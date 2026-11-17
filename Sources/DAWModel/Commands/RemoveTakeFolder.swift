/// T-080 (REC-030): removes a take folder with its takes. The inverse of `CreateTakeFolder`; its
/// inverse `RestoreTakeFolder` puts the folder back with its IDs, at its index. The takes' files
/// and assets stay (like `RemoveClip`).
public struct RemoveTakeFolder: Command {
    public static let type = "RemoveTakeFolder"

    public var folderID: ModelID

    public init(folderID: ModelID) {
        self.folderID = folderID
    }

    public var label: String { "Remove Take Folder" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let (trackID, index) = project.takeFolderLocation(folderID) else {
            throw .notFound(kind: "take folder", id: folderID)
        }
        let folder = try project.updateTrack(trackID) { $0.takeFolders.remove(at: index) }
        return RestoreTakeFolder(trackID: trackID, index: index, folder: folder)
    }
}
