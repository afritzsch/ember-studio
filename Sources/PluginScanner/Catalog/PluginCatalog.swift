import Foundation

public enum PluginCatalogError: Error, Equatable, Sendable {
    case scannerUnavailable(String)
    case cacheWriteFailed(String)
}

/// The DAW's view of installed plugins: discovery + scanner + cache (PLUG-001..004). Plugin code
/// is never loaded in the calling process; scans go through `scanner`.
public struct PluginCatalog: Sendable {
    public struct RefreshSummary: Equatable, Sendable {
        /// Candidates that were new or changed, in scan order.
        public var scanned: [PluginCandidate] = []
        public var unchanged = 0
        public var removed = 0
    }

    public let cacheURL: URL
    public private(set) var cache: PluginCache
    let discovery: any PluginDiscovering
    let scanner: any PluginScanning

    public init(
        cacheURL: URL = PluginCache.defaultURL,
        discovery: any PluginDiscovering = SystemPluginDiscovery(),
        scanner: any PluginScanning
    ) {
        self.cacheURL = cacheURL
        self.discovery = discovery
        self.scanner = scanner
        cache = PluginCache.load(from: cacheURL)
    }

    /// Every cached descriptor, blocked ones included.
    public var descriptors: [PluginDescriptor] { cache.entries.flatMap(\.plugins) }
    /// Plugins the DAW may instantiate.
    public var plugins: [PluginDescriptor] { descriptors.filter { $0.status == .ok } }
    /// PLUG-001: plugins that crashed, hung or failed during their scan.
    public var blocked: [PluginDescriptor] { descriptors.filter { $0.status == .blocked } }

    /// DW-018 (T-094): how many scanner processes run at once. Each candidate still gets a process
    /// of its own (PLUG-001), so a hanging plugin costs one worker its timeout, not the whole scan.
    public var maxConcurrentScans = 4

    /// PLUG-004: rescan only new or changed candidates, drop vanished ones, save the cache.
    /// Blocked entries are kept as long as their key matches, so they are not retried.
    /// Candidates are scanned up to `maxConcurrentScans` at a time (DW-018); the cache and the
    /// summary list them in discovery order either way.
    @discardableResult
    public mutating func refresh() throws(PluginCatalogError) -> RefreshSummary {
        try refresh(retrying: [], timeout: nil)
    }

    /// PLUG-001/004 (T-094, DW-275): forgets blocked plugins (those whose identifier is in
    /// `identifiers`, or all of them) and refreshes, scanning those again with `timeout` (nil: the
    /// scanner's own limit). Other new or changed candidates are scanned as `refresh()` would.
    @discardableResult
    public mutating func retryBlocked(identifiers: Set<String>? = nil, timeout: TimeInterval? = nil)
        throws(PluginCatalogError) -> RefreshSummary {
        let retried = forgetBlocked(identifiers: identifiers)
        return try refresh(retrying: retried, timeout: timeout)
    }

    private struct Location: Hashable {
        var format: PluginFormat
        var path: String
    }

    private mutating func refresh(retrying: Set<Location>, timeout: TimeInterval?) throws(PluginCatalogError) -> RefreshSummary {
        var summary = RefreshSummary()
        let current = discovery.candidates()
        var entries: [PluginCache.Entry?] = []
        var pending: [(slot: Int, candidate: PluginCandidate, timeout: TimeInterval?)] = []
        for candidate in current {
            if let cached = cache.entries.first(where: { $0.matches(candidate) }) {
                entries.append(cached)
                summary.unchanged += 1
            } else {
                let location = Location(format: candidate.format, path: candidate.path)
                pending.append((entries.count, candidate, retrying.contains(location) ? timeout : nil))
                entries.append(nil)
                summary.scanned.append(candidate)
            }
        }
        let results = try Self.scanAll(pending.map { ($0.candidate, $0.timeout) }, with: scanner, limit: maxConcurrentScans)
        for (job, plugins) in zip(pending, results) {
            entries[job.slot] = PluginCache.Entry(candidate: job.candidate, plugins: plugins)
        }
        let present = Set(current.map { Location(format: $0.format, path: $0.path) })
        summary.removed = cache.entries.count { !present.contains(Location(format: $0.format, path: $0.path)) }
        cache.entries = entries.compactMap { $0 }
        try cache.save(to: cacheURL)
        return summary
    }

    /// DW-018: runs the scans on up to `limit` threads, results in input order. The first error
    /// (a scanner that can't run) stops handing out work and is thrown once the running scans end.
    private static func scanAll(_ jobs: [(PluginCandidate, TimeInterval?)], with scanner: any PluginScanning,
                                limit: Int) throws(PluginCatalogError) -> [[PluginDescriptor]] {
        guard !jobs.isEmpty else { return [] }
        let state = ScanState(count: jobs.count)
        let workers = min(max(limit, 1), jobs.count)
        // Threads of their own: a scan mostly waits on the scanner process. concurrentPerform sizes
        // itself to the idle cores, so on a busy 3-core CI runner it ran the scans one at a time.
        let done = DispatchGroup()
        for _ in 0..<workers {
            done.enter()
            Thread.detachNewThread {
                defer { done.leave() }
                while let index = state.next() {
                    let (candidate, timeout) = jobs[index]
                    do throws(PluginCatalogError) {
                        let plugins = if let timeout { try scanner.scan(candidate, timeout: timeout) } else { try scanner.scan(candidate) }
                        state.finish(index, plugins)
                    } catch {
                        state.fail(error)
                    }
                }
            }
        }
        done.wait()
        return try state.results()
    }

    /// PLUG-004: the user-resettable blocked list. Forgets the cache entries holding blocked
    /// plugins (all of them, or those whose identifier is in `identifiers`) so the next
    /// `refresh()` scans them again.
    public mutating func resetBlocked(identifiers: Set<String>? = nil) throws(PluginCatalogError) {
        forgetBlocked(identifiers: identifiers)
        try cache.save(to: cacheURL)
    }

    /// The locations of the entries it removed.
    @discardableResult
    private mutating func forgetBlocked(identifiers: Set<String>?) -> Set<Location> {
        var forgotten = Set<Location>()
        cache.entries.removeAll { entry in
            let hit = entry.plugins.contains { plugin in
                plugin.status == .blocked && (identifiers?.contains(plugin.identifier) ?? true)
            }
            if hit { forgotten.insert(Location(format: entry.format, path: entry.path)) }
            return hit
        }
        return forgotten
    }
}

/// DW-018: the shared bookkeeping of one parallel scan (`PluginCatalog.scanAll`).
private final class ScanState: @unchecked Sendable {
    private let lock = NSLock()
    private var nextIndex = 0
    private var outputs: [[PluginDescriptor]?]
    private var error: PluginCatalogError?

    init(count: Int) { outputs = Array(repeating: nil, count: count) }

    /// The next job to run, or nil when all are handed out or one failed.
    func next() -> Int? {
        lock.withLock {
            guard error == nil, nextIndex < outputs.count else { return nil }
            defer { nextIndex += 1 }
            return nextIndex
        }
    }

    func finish(_ index: Int, _ plugins: [PluginDescriptor]) { lock.withLock { outputs[index] = plugins } }

    func fail(_ failure: PluginCatalogError) { lock.withLock { if error == nil { error = failure } } }

    func results() throws(PluginCatalogError) -> [[PluginDescriptor]] {
        let (outputs, error) = lock.withLock { (self.outputs, self.error) }
        if let error { throw error }
        return outputs.map { $0 ?? [] }
    }
}
