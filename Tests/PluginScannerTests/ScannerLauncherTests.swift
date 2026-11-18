import Foundation
import PluginCatalog
import Testing

/// PLUG-001: the scanner runs out of process; a crash, a timeout or bad output blocks the plugin
/// with a reason instead of taking the caller down.
@Suite("PLUG-001: scanner launcher")
struct ScannerLauncherTests {
    let candidate = PluginCandidate.vst3("/Plugins/Thing.vst3", version: "2.0")

    @Test("PLUG-001 (T-094, DW-275): default timeout is 30 s; a retry gets 120 s")
    func defaultTimeout() {
        #expect(ScannerLauncher.defaultTimeout == 30)
        #expect(ScannerLauncher(executableURL: URL(filePath: "/x")).timeout == 30)
        #expect(ScannerLauncher.retryTimeout == 120)
    }

    @Test("PLUG-001: scanner JSON on stdout is returned as descriptors")
    func passesThroughOutput() throws {
        let dir = try TestDirectory()
        // Echo the arguments back so the test also checks how the candidate is passed.
        let json = #"[{"format":1,"identifier":"%s#ABC","name":"Thing","vendor":"V","version":"2.0","isInstrument":false,"hasSidechain":true,"numParams":7,"status":"ok"}]"#
        let script = try Fixtures.script("[ \"$1\" = --vst3 ] || exit 9\nprintf '\(json)' \"$2\"", in: dir)
        let result = try ScannerLauncher(executableURL: script).scan(candidate)
        #expect(result == [PluginDescriptor(
            format: .vst3, identifier: "/Plugins/Thing.vst3#ABC", name: "Thing", vendor: "V",
            version: "2.0", isInstrument: false, hasSidechain: true, numParams: 7)])
    }

    @Test("PLUG-001: scanner crash → blocked")
    func crashBlocks() throws {
        let dir = try TestDirectory()
        let script = try Fixtures.script("kill -SEGV $$", in: dir)
        let result = try ScannerLauncher(executableURL: script).scan(candidate)
        #expect(result == [.blocked(candidate, reason: "scanner crashed (SIGSEGV)")])
        #expect(result[0].identifier == candidate.path)
        #expect(result[0].name == "Thing")
    }

    @Test("PLUG-001: scanner exceeding the timeout is killed → blocked")
    func timeoutBlocks() throws {
        let dir = try TestDirectory()
        let script = try Fixtures.script("exec sleep 30", in: dir)
        let start = Date()
        let result = try ScannerLauncher(executableURL: script, timeout: 0.5).scan(candidate)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(result == [.blocked(candidate, reason: "timed out after 0.5 s")])
        #expect(result.first?.isTimedOut == true)
    }

    @Test("PLUG-001 (DW-275): a scan with a time limit of its own uses it instead of the launcher's")
    func perScanTimeout() throws {
        let dir = try TestDirectory()
        let json = #"[{"format":1,"identifier":"/Plugins/Thing.vst3#ABC","name":"Thing","vendor":"V","version":"2.0","isInstrument":false,"hasSidechain":false,"numParams":1,"status":"ok"}]"#
        let script = try Fixtures.script("sleep 1\nprintf '\(json)'", in: dir)
        let launcher = ScannerLauncher(executableURL: script, timeout: 0.3)
        let first = try launcher.scan(candidate)
        #expect(first == [.timedOut(candidate, after: 0.3)])
        #expect(first.first?.isTimedOut == true)
        let retried = try launcher.scan(candidate, timeout: 20)
        #expect(retried.map(\.status) == [.ok])
        #expect(retried.first?.isTimedOut == false)
        // Other blocked reasons aren't timeouts.
        #expect(PluginDescriptor.blocked(candidate, reason: "scanner crashed (SIGSEGV)").isTimedOut == false)
    }

    @Test("PLUG-001: non-zero exit → blocked with the last stderr line")
    func failureExitBlocks() throws {
        let dir = try TestDirectory()
        let script = try Fixtures.script("echo noise >&2\necho 'bad things' >&2\nexit 3", in: dir)
        let result = try ScannerLauncher(executableURL: script).scan(candidate)
        #expect(result == [.blocked(candidate, reason: "scanner exited with status 3: bad things")])
    }

    @Test("PLUG-001: unparseable output → blocked")
    func invalidOutputBlocks() throws {
        let dir = try TestDirectory()
        let script = try Fixtures.script("echo 'not json'", in: dir)
        let result = try ScannerLauncher(executableURL: script).scan(candidate)
        #expect(result == [.blocked(candidate, reason: "scanner printed invalid output")])
    }

    @Test("PLUG-001: a missing scanner is an error, not a blocked plugin")
    func missingScannerThrows() throws {
        let dir = try TestDirectory()
        let launcher = ScannerLauncher(executableURL: dir.path("no-such-scanner"))
        #expect(throws: PluginCatalogError.self) { try launcher.scan(candidate) }
    }

    // MARK: Real scanner + fake bundles

    @Test("PLUG-001: deliberately crashing fake VST3 bundle → blocked")
    func crashingBundleBlocks() throws {
        let dir = try TestDirectory()
        let bundle = try Fixtures.makeVST3Bundle(named: "Fake Crash", in: dir.url)
        let candidate = PluginCandidate.vst3(bundle.path)
        let result = try Fixtures.launcher().scan(candidate)
        #expect(result == [.blocked(candidate, reason: "scanner crashed (SIGSEGV)")])
    }

    @Test("PLUG-001: hanging fake VST3 bundle → blocked after the timeout")
    func hangingBundleBlocks() throws {
        let dir = try TestDirectory()
        let bundle = try Fixtures.makeVST3Bundle(named: "Fake Hang", in: dir.url)
        let candidate = PluginCandidate.vst3(bundle.path)
        let result = try Fixtures.launcher(timeout: 1).scan(candidate)
        #expect(result == [.blocked(candidate, reason: "timed out after 1 s")])
    }

    @Test("PLUG-001: scanner exits 64 on bad arguments")
    func scannerUsage() throws {
        let result = try runTool(Fixtures.scannerURL.path, ["--bogus", "x"])
        #expect(result.status == 64)
        #expect(result.stderr.contains("usage: PluginScanner"))
    }
}
