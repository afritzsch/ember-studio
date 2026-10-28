/// Replaces a clip with the one of the same ID, on its track: the undo and redo of `SplitClip`.
/// The new clip is checked like any input (MODEL-031); note IDs it adds must be unused.
public struct SetClip: Command {
    public static let type = "SetClip"

    public var clip: Clip

    public init(clip: Clip) {
        self.clip = clip
    }

    public var label: String { "Edit Clip" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let (track, index) = project.clipLocation(clip.id) else { throw .notFound(kind: "clip", id: clip.id) }
        let old = try project.updateTrack(track) { $0.clips.remove(at: index) }
        try project.insertClip(clip, into: track)
        return SetClip(clip: old)
    }
}
