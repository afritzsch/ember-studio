/// Puts a clip back with its own IDs (notes included): the inverse of `RemoveClip` and the redo of
/// `AddClip` (see `RestoreTrack`). Its place follows from the clip order (DW-110). Checked like
/// any input (MODEL-031).
public struct RestoreClip: Command {
    public static let type = "RestoreClip"

    public var trackID: NodeIDValue
    public var clip: Clip

    public init(trackID: NodeIDValue, clip: Clip) {
        self.trackID = trackID
        self.clip = clip
    }

    public var label: String { "Restore Clip" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        try project.insertClip(clip, into: trackID)
        return RemoveClip(clipID: clip.id)
    }
}
