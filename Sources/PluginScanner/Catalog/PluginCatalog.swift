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

    /// PLUG-004: rescan only new or changed candidates, drop vanished ones, save the cache.
    /// Blocked entries are kept as long as their key matches, so they are not retried.
    @discardableResult
    public mutating func refresh() throws(PluginCatalogError) -> RefreshSummary {
        var summary = RefreshSummary()
        var entries: [PluginCache.Entry] = []
        let current = discovery.candidates()
        for candidate in current {
            if let cached = cache.entries.first(where: { $0.matches(candidate) }) {
                entries.append(cached)
                summary.unchanged += 1
            } else {
                entries.append(PluginCache.Entry(candidate: candidate, plugins: try scanner.scan(candidate)))
                summary.scanned.append(candidate)
            }
        }
        struct Location: Hashable { var format: PluginFormat; var path: String }
        let present = Set(current.map { Location(format: $0.format, path: $0.path) })
        summary.removed = cache.entries.count { !present.contains(Location(format: $0.format, path: $0.path)) }
        cache.entries = entries
        try cache.save(to: cacheURL)
        return summary
    }

    /// PLUG-004: the user-resettable blocked list. Forgets the cache entries holding blocked
    /// plugins (all of them, or those whose identifier is in `identifiers`) so the next
    /// `refresh()` scans them again.
    public mutating func resetBlocked(identifiers: Set<String>? = nil) throws(PluginCatalogError) {
        cache.entries.removeAll { entry in
            entry.plugins.contains { plugin in
                plugin.status == .blocked && (identifiers?.contains(plugin.identifier) ?? true)
            }
        }
        try cache.save(to: cacheURL)
    }
}
