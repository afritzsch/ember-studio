import DAWControl
import Foundation
import PluginCatalog
import Testing

@testable import EmberStudioShell

// UI-041 (plugin manager: scan, blocked list, rescan) and DW-015 (the app uses the `PluginCatalog`
// product): T-065. This file imports PluginCatalog without DAWModel (both name a PluginDescriptor).

/// Candidates the tests pretend are installed.
private final class FakeDiscovery: PluginDiscovering, @unchecked Sendable {
    let lock = NSLock()
    private var list: [PluginCandidate]
    init(_ list: [PluginCandidate]) { self.list = list }
    var candidatesList: [PluginCandidate] {
        get { lock.withLock { list } }
        set { lock.withLock { list = newValue } }
    }
    func candidates() -> [PluginCandidate] { candidatesList }
}

/// A scanner that reports what `results` says for each path (blocked if it says nothing), counting scans.
private final class FakeScanner: PluginScanning, @unchecked Sendable {
    let lock = NSLock()
    private var results: [String: [PluginDescriptor]]
    private(set) var scannedPaths: [String] = []
    init(_ results: [String: [PluginDescriptor]]) { self.results = results }
    func set(_ path: String, _ plugins: [PluginDescriptor]) { lock.withLock { results[path] = plugins } }
    var scanned: [String] { lock.withLock { scannedPaths } }
    func scan(_ candidate: PluginCandidate) throws(PluginCatalogError) -> [PluginDescriptor] {
        lock.withLock {
            scannedPaths.append(candidate.path)
            return results[candidate.path] ?? [.blocked(candidate, reason: "scanner crashed (SIGSEGV)")]
        }
    }
}

private func vst3(_ path: String, _ name: String) -> PluginCandidate {
    PluginCandidate(format: .vst3, path: path, mtime: 1, version: "1", name: name)
}

private func ok(_ path: String, _ name: String, instrument: Bool = false) -> PluginDescriptor {
    PluginDescriptor(format: .vst3, identifier: "\(path)#0A", name: name, vendor: "Ember", version: "1",
                     isInstrument: instrument, hasSidechain: false, numParams: 2)
}

extension PluginManagerModel {
    /// A manager whose cache (in `dir`) holds `plugins` (test helper for the device pickers).
    @MainActor
    static func withPlugins(_ plugins: [ScannedPlugin], in dir: TempDir) throws -> PluginManagerModel {
        let url = dir.file("plugins.json")
        var cache = PluginCache()
        for plugin in plugins {
            let candidate = PluginCandidate(format: plugin.format == .au ? .au : .vst3, path: plugin.identifier, mtime: 0,
                                            version: plugin.version, name: plugin.name)
            let descriptor = PluginDescriptor(
                format: candidate.format, identifier: plugin.identifier, name: plugin.name, vendor: plugin.vendor,
                version: plugin.version, isInstrument: plugin.isInstrument, hasSidechain: plugin.hasSidechain,
                numParams: plugin.numParams, status: plugin.isBlocked ? .blocked : .ok, reason: plugin.blockedReason)
            cache.entries.append(PluginCache.Entry(candidate: candidate, plugins: [descriptor]))
        }
        try cache.save(to: url)
        return PluginManagerModel(cacheURL: url, scannerURL: nil, discovery: FakeDiscovery([]), scanner: FakeScanner([:]))
    }
}

@MainActor
@Suite("Plugin manager (UI-041, DW-015; T-065)", .serialized)
struct PluginManagerTests {
    @Test("UI-041, PLUG-001/004: scan lists plugins and the blocked list with reasons; a second scan skips unchanged ones; rescan scans all again; retry rescans the blocked")
    func scanBlockedRescan() async throws {
        let dir = try TempDir()
        let discovery = FakeDiscovery([vst3("/a.vst3", "Alpha"), vst3("/b.vst3", "Bravo"), vst3("/c.vst3", "Crash")])
        let scanner = FakeScanner(["/a.vst3": [ok("/a.vst3", "Alpha")], "/b.vst3": [ok("/b.vst3", "Bravo Synth", instrument: true)]])
        let manager = PluginManagerModel(cacheURL: dir.file("plugins.json"), scannerURL: nil, discovery: discovery, scanner: scanner)
        #expect(manager.usable.isEmpty && manager.isLoaded)
        manager.scan()
        #expect(manager.isScanning)
        await manager.scanTask?.value
        #expect(!manager.isScanning && manager.error == nil)
        #expect(manager.usable.map(\.name) == ["Alpha", "Bravo Synth"] && manager.usable[1].isInstrument)
        #expect(manager.blocked.map(\.name) == ["Crash"] && manager.blocked[0].blockedReason == "scanner crashed (SIGSEGV)")
        #expect(manager.lastScan == .init(scanned: 3, unchanged: 0, removed: 0))
        // PLUG-004: unchanged candidates (blocked ones included) aren't scanned again.
        manager.scan()
        await manager.scanTask?.value
        #expect(scanner.scanned.count == 3 && manager.lastScan == .init(scanned: 0, unchanged: 3, removed: 0))
        // Retry: the blocked plugin gets another scan (it works now).
        scanner.set("/c.vst3", [ok("/c.vst3", "Crash Fixed")])
        manager.retryBlocked([manager.blocked[0].identifier])
        await manager.scanTask?.value
        #expect(manager.blocked.isEmpty && manager.usable.map(\.name).contains("Crash Fixed"))
        #expect(scanner.scanned.count == 4)
        // A vanished plugin drops out; rescan scans everything again.
        discovery.candidatesList = [vst3("/a.vst3", "Alpha"), vst3("/b.vst3", "Bravo")]
        manager.rescanAll()
        await manager.scanTask?.value
        #expect(scanner.scanned.count == 6 && manager.usable.map(\.name) == ["Alpha", "Bravo Synth"])
        // The cache persists: a new manager reads it without scanning.
        let reread = PluginManagerModel(cacheURL: dir.file("plugins.json"), scannerURL: nil, discovery: discovery, scanner: scanner)
        #expect(reread.usable.map(\.name) == ["Alpha", "Bravo Synth"] && scanner.scanned.count == 6)
    }

