import Foundation
import PluginCatalog
import Testing

/// PLUG-003. Discovery runs on temp directories and the scan on the fake module from
/// Fixtures/FakeVST3.cpp, never on installed plugins.
@Suite("PLUG-003: VST3 discovery and scan")
struct VST3ScanTests {
    @Test("PLUG-003: default search folders")
    func defaultDirectories() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(SystemPluginDiscovery.defaultVST3Directories.map(\.path) == [
            "/Library/Audio/Plug-Ins/VST3", "\(home)/Library/Audio/Plug-Ins/VST3",
        ])
    }

    @Test("PLUG-003: discovery finds bundles, also in vendor subfolders, without loading them")
    func discovery() throws {
        let user = try TestDirectory()
        let system = try TestDirectory()
        let vendor = system.path("Vendor")
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        try Fixtures.makeVST3Bundle(named: "Alpha", in: user.url, version: "1.0", withBinary: false)
        try Fixtures.makeVST3Bundle(named: "Beta", in: vendor, version: "2.5", withBinary: false)
        // A bundle nested inside a bundle isn't a separate plugin.
        try Fixtures.makeVST3Bundle(named: "Inner", in: user.path("Alpha.vst3/Contents/Resources"), withBinary: false)
        try Data().write(to: user.path("NotABundle.vst3"))
        try Data().write(to: user.path("readme.txt"))

        let discovery = SystemPluginDiscovery(
            vst3Directories: [system.url, user.url, user.path("missing")], includeAudioUnits: false)
        let candidates = discovery.candidates()
        #expect(candidates.map(\.name).sorted() == ["Alpha", "Beta"])
        let beta = try #require(candidates.first { $0.name == "Beta" })
        #expect(beta.format == .vst3)
        #expect(beta.path == vendor.appending(path: "Beta.vst3").path)
        #expect(beta.version == "2.5")
        #expect(beta.mtime > 0)
    }

    @Test("PLUG-003: scan lists audio effect classes with buses, sidechain and parameter count")
    func scanModule() throws {
        let dir = try TestDirectory()
        let bundle = try Fixtures.makeVST3Bundle(named: "Fake Plugins", in: dir.url)
        let result = try Fixtures.launcher().scan(.vst3(bundle.path))

        // Controller classes are not plugins; only kVstAudioEffectClass entries are listed.
        #expect(result.map(\.name) == ["Fake Sidechain Comp", "Fake Synth"])
        #expect(result.allSatisfy { $0.status == .ok && $0.reason == nil && $0.format == .vst3 })
        #expect(result.allSatisfy { $0.vendor == "Ember Studio Tests" && $0.version == "1.2.3" })

        let comp = result[0]
        #expect(comp.identifier == "\(bundle.path)#5A1D3C01000000000000000000000001")
        #expect(comp.hasSidechain)
        #expect(!comp.isInstrument)
        #expect(comp.numParams == 3)

        let synth = result[1]
        #expect(synth.identifier == "\(bundle.path)#5A1D3C01000000000000000000000003")
        #expect(!synth.hasSidechain)
        #expect(synth.isInstrument)
        #expect(synth.numParams == 1)
    }

    @Test("PLUG-003: plugin output on stdout doesn't corrupt the scanner's JSON")
    func pluginChatterIsKeptOffStdout() throws {
        let dir = try TestDirectory()
        let bundle = try Fixtures.makeVST3Bundle(named: "Fake Chatty", in: dir.url)
        let result = try runTool(Fixtures.scannerURL.path, ["--vst3", bundle.path])
        #expect(result.status == 0)
        #expect(result.stderr.contains("fake plugin chatter"))
        #expect(try ScannerOutput.decode(result.stdout).count == 2)
    }

    @Test("PLUG-003: a module that fails to load is blocked with the loader's reason")
    func unloadableModule() throws {
        let dir = try TestDirectory()
        let bundle = try Fixtures.makeVST3Bundle(named: "Broken", in: dir.url, version: "0.9", withBinary: false)
        let result = try Fixtures.launcher().scan(.vst3(bundle.path))
        let entry = try #require(result.first)
        #expect(result.count == 1)
        #expect(entry.status == .blocked)
        #expect(entry.identifier == bundle.path)
        #expect(entry.name == "Broken")
        #expect(entry.version == "0.9")
        #expect(entry.reason?.hasPrefix("could not load module") == true)
    }
}
