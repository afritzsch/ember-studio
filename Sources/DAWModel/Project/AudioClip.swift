/// A view into an asset, placed on the timeline. Field names follow `ClipDesc` (05 Interfaces).
/// Audio clips move with tempo changes but don't stretch (D-06).
public struct AudioClip: Identifiable, Hashable, Sendable, Codable {
    public var id: ModelID
    public var assetID: ModelID
    public var start: Tick
    public var length: Tick
    /// Where in the asset the clip starts, in samples at the session rate.
    public var sourceOffsetSamples: Int64
    /// Linear amplitude.
    public var gain: Float
    public var fadeIn: Tick
    public var fadeOut: Tick

    public init(
        id: ModelID, assetID: ModelID, start: Tick, length: Tick, sourceOffsetSamples: Int64 = 0,
        gain: Float = 1, fadeIn: Tick = 0, fadeOut: Tick = 0
    ) {
        self.id = id
        self.assetID = assetID
        self.start = start
        self.length = length
        self.sourceOffsetSamples = sourceOffsetSamples
        self.gain = gain
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }
}
