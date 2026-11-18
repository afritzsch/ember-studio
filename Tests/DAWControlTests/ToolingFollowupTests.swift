import DAWControl
import DAWModel
import Darwin
import Foundation
import Testing

// T-098: control/tooling follow-ups. plugins.* (DW-016) with stand-in scanners and with the real
// PluginScanner on bundles made here (never the machine's installed plugins), engine.paramDisplay
// (DW-289), Ctrl-C during dawctl render.offline (DW-283), the midi.inject summary (DW-285) and
// dawctl's fixture lookup (DW-132).

private let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func dawctlBinary() -> URL {
    Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "dawctl")
}

/// A dawctl child whose stdout/stderr are collected as they arrive, so a test can act on a line
/// (and signal the child) before it exits.
private final class LiveDawctl: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    let input = Pipe()

    init(_ arguments: [String], in directory: URL, environment: [String: String] = [:]) throws {
        process.executableURL = dawctlBinary()
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.filter { $0.key != "DAWCTL_FIXTURES" }
            .merging(environment) { $1 }
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = input
        // An empty read is EOF: drop the handler, or it fires again at once and spins a core (DW-261).
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            self?.lock.withLock { self?.out.append(d) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            self?.lock.withLock { self?.err.append(d) }
        }
        try process.run()
    }

    var stdout: String { lock.withLock { String(decoding: out, as: UTF8.self) } }
    var stderr: String { lock.withLock { String(decoding: err, as: UTF8.self) } }

    func send(_ text: String, close: Bool = true) throws {
        input.fileHandleForWriting.write(Data(text.utf8))
        if close { try input.fileHandleForWriting.close() }
    }

    /// After exit: lets the last output arrive.
    func settle() { usleep(200_000) }

    func waitFor(_ timeout: Duration = .seconds(20), _ condition: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline, process.isRunning else { return condition() }
            usleep(5_000)
        }
        return true
    }
}

@Suite("Control/tooling follow-ups (T-098)", .serialized)
@MainActor
struct ToolingFollowupTests {
    // MARK: plugins.* (DW-016)

    private func pluginDispatcher(_ box: CatalogPluginControlBox) -> Dispatcher {
        let plugins = CatalogPluginControl(cacheURL: box.cacheURL, discovery: box.discovery, scanner: box.scanner)
        var config = Dispatcher.Configuration()
        config.plugins = plugins
        return Dispatcher(configuration: config)
    }

    @Test("DW-016: plugins.scan scans new candidates once, plugins.list/blocked split usable and blocked, with reasons; the cache is the given file")
    func scanListBlocked() async throws {
        let dir = try TempDir()
        let scanner = FakePluginScanner(crashing: ["Crashy"], hanging: ["Slow"])
        let box = fakePluginControl(in: dir.url, names: ["Synth A", "Crashy", "Echo", "Slow"], scanner: scanner)
        let dispatcher = pluginDispatcher(box)

        #expect(try await dispatcher.ok(.pluginsList)["plugins"] == [])
        let scan = try await dispatcher.ok(.pluginsScan)
        #expect(scan["scanned"] == 4 && scan["unchanged"] == 0 && scan["plugins"] == 2 && scan["blocked"] == 2)
        #expect(scan["timeoutSeconds"] == 30)
        #expect(scan["scannedCandidates"] == ["/fake/Synth A.vst3", "/fake/Crashy.vst3", "/fake/Echo.vst3", "/fake/Slow.vst3"])

        let list = try await dispatcher.ok(.pluginsList)
        #expect(list["cachePath"]?.stringValue == box.cacheURL.path)
        #expect(list["plugins"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["Synth A", "Echo"])
        #expect(list["plugins"]?[0]?["isInstrument"] == true && list["plugins"]?[0]?["status"] == "ok")
        let blocked = try #require(try await dispatcher.ok(.pluginsBlocked)["blocked"]?.arrayValue)
        #expect(blocked.map { $0["identifier"] } == ["/fake/Crashy.vst3", "/fake/Slow.vst3"])
        #expect(blocked[0]["reason"] == "scanner crashed (SIGSEGV)" && blocked[0]["timedOut"] == nil)
        #expect(blocked[1]["reason"] == "timed out after 30 s" && blocked[1]["timedOut"] == true)
        #expect(FileManager.default.fileExists(atPath: box.cacheURL.path))

        // PLUG-004: nothing new, nothing scanned; blocked ones aren't retried by a scan.
        let again = try await dispatcher.ok(.pluginsScan, ["timeoutSeconds": 7])
        #expect(again["scanned"] == 0 && again["unchanged"] == 4 && again["timeoutSeconds"] == 7)
        #expect(scanner.scans.count == 4)
        #expect(await dispatcher.failure(.pluginsScan, ["timeoutSeconds": 0])?.code == -32602)
    }

