/// MODEL-005: moves a clip to a new start, optionally onto another track of the same kind. The
/// audio moves with the clip (its source offset stays); MIDI notes are relative to the clip and
/// move with it. Positions are absolute, so a drag's steps coalesce into one undo entry (MODEL-003).
public struct MoveClip: Command {
    public static let type = "MoveClip"

    public var clipID: ModelID
    public var start: Tick
    /// Default: the clip's own track.
    public var trackID: NodeIDValue?

    public init(clipID: ModelID, start: Tick, trackID: NodeIDValue? = nil) {
        self.clipID = clipID
        self.start = start
        self.trackID = trackID
    }

    public var label: String { "Move Clip" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let (from, index) = project.clipLocation(clipID) else { throw .notFound(kind: "clip", id: clipID) }
        let to = trackID ?? from
        guard let target = project.track(to) else { throw .notFound(kind: "track", id: to) }
        var clip = try project.updateTrack(from) { $0.clips.remove(at: index) }
        let oldStart = clip.start
        clip.start = start
        try project.checkClipFits(clip, on: target)
        try project.updateTrack(to) { track in
            track.clips.append(clip)
            track.sortClips()
        }
        return MoveClip(clipID: clipID, start: oldStart, trackID: to == from ? nil : from)
    }
}
