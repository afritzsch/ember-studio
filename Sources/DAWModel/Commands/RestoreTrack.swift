/// Puts a whole track back with its own IDs: the inverse of `RemoveTrack` and the redo of
/// `AddTrack`, so commands further along the history still find the IDs they name. It checks the
/// track like any input (MODEL-031): its IDs must be unused, its contents valid, its routing
/// existing and acyclic.
public struct RestoreTrack: Command {
    public static let type = "RestoreTrack"

    public var track: Track
    /// 0…track count.
    public var index: Int

    public init(track: Track, index: Int) {
        self.track = track
        self.index = index
    }

    public var label: String { "Restore Track" }

    /// DW-334: the track snapshot's clips, takes and zones follow a session-rate change.
    public func rescaled(from: Double, to: Double) -> any Command {
        RestoreTrack(track: track.rescaled(from: from, to: to), index: index)
    }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard (0...project.tracks.count).contains(index) else {
            throw .invalidArgument("track index \(index) is outside 0…\(project.tracks.count)")
        }
        try track.validateContents()
        try project.claimIDs(track.forEachID)
        project.tracks.insert(track, at: index)
        try project.validateRouting()
        return RemoveTrack(trackID: track.id)
    }
}
