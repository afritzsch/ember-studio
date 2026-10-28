/// MODEL-005: moves a track so it ends up at `index` in the track list.
public struct MoveTrack: Command {
    public static let type = "MoveTrack"

    public var trackID: NodeIDValue
    /// The track's new position, 0…track count − 1.
    public var index: Int

    public init(trackID: NodeIDValue, index: Int) {
        self.trackID = trackID
        self.index = index
    }

    public var label: String { "Move Track" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let old = project.trackIndex(trackID) else { throw .notFound(kind: "track", id: trackID) }
        guard project.tracks.indices.contains(index) else {
            throw .invalidArgument("track index \(index) is outside 0…\(project.tracks.count - 1)")
        }
        project.tracks.insert(project.tracks.remove(at: old), at: index)
        return MoveTrack(trackID: trackID, index: old)
    }
}
