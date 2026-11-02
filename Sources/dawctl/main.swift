import DAWControl
import Foundation

// CTL-010..012: the control protocol from the shell. Headless by default (in-process model +
// offline engine); with --attach (CTL-011) the same requests go to the running app's socket.
//
//   dawctl <method> [--json '<params>']        one request; prints its result
//   dawctl script <file.jsonl | -> [--keep-going]
//   dawctl repl
//   dawctl methods
//   dawctl serve [--control-socket <path>] [--engine e] [--parent-pid n]
//
// CTL-012: exits 0 when every request succeeded, 1 when one failed, 2 on bad usage.

let usage = """
    usage: dawctl <method> [--json '<params>'] [--pretty]
           dawctl script <file.jsonl | -> [--keep-going]
           dawctl repl
           dawctl methods
           dawctl serve [--control-socket <path>] [--engine fake|coreAudio|offline] [--parent-pid <pid>]
    options:
      --fixtures <dir>  also look for test.fixture scripts here (repeatable; $DAWCTL_FIXTURES too)
      --attach          send requests to the running app (CTL-011) at this checkout's socket,
                        $TMPDIR/emberstudio-<hash of the checkout root>.sock (CTL-032)
      --socket <path>   attach to the app (or `dawctl serve`) listening at <path>
      --launch          with --attach: start this checkout's built app if nothing listens yet; it
                        keeps running after dawctl exits (stop it with Quit or `kill`)
      --progress        print progress of long requests (render.offline, CTL-031) to stderr
    serve runs a headless dispatcher behind a control socket (CTL-030) until it is killed or
    --parent-pid exits; the default socket is $TMPDIR/emberstudio-<pid>.sock.
    Scripts hold one request per line: {"method": …, "params": {…}} or `method {params}`;
    blank lines and lines starting with # or // are skipped.
    Exit status: 0 all requests succeeded, 1 a request failed, 2 bad usage.
    """

enum Exit: Int32 {
    case ok = 0
    case requestFailed = 1
    case usage = 2
}

func fail(_ message: String, _ code: Exit = .usage) -> Never {
    FileHandle.standardError.write(Data("dawctl: \(message)\n".utf8))
    exit(code.rawValue)
}

func printError(_ error: RPCError) {
    let json = (try? JSONValue(encoding: error))?.jsonString() ?? error.message
    FileHandle.standardError.write(Data("dawctl: \(error.message)\n\(json)\n".utf8))
}

// MARK: Arguments

var positional: [String] = []
var paramsJSON: String?
var pretty = false
var keepGoing = false
var attach = false
var launch = false
var showProgress = false
var socketOverride: String?
var serveSocket: String?
var serveEngine = EngineChoice.offline
var parentPID: Int32?
var extraFixtures: [URL] = []
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--json":
        guard let value = arguments.popFirst() else { fail("--json needs a value\n\(usage)") }
        paramsJSON = value
    case "--fixtures":
        guard let value = arguments.popFirst() else { fail("--fixtures needs a folder\n\(usage)") }
        extraFixtures.append(URL(fileURLWithPath: value, isDirectory: true))
    case "--pretty": pretty = true
    case "--keep-going": keepGoing = true
    case "--attach": attach = true
    case "--launch": launch = true
    case "--progress": showProgress = true
    case "--socket":
        guard let value = arguments.popFirst() else { fail("--socket needs a path\n\(usage)") }
        socketOverride = value
        attach = true
    case "--control-socket":
        guard let value = arguments.popFirst() else { fail("--control-socket needs a path\n\(usage)") }
        serveSocket = value
    case "--engine":
        guard let value = arguments.popFirst(), let engine = EngineChoice(rawValue: value) else {
            fail("--engine is one of \(EngineChoice.names)\n\(usage)")
        }
        serveEngine = engine
    case "--parent-pid":
        guard let value = arguments.popFirst(), let pid = Int32(value), pid > 0 else { fail("--parent-pid needs a pid\n\(usage)") }
        parentPID = pid
    case "-h", "--help", "help":
        print(usage)
        exit(Exit.ok.rawValue)
    default:
        if argument.hasPrefix("--") { fail("unknown option \(argument)\n\(usage)") }
        positional.append(argument)
    }
}
guard let command = positional.first else { fail(usage) }
if launch && !attach { fail("--launch goes with --attach\n\(usage)") }
if command == "serve" && attach { fail("serve is a server; it doesn't attach\n\(usage)") }

// MARK: Transport

/// Where requests go: the in-process dispatcher (headless) or the app's socket (CTL-011).
@MainActor
enum Target {
    case headless(Dispatcher)
    case attached(ControlSocketClient)

    func handle(_ request: RPCRequest) async -> RPCResponse? {
        let printing = showProgress
        switch self {
        case .headless(let dispatcher):
            var handler: ControlProgressHandler?
            if printing { handler = { report($0) } }
            return await dispatcher.handle(request, progress: handler)
        case .attached(let client):
            do {
                return try await client.send(request) { notification in
                    if printing, let update = ControlProgress(notification: notification) { report(update) }
                }
            } catch {
                return RPCResponse(id: request.id, error: error.rpcError)
            }
        }
    }
}

/// CTL-031: `--progress` lines on stderr.
@Sendable nonisolated func report(_ progress: ControlProgress) {
    let percent = Int((progress.progress * 100).rounded())
    let message = progress.message.map { " \($0)" } ?? ""
    FileHandle.standardError.write(Data("dawctl: \(progress.method) \(percent)%\(message)\n".utf8))
}

@MainActor func headlessDispatcher(engine: EngineChoice = .offline) -> Dispatcher {
    Dispatcher(configuration: .init(
        makeEngine: engine.factory, fixtureDirectories: extraFixtures + ControlFixtures.defaultDirectories()))
}

