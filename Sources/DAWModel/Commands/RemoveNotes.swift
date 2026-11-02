/// MODEL-005: removes notes from a MIDI clip. The inverse, `RestoreNotes`, puts them back with
/// their own IDs ("inverses keep IDs", as for clips).
public struct RemoveNotes: Command {
    public static let type = "RemoveNotes"

    public var clipID: ModelID
    public var noteIDs: [ModelID]

    public init(clipID: ModelID, noteIDs: [ModelID]) {
        self.clipID = clipID
        self.noteIDs = noteIDs
    }

    public var label: String { noteIDs.count == 1 ? "Delete Note" : "Delete Notes" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        let indices = try project.midiClip(clipID).noteIndices(noteIDs)
        let removed = try project.updateNotes(ofClip: clipID) { notes in
            let removed = indices.map { notes[$0] }
            let gone = Set(noteIDs)
            notes.removeAll { gone.contains($0.id) }
            return removed
        }
        return RestoreNotes(clipID: clipID, notes: removed)
    }
}