    @Test("DW-016, DW-275: plugins.retry rescans a blocked plugin (120 s when it timed out, or the given limit); plugins.unblock forgets it for the next scan; unknown ids are refused")
    func retryAndUnblock() async throws {
        let dir = try TempDir()
        let scanner = FakePluginScanner(crashing: ["Crashy"], hanging: ["Slow"])
        let dispatcher = pluginDispatcher(fakePluginControl(in: dir.url, names: ["Crashy", "Echo", "Slow"], scanner: scanner))
        _ = try await dispatcher.ok(.pluginsScan)

        // A timed-out plugin gets the plugin manager's longer limit; it is fixed now, so it loads.
        scanner.heal("Slow")
        let slow = try await dispatcher.ok(.pluginsRetry, ["id": "/fake/Slow.vst3"])
        #expect(slow["retried"] == ["/fake/Slow.vst3"] && slow["stillBlocked"] == [])
        #expect(slow["scan"]?["scanned"] == 1 && slow["scan"]?["timeoutSeconds"] == 120)
        #expect(scanner.scans.last?.name == "Slow" && scanner.scans.last?.timeout == 120)
        #expect(try await dispatcher.ok(.pluginsList)["plugins"]?.arrayValue?.count == 2)

        // A crashed one keeps crashing: still blocked; an explicit limit is used as given.
        let crashy = try await dispatcher.ok(.pluginsRetry, ["id": "/fake/Crashy.vst3", "timeoutSeconds": 9])
        #expect(crashy["stillBlocked"]?[0]?["identifier"] == "/fake/Crashy.vst3")
        #expect(scanner.scans.last?.name == "Crashy" && scanner.scans.last?.timeout == 9)

        let unknown = await dispatcher.failure(.pluginsRetry, ["id": "/fake/Echo.vst3"])
        #expect(unknown?.code == -32000 && unknown?.data?["dawError"] == "invalidArgument")
        #expect(await dispatcher.failure(.pluginsUnblock, ["id": "nope"])?.data?["dawError"] == "invalidArgument")

        // Unblock without scanning: gone from the blocked list; the next scan tries it again.
        let scansBefore = scanner.scans.count
        #expect(try await dispatcher.ok(.pluginsUnblock)["unblocked"] == ["/fake/Crashy.vst3"])
        #expect(scanner.scans.count == scansBefore)
        #expect(try await dispatcher.ok(.pluginsBlocked)["blocked"] == [])
        scanner.heal("Crashy")
        #expect(try await dispatcher.ok(.pluginsScan)["scanned"] == 1)
        #expect(try await dispatcher.ok(.pluginsList)["plugins"]?.arrayValue?.count == 3)
    }

    @Test("DW-016: without a configured provider, a UI provider that implements plugins.* is used (the app's, attach mode)")
    func uiProviderServesPlugins() async throws {
        let provider = StubAppPlugins()
        let dispatcher = Dispatcher(configuration: .init(mode: .attach, ui: provider))
        let list = try await dispatcher.ok(.pluginsList)
        #expect(list["cachePath"] == "/stub/plugins.json" && list["plugins"]?[0]?["name"] == "Stub")
        #expect(try await dispatcher.ok(.pluginsScan, ["timeoutSeconds": 5])["note"] == "stub")
        #expect(provider.calls == ["list", "scan 5.0"])
    }

