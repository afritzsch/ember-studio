/// MODEL-005: removes a clip (with its notes).
public struct RemoveClip: Command {
    public static let type = "RemoveClip"

    public var clipID: ModelID

    public init(clipID: ModelID) {
        self.clipID = clipID
    }

    public var label: String { "Remove Clip" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let (track, index) = project.clipLocation(clipID) else { throw .notFound(kind: "clip", id: clipID) }
        let clip = try project.updateTrack(track) { $0.clips.remove(at: index) }
        return RestoreClip(trackID: track, clip: clip)
    }
}
