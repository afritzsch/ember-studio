import Foundation

/// PLUG-004: the scan cache, `~/Library/Application Support/macDAW/plugins.json`. One entry per
/// candidate, keyed by path + mtime + version, holding what the scanner reported for it. Blocked
/// plugins are cached like any other result, which is what keeps them from being rescanned.
public struct PluginCache: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public struct Entry: Codable, Equatable, Sendable {
        public var format: PluginFormat
        public var path: String
        public var mtime: Double
        public var version: String
        public var plugins: [PluginDescriptor]

        public init(candidate: PluginCandidate, plugins: [PluginDescriptor]) {
            format = candidate.format
            path = candidate.path
            mtime = candidate.mtime
            version = candidate.version
            self.plugins = plugins
        }

        /// PLUG-004: an entry is still valid for a candidate with the same path, mtime and version.
        public func matches(_ candidate: PluginCandidate) -> Bool {
            format == candidate.format && path == candidate.path
                && mtime == candidate.mtime && version == candidate.version
        }
    }

    public var formatVersion: Int
    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        formatVersion = Self.currentFormatVersion
        self.entries = entries
    }

    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "macDAW/plugins.json")
    }

    /// A missing, unreadable or incompatible file yields an empty cache, which only costs a full
    /// rescan.
    public static func load(from url: URL) -> PluginCache {
        guard let data = try? Data(contentsOf: url),
            let cache = try? JSONDecoder().decode(PluginCache.self, from: data),
            cache.formatVersion == currentFormatVersion
        else { return PluginCache() }
        return cache
    }

    public func save(to url: URL) throws(PluginCatalogError) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            throw .cacheWriteFailed("\(url.path): \(error.localizedDescription)")
        }
    }
}