    @Test("DW-016: dawctl plugins.* run the real PluginScanner (next to dawctl) on bundles in $DAWCTL_VST3_DIRS, cached in $DAWCTL_PLUGIN_CACHE; a broken bundle is blocked, a real one listed")
    func dawctlRealScanner() throws {
        try buildTestVST3()
        let dir = try TempDir()
        let vst3 = dir.file("vst3")
        try FileManager.default.createDirectory(at: vst3.appending(path: "Broken.vst3"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: vst3.appending(path: "again.vst3"), withDestinationURL: repoRoot.appending(path: ".build/test-plugins/again.vst3"))
        let env = ["DAWCTL_PLUGIN_CACHE": dir.file("cache/plugins.json").path, "DAWCTL_VST3_DIRS": vst3.path, "DAWCTL_AU": "0"]
        func run(_ args: [String]) throws -> (Int32, JSONValue?, String) {
            let child = try LiveDawctl(args, in: dir.url, environment: env)
            try child.send("")
            #expect(waitForExit(child.process, timeout: .seconds(60)))
            child.settle()
            let line = child.stdout.split(separator: "\n").last.map(String.init) ?? ""
            return (child.process.terminationStatus, try? JSONValue(parsing: Data(line.utf8)), child.stderr)
        }
        let (status, scan, err) = try run(["plugins.scan"])
        #expect(status == 0, "\(err)")
        // again.vst3 holds two classes (Steinberg's AGain and its sidechain variant).
        #expect(scan?["scanned"] == 2 && (scan?["plugins"]?.int64Value ?? 0) >= 1 && scan?["blocked"] == 1)
        let (_, list, _) = try run(["plugins.list"])
        let identifiers = list?["plugins"]?.arrayValue?.compactMap { $0["identifier"]?.stringValue } ?? []
        #expect(identifiers.contains { $0.hasSuffix("again.vst3#84E8DE5F92554F5396FAE4133C935A18") }, "\(identifiers)")
        #expect(list?["cachePath"]?.stringValue == dir.file("cache/plugins.json").path)
        let (_, blocked, _) = try run(["plugins.blocked"])
        #expect(blocked?["blocked"]?[0]?["name"] == "Broken")
        #expect(blocked?["blocked"]?[0]?["reason"]?.stringValue?.contains("could not load module") == true)
        let broken = try #require(blocked?["blocked"]?[0]?["identifier"]?.stringValue)
        let (_, retried, _) = try run(["plugins.retry", "--json", #"{"id": "\#(broken)", "timeoutSeconds": 10}"#])
        #expect(retried?["retried"] == [.string(broken)] && retried?["stillBlocked"]?.arrayValue?.count == 1)
        #expect(try run(["plugins.unblock"]).1?["unblocked"] == [.string(broken)])
        #expect(try run(["plugins.blocked"]).1?["blocked"] == [])
    }

    // MARK: engine.paramDisplay (DW-289)

    @Test("DW-289: engine.paramDisplay answers a hosted VST3's own strings for a value or its current one; no plugin or no param is invalidArgument")
    func paramDisplay() async throws {
        try buildTestVST3()
        let dir = try TempDir()
        let dispatcher = TestDispatchers.real(workingDirectory: dir.url)
        _ = try await dispatcher.ok(.projectNew, ["name": "display"])
        let again = repoRoot.appending(path: ".build/test-plugins/again.vst3").path + "#84E8DE5F92554F5396FAE4133C935A18"
        let track: JSONValue = [
            "id": 10, "name": "Fx", "kind": "audio", "color": ["red": 0.5, "green": 0.5, "blue": 0.5],
            "clips": [], "takeFolders": [],
            "inserts": [["id": 20, "kind": ["format": "vst3", "identifier": .string(again), "name": "again", "vendor": "Steinberg", "version": "1"],
                         "params": [], "bypass": false]],
            "strip": ["gain": 1, "pan": 0, "mute": false, "solo": false, "phaseInvert": false],
            "sends": [], "output": ["kind": "master"], "armed": false, "monitoring": "auto", "automation": [],
        ]
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "RestoreTrack", "index": 0, "track": track]])
        _ = try await dispatcher.ok(.renderOffline, ["from": 0, "to": 960, "path": "warm.wav", "tail": false])  // the plugin loads
        #expect(try await dispatcher.ok(.enginePluginInfo, ["slot": 20])["loaded"] == true)

        let half = try await dispatcher.ok(.engineParamDisplay, ["node": 20, "param": 0, "value": 0.5])
        #expect(half["node"] == 20 && half["param"] == 0 && half["value"]?.doubleValue == 0.5 && half["display"] == "-6.02")
        let current = try await dispatcher.ok(.engineParamDisplay, ["node": 20, "param": 0])
        #expect(current["value"]?.doubleValue == 1 && current["display"] == "0.00")
        #expect(try await dispatcher.ok(.engineParamDisplay, ["node": 20, "param": 2, "value": 1])["display"] == "On")
        // A value the plugin has no string for answers "" (here: an unknown index with a value).
        #expect(try await dispatcher.ok(.engineParamDisplay, ["node": 20, "param": 7, "value": 0.5])["display"] == "")
        #expect(await dispatcher.failure(.engineParamDisplay, ["node": 20, "param": 7])?.data?["dawError"] == "invalidArgument")
        #expect(await dispatcher.failure(.engineParamDisplay, ["node": 99, "param": 0])?.data?["dawError"] == "invalidArgument")
        #expect(await dispatcher.failure(.engineParamDisplay, ["node": 20, "param": -1])?.code == -32602)
        #expect(try await dispatcher.ok(.engineTelemetry)["rtViolations"] == 0)
    }

