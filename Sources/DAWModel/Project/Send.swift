/// A send from a track or bus into a bus (MIX-007).
public struct Send: Identifiable, Hashable, Sendable, Codable {
    public var id: ModelID
    /// The receiving bus.
    public var target: NodeIDValue
    /// Linear amplitude, like `ChannelStripState.gain`. A param slot in the engine (D-09).
    public var level: Float
    public var tap: SignalTap

    public init(id: ModelID, target: NodeIDValue, level: Float = 1, tap: SignalTap = .postFader) {
        self.id = id
        self.target = target
        self.level = level
        self.tap = tap
    }
}
