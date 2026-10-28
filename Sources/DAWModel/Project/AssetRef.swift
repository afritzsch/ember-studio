/// An audio file the project uses. Decoded into RAM by the engine (D-10), resampled to the session
/// rate if needed (D-27); the original file is kept as is.
public struct AssetRef: Identifiable, Hashable, Sendable, Codable {
    public var id: ModelID
    /// Relative to the project folder (MODEL-040) when the file is inside it (imported into
    /// `Audio/`), otherwise absolute: a referenced file, or a project with no folder yet (T-030).
    public var path: String
    public var channels: Int
    public var originalSampleRate: Double
    /// Length in frames at `originalSampleRate`.
    public var frames: Int64

    public init(id: ModelID, path: String, channels: Int, originalSampleRate: Double, frames: Int64) {
        self.id = id
        self.path = path
        self.channels = channels
        self.originalSampleRate = originalSampleRate
        self.frames = frames
    }
}
