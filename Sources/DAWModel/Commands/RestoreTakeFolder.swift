/// T-080 (REC-030): puts a take folder back with its own IDs (takes, clips, notes) at `index` of
/// the track's folders: the inverse of `RemoveTakeFolder` and the redo of `CreateTakeFolder`.
/// Checked like any input (MODEL-031): the IDs must be unused, the takes must match the track's
/// kind and use existing assets, and the comp must be valid (REC-031).
public struct RestoreTakeFolder: Command {
    public static let type = "RestoreTakeFolder"

    public var trackID: NodeIDValue
    public var index: Int
    public var folder: TakeFolder

    public init(trackID: NodeIDValue, index: Int, folder: TakeFolder) {
        self.trackID = trackID
        self.index = index
        self.folder = folder
    }

    public var label: String { "Restore Take Folder" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let track = project.track(trackID) else { throw .notFound(kind: "track", id: trackID) }
        guard (0...track.takeFolders.count).contains(index) else {
            throw .invalidArgument("folder index \(index) is outside 0…\(track.takeFolders.count)")
        }
        do { try folder.validate(on: track.kind) } catch { throw .invalidArgument("take folder: \(error)") }
        for take in folder.takes {
            if case .audio(let clip) = take.clip, project.asset(clip.assetID) == nil {
                throw .notFound(kind: "asset", id: clip.assetID)
            }
        }
        try project.claimIDs(folder.forEachID)
        try project.updateTrack(trackID) { $0.takeFolders.insert(folder, at: index) }
        return RemoveTakeFolder(folderID: folder.id)
    }
}