    // MARK: Ctrl-C (DW-283)

    private static let longRender = #"render.offline {"from": 0, "to": 1152000, "path": "long.wav", "tail": false, "sampleFormat": "int16"}"#

    @Test("DW-283: Ctrl-C during a headless dawctl render.offline cancels it: the render fails with cancelled, its file is deleted, dawctl exits 1")
    func ctrlCHeadless() throws {
        let dir = try TempDir()
        let child = try LiveDawctl(["--progress", "script", "-"], in: dir.url)
        try child.send("""
            project.new {"name": "c"}
            command.apply {"command": {"type": "AddTrack", "name": "A", "kind": "audio"}}
            \(Self.longRender)
            project.get {"path": "/name"}

            """)
        #expect(child.waitFor { child.stderr.contains("dawctl: render.offline") }, "\(child.stderr)")
        kill(child.process.processIdentifier, SIGINT)
        #expect(waitForExit(child.process, timeout: .seconds(30)))
        child.settle()
        #expect(child.process.terminationStatus == 1, "\(child.stderr)")
        #expect(child.stderr.contains("cancelling render.offline"))
        let last = try #require(child.stdout.split(separator: "\n").last)
        let response = try JSONDecoder().decode(RPCResponse.self, from: Data(last.utf8))
        #expect(response.error?.code == -32005, "the script stops at the cancelled render: \(child.stdout)")
        #expect(!FileManager.default.fileExists(atPath: dir.file("long.wav").path))
    }

