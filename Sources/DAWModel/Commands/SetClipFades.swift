/// MODEL-005: an audio clip's linear fade-in and fade-out, in ticks. Each must fit in the clip;
/// they may overlap (the clip player applies both there).
public struct SetClipFades: Command {
    public static let type = "SetClipFades"

    public var clipID: ModelID
    public var fadeIn: Tick
    public var fadeOut: Tick

    public init(clipID: ModelID, fadeIn: Tick, fadeOut: Tick) {
        self.clipID = clipID
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    public var label: String { "Set Clip Fades" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        let old = try project.updateAudioClip(clipID) { (clip: inout AudioClip) throws(DAWError) -> (Tick, Tick) in
            try checkFades(fadeIn: fadeIn, fadeOut: fadeOut, length: clip.length)
            defer { (clip.fadeIn, clip.fadeOut) = (fadeIn, fadeOut) }
            return (clip.fadeIn, clip.fadeOut)
        }
        return SetClipFades(clipID: clipID, fadeIn: old.0, fadeOut: old.1)
    }
}
