import Foundation
import PluginCatalog
import Testing

/// Discovery whose results a test can change between refreshes.
final class FakeDiscovery: PluginDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private var current: [PluginCandidate]

    init(_ candidates: [PluginCandidate]) { current = candidates }

    var candidatesToReport: [PluginCandidate] {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func candidates() -> [PluginCandidate] { candidatesToReport }
}

/// Records which candidates were scanned. Paths containing "Crash" come back blocked, as the
/// real launcher would report them.
final class RecordingScanner: PluginScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []

    var scannedPaths: [String] { lock.withLock { log } }
    func clear() { lock.withLock { log.removeAll() } }

    func scan(_ candidate: PluginCandidate) throws(PluginCatalogError) -> [PluginDescriptor] {
        lock.withLock { log.append(candidate.path) }
        if candidate.path.contains("Crash") {
            return [.blocked(candidate, reason: "scanner crashed (SIGSEGV)")]
        }
        return [PluginDescriptor(
            format: candidate.format, identifier: "\(candidate.path)#1", name: candidate.name,
            vendor: "V", version: candidate.version, isInstrument: false, hasSidechain: false,
            numParams: 2)]
    }
}

struct FailingScanner: PluginScanning {
    func scan(_ candidate: PluginCandidate) throws(PluginCatalogError) -> [PluginDescriptor] {
        throw .scannerUnavailable("test")
    }
}