/// CTL-011: the app at --socket, or at this checkout's attach socket (CTL-032).
@MainActor func attachedClient() async -> ControlSocketClient {
    let root = ControlSocketPath.currentCheckoutRoot()
    guard let path = socketOverride ?? root.map({ ControlSocketPath.forCheckout($0) }) else {
        fail("--attach: not inside a checkout (no Package.swift above the current folder); pass --socket <path>")
    }
    do {
        guard launch, let root else { return try ControlSocketClient(path: path) }
        let app = try await AppLauncher.attach(
            .app(checkoutRoot: root), socketPath: path, parentPID: nil,
            log: root.appending(path: ".build/attach/app.log"))
        if let pid = app.pid { FileHandle.standardError.write(Data("dawctl: launched the app (pid \(pid)) at \(path)\n".utf8)) }
        return app.client
    } catch {
        printError(error.rpcError)
        exit(Exit.requestFailed.rawValue)
    }
}

// MARK: Modes

@MainActor func runScript(_ script: ControlScript, on target: Target) async -> Exit {
    var status = Exit.ok
    for line in script.lines {
        guard let response = await target.handle(line.request) else { continue }
        print(response.line())
        if let error = response.error {
            status = .requestFailed
            FileHandle.standardError.write(Data("dawctl: line \(line.number): \(error.message)\n".utf8))
            if !keepGoing { break }
        }
    }
    return status
}

@MainActor func runREPL(on target: Target) async -> Exit {
    let interactive = isatty(STDIN_FILENO) != 0
    var status = Exit.ok
    var nextID: Int64 = 1
    while true {
        if interactive {
            print("dawctl> ", terminator: "")
            fflush(stdout)
        }
        guard let line = readLine() else { break }
        switch line.trimmingCharacters(in: .whitespaces) {
        case "quit", "exit": return status
        case "help":
            print(usage)
            continue
        case "methods":
            for method in ControlMethod.allCases { print("\(method.rawValue)  \(method.summary)") }
            continue
        default: break
        }
        let request: RPCRequest
        do {
            guard let parsed = try ControlScript.request(fromLine: line, defaultID: .int(nextID)) else { continue }
            request = parsed
        } catch {
            status = .requestFailed
            print(RPCResponse(id: nil, error: error.rpcError).line())
            continue
        }
        nextID += 1
        if let response = await target.handle(request) {
            print(response.line())
            if response.isError { status = .requestFailed }
        }
    }
    return status
}

@MainActor func runSingle(_ method: String, on target: Target) async -> Exit {
    var params: JSONValue?
    if let paramsJSON {
        guard let parsed = try? JSONValue(parsing: Data(paramsJSON.utf8)) else { fail("--json is not valid JSON") }
        params = parsed
    }
    guard let response = await target.handle(RPCRequest(id: .int(1), method: method, params: params)) else {
        return .ok
    }
    if let error = response.error {
        printError(error)
        return .requestFailed
    }
    let result = response.result ?? .null
    if pretty, let data = try? JSONSerialization.data(
        withJSONObject: JSONSerialization.jsonObject(with: result.data(), options: .fragmentsAllowed),
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    {
        print(String(decoding: data, as: UTF8.self))
    } else {
        print(result.jsonString())
    }
    return .ok
}

/// `dawctl serve`: a headless dispatcher behind a control socket (CTL-030), as the app serves one.
/// Attach-mode tests use it as a stand-in for the app. Runs until SIGTERM/SIGINT or until
/// `--parent-pid` exits; the socket file is removed either way.
@MainActor func serve() async -> Never {
    let path = serveSocket ?? ControlSocketPath.forProcess()
    let server = ControlSocketServer(path: path, dispatcher: headlessDispatcher(engine: serveEngine))
    do {
        try server.start()
    } catch {
        printError(error.rpcError)
        exit(Exit.requestFailed.rawValue)
    }
    FileHandle.standardError.write(Data("dawctl: serving at \(path)\n".utf8))
    let stop: @Sendable () -> Void = {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { server.stop() }
            exit(0)
        }
    }
    var signalSources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler(handler: stop)
        source.resume()
        signalSources.append(source)
    }
    if let parentPID { ParentProcessWatch.start(parentPID, onExit: stop) }
    // Serve until a signal or the parent ends the process.
    while true {
        try? await Task.sleep(for: .seconds(3600))
        _ = signalSources
    }
}

let status: Exit
switch command {
case "serve":
    guard positional.count == 1 else { fail("serve takes no arguments besides options\n\(usage)") }
    await serve()
case "methods":
    for method in ControlMethod.allCases { print("\(method.rawValue)  \(method.summary)") }
    status = .ok
case "script":
    guard positional.count == 2 else { fail("script needs one file (or - for stdin)\n\(usage)") }
    let path = positional[1]
    let text: String
    if path == "-" {
        text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    } else {
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            fail("cannot read \(path): \(error.localizedDescription)", .requestFailed)
        }
    }
    let script: ControlScript
    do {
        script = try ControlScript(parsing: text)
    } catch {
        printError(error.rpcError)
        exit(Exit.requestFailed.rawValue)
    }
    status = await runScript(script, on: attach ? .attached(await attachedClient()) : .headless(headlessDispatcher()))
case "repl":
    status = await runREPL(on: attach ? .attached(await attachedClient()) : .headless(headlessDispatcher()))
default:
    guard positional.count == 1 else { fail("one method per call; use `dawctl script` for more\n\(usage)") }
    status = await runSingle(command, on: attach ? .attached(await attachedClient()) : .headless(headlessDispatcher()))
}
exit(status.rawValue)