    @Test("UI-041: without the scanner helper a scan reports the error and caches nothing")
    func missingScanner() async throws {
        let dir = try TempDir()
        let manager = PluginManagerModel(cacheURL: dir.file("plugins.json"), scannerURL: nil,
                                         discovery: FakeDiscovery([vst3("/a.vst3", "Alpha")]))
        manager.scan()
        await manager.scanTask?.value
        #expect(manager.error?.contains("Plugin scanner unavailable") == true && manager.plugins.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.file("plugins.json").path))
    }

    @Test("UI-041, UI-052: the panel's controls (scan, rescan, retry) and ui.state pluginManager; scans disabled while one runs")
    func panelControlsAndState() async throws {
        let dir = try TempDir()
        let scanner = FakeScanner(["/a.vst3": [ok("/a.vst3", "Alpha")]])
        let manager = PluginManagerModel(cacheURL: dir.file("plugins.json"), scannerURL: URL(fileURLWithPath: "/x/PluginScanner"),
                                         discovery: FakeDiscovery([vst3("/a.vst3", "Alpha"), vst3("/z.vst3", "Zap")]), scanner: scanner)
        let (window, _) = try makeWindow()
        window.pluginPanel.manager = manager
        #expect(window.controls.filter { $0.id.hasPrefix("prefs.plugins") }.map(\.id) == ["prefs.plugins"])
        try window.control("prefs.plugins").action()
        #expect(window.pluginPanel.isOpen)
        try window.control("prefs.plugins.scan").action()
        #expect(try window.control("prefs.plugins.scan").isEnabled == false && (try window.control("prefs.plugins.rescan")).isEnabled == false)
        await manager.scanTask?.value
        let ids = window.controls.filter { $0.id.hasPrefix("prefs.plugins") }.map(\.id)
        #expect(ids == ["prefs.plugins", "prefs.plugins.close", "prefs.plugins.scan", "prefs.plugins.rescan", "prefs.plugins.blocked.retry", "prefs.plugins.blocked.0.retry"])
        let state = UIStateDumper.dump(window.pluginPanel)
        #expect(state["open"] == true && state["scanning"] == false && state["scannerPath"] == "/x/PluginScanner")
        #expect(state["plugins"]?[0]?["name"] == "Alpha" && state["plugins"]?[0]?["format"] == "vst3")
        #expect(state["blocked"]?[0]?["name"] == "Zap" && state["blocked"]?[0]?["reason"] == "scanner crashed (SIGSEGV)")
        #expect(state["lastScan"]?["scanned"] == 2)
        // The picker offers what the manager has (effects only).
        #expect(window.deviceChain.choices.last?.name == "Alpha")
        try window.control("prefs.plugins.close").action()
        #expect(!window.pluginPanel.isOpen)
    }

    @Test("UI-041, CONV §9: a tool-launched app works on its own copy of the scan cache under $TMPDIR; a person's app on the user's cache")
    func automatedCacheCopy() throws {
        let dir = try TempDir()
        let user = dir.file("user/plugins.json")
        try FileManager.default.createDirectory(at: user.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: user)
        #expect(PluginManagerModel.sharedCacheURL(automated: false, userCache: user) == user)
        let pid = Int32.random(in: 900_000...999_999)
        let copy = PluginManagerModel.sharedCacheURL(automated: true, pid: pid, userCache: user)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        #expect(copy != user && copy.path.contains("EmberStudio-Plugins-\(pid)"))
        #expect(FileManager.default.contents(atPath: copy.path) == Data("{}".utf8), "seeded from the user's cache")
    }
}
