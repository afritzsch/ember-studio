/// MODEL-005: an audio clip's gain, linear 0…+12 dB. Part of the clip's data in the graph, so it
/// rebuilds the clip player (DW-072), unlike a fader.
public struct SetClipGain: Command {
    public static let type = "SetClipGain"

    public var clipID: ModelID
    public var gain: Float

    public init(clipID: ModelID, gain: Float) {
        self.clipID = clipID
        self.gain = gain
    }

    public var label: String { "Set Clip Gain" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        try checkClipGain(gain)
        let old = try project.updateAudioClip(clipID) { clip in
            defer { clip.gain = gain }
            return clip.gain
        }
        return SetClipGain(clipID: clipID, gain: old)
    }
}
