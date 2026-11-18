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

/// Records which candidates were scanned. Paths containing "Crash" come back blocked, and paths
/// containing "Slow" time out unless given a time limit of their own, as the real launcher would
/// report them. Scans may run in parallel (DW-018), so the log is kept sorted.
final class RecordingScanner: PluginScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var limits: [String: TimeInterval] = [:]
    private var running = 0
    private var peak = 0
    /// How long each scan takes (to see scans overlap).
    var delay: TimeInterval = 0

    /// The scanned paths, sorted (scan order isn't defined with parallel scans).
    var scannedPaths: [String] { lock.withLock { log.sorted() } }
    /// T-094: the time limits passed with `scan(_:timeout:)`, by path.
    var timeouts: [String: TimeInterval] { lock.withLock { limits } }
    /// DW-018: the most scans that ran at once.
    var peakConcurrency: Int { lock.withLock { peak } }
    func clear() { lock.withLock { log.removeAll(); limits.removeAll(); peak = 0 } }

    func scan(_ candidate: PluginCandidate, timeout: TimeInterval) throws(PluginCatalogError) -> [PluginDescriptor] {
        lock.withLock { limits[candidate.path] = timeout }
        return try scan(candidate, limited: true)
    }

    func scan(_ candidate: PluginCandidate) throws(PluginCatalogError) -> [PluginDescriptor] {
        try scan(candidate, limited: false)
    }

    private func scan(_ candidate: PluginCandidate, limited: Bool) throws(PluginCatalogError) -> [PluginDescriptor] {
        lock.withLock {
            log.append(candidate.path)
            running += 1
            peak = max(peak, running)
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.withLock { running -= 1 }
        if candidate.path.contains("Crash") {
            return [.blocked(candidate, reason: "scanner crashed (SIGSEGV)")]
        }
        if candidate.path.contains("Slow") && !limited {
            return [.timedOut(candidate, after: ScannerLauncher.defaultTimeout)]
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

    // MARK: T-094 (DW-018, DW-275)

    @Test("DW-018: up to 4 candidates scan at once; the cache and summary keep discovery order")
    func parallelScans() throws {
        let dir = try TestDirectory()
        let paths = (0..<10).map { "/P/Plugin\($0).vst3" }
        let scanner = RecordingScanner()
        scanner.delay = 0.3
        var catalog = PluginCatalog(cacheURL: dir.path("plugins.json"), discovery: FakeDiscovery(paths.map { .vst3($0) }), scanner: scanner)
        #expect(catalog.maxConcurrentScans == 4)
        let start = Date()
        let summary = try catalog.refresh()
        #expect(scanner.peakConcurrency <= 4)
        #expect(scanner.peakConcurrency >= 2, "scans overlap")
        #expect(Date().timeIntervalSince(start) < 10 * 0.3, "faster than one at a time")
        #expect(summary.scanned.map(\.path) == paths)
        #expect(catalog.cache.entries.map(\.path) == paths)
        #expect(scanner.scannedPaths == paths.sorted())

        // One at a time when asked.
        let serialDir = try TestDirectory()
        scanner.clear()
        scanner.delay = 0.05
        var serial = PluginCatalog(cacheURL: serialDir.path("plugins.json"), discovery: FakeDiscovery(paths.map { .vst3($0) }), scanner: scanner)
        serial.maxConcurrentScans = 1
        try serial.refresh()
        #expect(scanner.peakConcurrency == 1)
        #expect(serial.cache.entries.map(\.path) == paths)
    }

    @Test("DW-018: a scanner that can't run fails the parallel scan and caches nothing")
    func parallelScanFailure() throws {
        let dir = try TestDirectory()
        let cacheURL = dir.path("plugins.json")
        let discovery = FakeDiscovery((0..<9).map { .vst3("/P/P\($0).vst3") })
        var catalog = PluginCatalog(cacheURL: cacheURL, discovery: discovery, scanner: FailingScanner())
        #expect(throws: PluginCatalogError.scannerUnavailable("test")) { try catalog.refresh() }
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test("PLUG-001 (DW-275): a timed-out plugin is retried with the longer limit; other new plugins scan as usual")
    func retryTimedOut() throws {
        let dir = try TestDirectory()
        let discovery = FakeDiscovery([.vst3("/P/A.vst3"), .vst3("/P/Slow.vst3"), .vst3("/P/Crash.vst3")])
        let scanner = RecordingScanner()
        var catalog = PluginCatalog(cacheURL: dir.path("plugins.json"), discovery: discovery, scanner: scanner)
        try catalog.refresh()
        #expect(catalog.blocked.map(\.identifier) == ["/P/Slow.vst3", "/P/Crash.vst3"])
        #expect(catalog.blocked.map(\.isTimedOut) == [true, false])
        #expect(catalog.blocked.first?.reason == "timed out after 30 s")
        #expect(scanner.timeouts.isEmpty)

        // A new plugin appears meanwhile; only the retried one gets the long limit.
        discovery.candidatesToReport.append(.vst3("/P/New.vst3"))
        scanner.clear()
        let summary = try catalog.retryBlocked(identifiers: ["/P/Slow.vst3"], timeout: ScannerLauncher.retryTimeout)
        #expect(scanner.scannedPaths == ["/P/New.vst3", "/P/Slow.vst3"])
        #expect(scanner.timeouts == ["/P/Slow.vst3": 120])
        #expect(summary.scanned.map(\.path) == ["/P/Slow.vst3", "/P/New.vst3"])
        #expect(catalog.blocked.map(\.identifier) == ["/P/Crash.vst3"])
        #expect(catalog.plugins.map(\.identifier).contains("/P/Slow.vst3#1"))
        // Saved.
        #expect(PluginCache.load(from: dir.path("plugins.json")) == catalog.cache)

        // Without a timeout it is resetBlocked + refresh, at the scanner's own limit.
        scanner.clear()
        try catalog.retryBlocked()
        #expect(scanner.scannedPaths == ["/P/Crash.vst3"])
        #expect(scanner.timeouts.isEmpty)
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
