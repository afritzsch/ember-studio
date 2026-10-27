/// Something discovery found that the scanner can be pointed at, keyed the way the cache keys
/// its entries (PLUG-004: path + mtime + version). Discovery never loads plugin code.
public struct PluginCandidate: Codable, Hashable, Sendable {
    public var format: PluginFormat
    /// VST3: the bundle path. AU: the component identifier, because the component manager does
    /// not expose a file location for audio units (AUv3 extensions have none of their own).
    public var path: String
    /// Modification time in seconds since 1970. Always 0 for AUs, where `version` is the key.
    public var mtime: Double
    public var version: String
    /// Display name used for blocked entries, when the scanner can't report one.
    public var name: String

    public init(format: PluginFormat, path: String, mtime: Double, version: String, name: String) {
        self.format = format
        self.path = path
        self.mtime = mtime
        self.version = version
        self.name = name
    }

    /// Command-line arguments that make `PluginScanner` scan this candidate.
    public var scannerArguments: [String] {
        switch format {
        case .au: ["--au", path]
        case .vst3: ["--vst3", path]
        }
    }
}
