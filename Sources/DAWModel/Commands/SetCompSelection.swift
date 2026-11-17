/// MODEL-005, REC-033 (T-080): `[start, end)` of a take folder plays take `takeID`. The comp's
/// segments are cut at `start` and `end`, the range gets the take, and neighbouring segments of
/// the same take merge (REC-031 keeps the comp gapless and merged). The range must lie inside the
/// folder and the take must be one of its own. Undoable: the inverse is `RestoreComp` with the
/// comp as it was.
public struct SetCompSelection: Command {
    public static let type = "SetCompSelection"

    public var folderID: ModelID
    public var start: Tick
    public var end: Tick
    public var takeID: ModelID

    public init(folderID: ModelID, start: Tick, end: Tick, takeID: ModelID) {
        self.folderID = folderID
        self.start = start
        self.end = end
        self.takeID = takeID
    }

    public var label: String { "Select Take" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let folder = project.takeFolder(folderID) else { throw .notFound(kind: "take folder", id: folderID) }
        guard folder.take(takeID) != nil else { throw .notFound(kind: "take", id: takeID) }
        guard start < end, start >= folder.start, end <= folder.end else {
            throw .invalidArgument("range [\(start.raw), \(end.raw)) isn't a range inside the folder's [\(folder.start.raw), \(folder.end.raw))")
        }
        let old = folder.comp
        try project.updateTakeFolder(folderID) { $0.comp = folder.comp(selecting: takeID, from: start, to: end) }
        return RestoreComp(folderID: folderID, comp: old)
    }
}