    @Test("DW-283: Ctrl-C during `dawctl --socket … render.offline` sends render.cancel over a side connection; the server's render stops and the server keeps serving")
    func ctrlCAttached() throws {
        let dir = try TempDir()
        let path = ControlSocketPath.forProcess(Int32.random(in: 1_000_000...Int32.max))
        let server = Process()
        server.executableURL = dawctlBinary()
        server.arguments = ["serve", "--control-socket", path, "--parent-pid", String(getpid())]
        server.currentDirectoryURL = dir.url
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer {
            server.terminate()
            waitForExit(server)
        }
        for _ in 0..<500 where !ControlSocketClient.isListening(at: path) { usleep(10_000) }
        let setup = try dawctl(["--socket", path, "script", "-"], stdin: """
            project.new {"name": "c"}
            command.apply {"command": {"type": "AddTrack", "name": "A", "kind": "audio"}}

            """, in: dir.url)
        #expect(setup.status == 0, "\(setup.stderr)")

        let child = try LiveDawctl(["--socket", path, "--progress", "render.offline", "--json",
                                    #"{"from": 0, "to": 1152000, "path": "long.wav", "tail": false, "sampleFormat": "int16"}"#],
                                   in: dir.url)
        try child.send("")
        #expect(child.waitFor { child.stderr.contains("dawctl: render.offline") }, "\(child.stderr)")
        kill(child.process.processIdentifier, SIGINT)
        #expect(waitForExit(child.process, timeout: .seconds(30)))
        child.settle()
        #expect(child.process.terminationStatus == 1, "\(child.stderr)")
        #expect(child.stderr.contains("cancelling render.offline") && child.stderr.contains("cancelled"))
        #expect(!FileManager.default.fileExists(atPath: dir.file("long.wav").path))
        // The server is fine and idle: the next request answers.
        let after = try dawctl(["--socket", path, "project.get", "--json", #"{"path": "/name"}"#], in: dir.url)
        #expect(after.status == 0 && after.stdout == "\"c\"\n")
    }

    @Test("DW-283: Ctrl-C with no render running exits 130 at once")
    func ctrlCIdle() throws {
        let dir = try TempDir()
        let child = try LiveDawctl(["repl"], in: dir.url)
        // The REPL waits in readLine (stdin stays open), blocking its main thread.
        try child.send("project.new {\"name\": \"idle\"}\n", close: false)
        usleep(500_000)
        kill(child.process.processIdentifier, SIGINT)
        #expect(waitForExit(child.process, timeout: .seconds(10)))
        #expect(child.process.terminationStatus == 130)
    }

    // MARK: DW-285, DW-132

    @Test("DW-285: the midi.inject summary names source?")
    func midiInjectSummary() {
        #expect(ControlMethod.midiInject.summary.contains("source?"))
        #expect(ControlMethod.engineParamDisplay.summary.contains("{node, param, value?}"))
    }

    @Test("DW-132: dawctl finds the checkout's fixtures through ControlFixtures.defaultDirectories (no --fixtures, no $DAWCTL_FIXTURES)")
    func dawctlFixtureLookup() throws {
        let dir = try TempDir()
        let fixtures = repoRoot.appending(path: "Tests/GoldenTests/fixtures")
        #expect(ControlFixtures.defaultDirectories(environment: [:], executable: dawctlBinary(), currentDirectory: dir.url) == [fixtures])
        let name = "pan_law"
        let run = try dawctl(["test.fixture", "--json", #"{"name": "\#(name)"}"#], in: dir.url)
        #expect(run.status == 0, "\(run.stderr)")
        #expect(run.stdout.contains(#""name":"\#(name)""#))
    }
}

/// The app side of plugins.* in miniature: a UI provider that also implements them.
@MainActor
private final class StubAppPlugins: ControlUIProvider, ControlPluginProvider {
    var calls: [String] = []
    func uiState() async throws -> JSONValue { [:] }
    func uiSnapshot(_ params: UISnapshotParams) async throws -> JSONValue { [:] }
    func uiPerform(_ params: UIPerformParams) async throws -> JSONValue { [:] }

    var pluginCachePath: String { "/stub/plugins.json" }
    func pluginsList() async throws -> [ControlPlugin] {
        calls.append("list")
        return [ControlPlugin(format: "au", identifier: "aufx:stub:test", name: "Stub", vendor: "T", version: "1",
                              isInstrument: false, hasSidechain: false, numParams: 0)]
    }
    func pluginsScan(timeout: TimeInterval?) async throws -> ControlPluginScanSummary {
        calls.append("scan \(timeout ?? -1)")
        return ControlPluginScanSummary(scanned: 0, unchanged: 1, removed: 0, note: "stub")
    }
    func pluginsRetry(identifiers: Set<String>?, timeout: TimeInterval?) async throws -> ControlPluginScanSummary {
        ControlPluginScanSummary(scanned: 0, unchanged: 0, removed: 0)
    }
    func pluginsUnblock(identifiers: Set<String>?) async throws {}
}

private func buildTestVST3() throws {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/bash")
    process.arguments = [repoRoot.appending(path: "scripts/build-test-vst3.sh").path]
    try process.run()
    #expect(waitForExit(process, timeout: .seconds(600)))
    #expect(process.terminationStatus == 0, "scripts/build-test-vst3.sh failed")
}
