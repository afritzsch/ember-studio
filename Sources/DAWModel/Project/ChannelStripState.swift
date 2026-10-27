/// The channel strip of a track, bus or master (MIX-005). Gain and pan are param slots in the
/// engine (D-09); these are the values the slots start from.
public struct ChannelStripState: Hashable, Sendable, Codable {
    /// Linear amplitude: 1 is 0 dB, 0 is −∞ (kept linear so JSON never has to hold −∞).
    public var gain: Float
    /// −1 (left) … 1 (right).
    public var pan: Float
    public var mute: Bool
    public var solo: Bool
    public var phaseInvert: Bool

    public init(gain: Float = 1, pan: Float = 0, mute: Bool = false, solo: Bool = false, phaseInvert: Bool = false) {
        self.gain = gain
        self.pan = pan
        self.mute = mute
        self.solo = solo
        self.phaseInvert = phaseInvert
    }
}
