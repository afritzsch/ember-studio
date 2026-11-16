/// T-080 (REC-033): sets a take folder's comp exactly: the inverse of `SetCompSelection` (and of
/// itself). Checked like any input (REC-031): sorted, gapless over the folder range, merged, and
/// naming the folder's takes.
public struct RestoreComp: Command {
    public static let type = "RestoreComp"

    public var folderID: ModelID
    public var comp: [CompSegment]

    public init(folderID: ModelID, comp: [CompSegment]) {
        self.folderID = folderID
        self.comp = comp
    }

    public var label: String { "Restore Comp" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let (trackID, _) = project.takeFolderLocation(folderID),
              let kind = project.track(trackID)?.kind else { throw .notFound(kind: "take folder", id: folderID) }
        let old = try project.updateTakeFolder(folderID) { (folder: inout TakeFolder) throws(DAWError) -> [CompSegment] in
            let old = folder.comp
            folder.comp = comp
            do { try folder.validate(on: kind) } catch { throw .invalidArgument("comp: \(error)") }
            return old
        }
        return RestoreComp(folderID: folderID, comp: old)
    }
}
