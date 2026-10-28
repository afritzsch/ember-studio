/// MODEL-005 (catalogue entry). Routing commands are T-022; clips, notes and the rest come with T-030/T-042.
public struct RenameTrack: Command {
    public static let type = "RenameTrack"

    public var trackID: NodeIDValue
    public var name: String

    public init(trackID: NodeIDValue, name: String) {
        self.trackID = trackID
        self.name = name
    }

    public var label: String { "Rename Track" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        let oldName = try project.updateTrack(trackID) { track in
            defer { track.name = name }
            return track.name
        }
        return RenameTrack(trackID: trackID, name: oldName)
    }
}
