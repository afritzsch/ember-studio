import DAWControl
import Foundation

// CTL-010..012: the control protocol from the shell, headless (in-process model + offline engine).
//
//   dawctl <method> [--json '<params>']        one request; prints its result
//   dawctl script <file.jsonl | -> [--keep-going]
//   dawctl repl
//   dawctl methods
//
// CTL-012: exits 0 when every request succeeded, 1 when one failed, 2 on bad usage.

let usage = """
    usage: dawctl <method> [--json '<params>'] [--pretty]
           dawctl script <file.jsonl | -> [--keep-going]
           dawctl repl
           dawctl methods
    options:
      --fixtures <dir>  also look for test.fixture scripts here (repeatable; $DAWCTL_FIXTURES too)
      --attach          use the running app's socket (CTL-011, not available yet)
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
    case "--attach": fail("--attach (CTL-011) needs the app's control socket, which isn't implemented yet")
    case "-h", "--help", "help":
        print(usage)
        exit(Exit.ok.rawValue)
    default:
        if argument.hasPrefix("--") { fail("unknown option \(argument)\n\(usage)") }
        positional.append(argument)
    }
}
guard let command = positional.first else { fail(usage) }

/// `Tests/GoldenTests/fixtures` of the checkout this binary was built in (it lives in
/// `<repo>/.build/<config>/`), or of the current directory's checkout.
func defaultFixtureDirectories() -> [URL] {
    var dirs: [URL] = []
    if let env = ProcessInfo.processInfo.environment["DAWCTL_FIXTURES"] {
        dirs += env.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
    }
    let starts = [Bundle.main.executableURL?.resolvingSymlinksInPath(),
                  URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)]
    for start in starts.compactMap({ $0 }) {
        var dir = start
        while dir.path != "/" {
            let fixtures = dir.appending(path: "Tests/GoldenTests/fixtures")
            if FileManager.default.fileExists(atPath: dir.appending(path: "Package.swift").path) {
                if !dirs.contains(fixtures) { dirs.append(fixtures) }
                break
            }
            dir = dir.deletingLastPathComponent()
        }
    }
    return dirs
}

let dispatcher = Dispatcher(configuration: .init(fixtureDirectories: extraFixtures + defaultFixtureDirectories()))

// MARK: Modes

@MainActor func runScript(_ script: ControlScript) async -> Exit {
    var status = Exit.ok
    for line in script.lines {
        guard let response = await dispatcher.handle(line.request) else { continue }
        print(response.line())
        if let error = response.error {
            status = .requestFailed
            FileHandle.standardError.write(Data("dawctl: line \(line.number): \(error.message)\n".utf8))
            if !keepGoing { break }
        }
    }
    return status
}

@MainActor func runREPL() async -> Exit {
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
        if let response = await dispatcher.handle(request) {
            print(response.line())
            if response.isError { status = .requestFailed }
        }
    }
    return status
}

@MainActor func runSingle(_ method: String) async -> Exit {
    var params: JSONValue?
    if let paramsJSON {
        guard let parsed = try? JSONValue(parsing: Data(paramsJSON.utf8)) else { fail("--json is not valid JSON") }
        params = parsed
    }
    guard let response = await dispatcher.handle(RPCRequest(id: .int(1), method: method, params: params)) else {
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

let status: Exit
switch command {
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
    do {
        status = await runScript(try ControlScript(parsing: text))
    } catch {
        printError(error.rpcError)
        status = .requestFailed
    }
case "repl":
    status = await runREPL()
case "methods":
    for method in ControlMethod.allCases { print("\(method.rawValue)  \(method.summary)") }
    status = .ok
default:
    guard positional.count == 1 else { fail("one method per call; use `dawctl script` for more\n\(usage)") }
    status = await runSingle(command)
}
exit(status.rawValue)