/// PLUG-004: plugins.json keyed by path + mtime + version; only new or changed entries are
/// rescanned; the blocked list is resettable.
@Suite("PLUG-004: plugin cache")
struct PluginCatalogTests {
    @Test("PLUG-004: cache lives at ~/Library/Application Support/Ember Studio/plugins.json")
    func defaultLocation() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(PluginCache.defaultURL.path == "\(home)/Library/Application Support/Ember Studio/plugins.json")
    }

    @Test("PLUG-004: first refresh scans everything and persists the results")
    func firstRefresh() throws {
        let dir = try TestDirectory()
        let cacheURL = dir.path("cache/plugins.json")
        let scanner = RecordingScanner()
        var catalog = PluginCatalog(
            cacheURL: cacheURL,
            discovery: FakeDiscovery([.vst3("/P/A.vst3"), .vst3("/P/Crash.vst3")]),
            scanner: scanner)
        let summary = try catalog.refresh()

        #expect(scanner.scannedPaths == ["/P/A.vst3", "/P/Crash.vst3"])
        #expect(summary.scanned.map(\.path) == ["/P/A.vst3", "/P/Crash.vst3"])
        #expect(catalog.plugins.map(\.identifier) == ["/P/A.vst3#1"])
        #expect(catalog.blocked.map(\.identifier) == ["/P/Crash.vst3"])

        // The file holds the key fields and the scanner's descriptors, and loads back as-is.
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        let entries = try #require(json["entries"] as? [[String: Any]])
        #expect(json["formatVersion"] as? Int == PluginCache.currentFormatVersion)
        #expect(Set(entries[0].keys) == ["format", "path", "mtime", "version", "plugins"])
        #expect(PluginCache.load(from: cacheURL) == catalog.cache)
    }

    @Test("PLUG-004: only new or changed (mtime or version) entries are rescanned")
    func incrementalRefresh() throws {
        let dir = try TestDirectory()
        let cacheURL = dir.path("plugins.json")
        let discovery = FakeDiscovery([
            .vst3("/P/A.vst3"), .vst3("/P/B.vst3"), .vst3("/P/C.vst3"), .vst3("/P/D.vst3"),
        ])
        let scanner = RecordingScanner()
        var catalog = PluginCatalog(cacheURL: cacheURL, discovery: discovery, scanner: scanner)
        try catalog.refresh()
        scanner.clear()

        // Nothing changed: nothing scanned, even with a fresh catalog reading the file.
        var reopened = PluginCatalog(cacheURL: cacheURL, discovery: discovery, scanner: scanner)
        var summary = try reopened.refresh()
        #expect(scanner.scannedPaths.isEmpty)
        #expect(summary.unchanged == 4)

        discovery.candidatesToReport = [
            .vst3("/P/A.vst3"),                     // unchanged
            .vst3("/P/B.vst3", mtime: 2),           // touched
            .vst3("/P/C.vst3", version: "1.1"),     // updated
            .vst3("/P/E.vst3"),                     // new; D was removed
        ]
        summary = try reopened.refresh()
        #expect(scanner.scannedPaths == ["/P/B.vst3", "/P/C.vst3", "/P/E.vst3"])
        #expect(summary.unchanged == 1)
        #expect(summary.removed == 1)
        #expect(reopened.cache.entries.map(\.path) == ["/P/A.vst3", "/P/B.vst3", "/P/C.vst3", "/P/E.vst3"])
        #expect(reopened.cache.entries[2].version == "1.1")
        #expect(PluginCache.load(from: cacheURL) == reopened.cache)
    }

    @Test("PLUG-004: blocked plugins stay blocked until the user resets them")
    func blockedListReset() throws {
        let dir = try TestDirectory()
        let discovery = FakeDiscovery([.vst3("/P/A.vst3"), .vst3("/P/Crash1.vst3"), .vst3("/P/Crash2.vst3")])
        let scanner = RecordingScanner()
        var catalog = PluginCatalog(cacheURL: dir.path("plugins.json"), discovery: discovery, scanner: scanner)
        try catalog.refresh()
        scanner.clear()

        try catalog.refresh()
        #expect(scanner.scannedPaths.isEmpty, "blocked plugins are not retried on every refresh")

        try catalog.resetBlocked(identifiers: ["/P/Crash2.vst3"])
        #expect(catalog.blocked.map(\.identifier) == ["/P/Crash1.vst3"])
        try catalog.refresh()
        #expect(scanner.scannedPaths == ["/P/Crash2.vst3"])

        scanner.clear()
        try catalog.resetBlocked()
        #expect(catalog.blocked.isEmpty)
        // The reset is saved, so it survives a restart.
        var reopened = PluginCatalog(cacheURL: dir.path("plugins.json"), discovery: discovery, scanner: scanner)
        #expect(reopened.blocked.isEmpty)
        try reopened.refresh()
        #expect(scanner.scannedPaths == ["/P/Crash1.vst3", "/P/Crash2.vst3"])
    }

    @Test("PLUG-004: a corrupt or missing cache means a full rescan")
    func corruptCache() throws {
        let dir = try TestDirectory()
        let cacheURL = dir.path("plugins.json")
        #expect(PluginCache.load(from: cacheURL) == PluginCache())
        try Data("{ not json".utf8).write(to: cacheURL)
        let scanner = RecordingScanner()
        var catalog = PluginCatalog(cacheURL: cacheURL, discovery: FakeDiscovery([.vst3("/P/A.vst3")]), scanner: scanner)
        try catalog.refresh()
        #expect(scanner.scannedPaths == ["/P/A.vst3"])
        #expect(PluginCache.load(from: cacheURL) == catalog.cache)
    }

    @Test("PLUG-004: when the scanner can't run, nothing is cached as blocked")
    func scannerUnavailable() throws {
        let dir = try TestDirectory()
        let cacheURL = dir.path("plugins.json")
        var catalog = PluginCatalog(cacheURL: cacheURL, discovery: FakeDiscovery([.vst3("/P/A.vst3")]), scanner: FailingScanner())
        #expect(throws: PluginCatalogError.scannerUnavailable("test")) { try catalog.refresh() }
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
        #expect(catalog.descriptors.isEmpty)
    }

    // MARK: End to end

    @Test("PLUG-001/003/004: real discovery + scanner on fake bundles, crash blocked, touched bundle rescanned")
    func endToEnd() throws {
        let plugins = try TestDirectory()
        let support = try TestDirectory()
        let good = try Fixtures.makeVST3Bundle(named: "Fake Good", in: plugins.url)
        try Fixtures.makeVST3Bundle(named: "Fake Crash", in: plugins.url)
        let discovery = SystemPluginDiscovery(vst3Directories: [plugins.url], includeAudioUnits: false)
        let cacheURL = support.path("Ember Studio/plugins.json")

        var catalog = PluginCatalog(cacheURL: cacheURL, discovery: discovery, scanner: Fixtures.launcher())
        var summary = try catalog.refresh()
        #expect(summary.scanned.count == 2)
        #expect(catalog.plugins.map(\.name) == ["Fake Sidechain Comp", "Fake Synth"])
        #expect(catalog.blocked.map(\.name) == ["Fake Crash"])
        #expect(catalog.blocked.first?.reason == "scanner crashed (SIGSEGV)")

        summary = try catalog.refresh()
        #expect(summary.scanned.isEmpty)
        #expect(summary.unchanged == 2)

        // Simulate an update of the good plugin's binary.
        try Fixtures.setModificationDate(Date(timeIntervalSinceNow: 60), of: good.appending(path: "Contents/MacOS/Fake Good"))
        summary = try catalog.refresh()
        #expect(summary.scanned.map(\.path) == [good.path])
        #expect(catalog.plugins.count == 2)
    }
}
