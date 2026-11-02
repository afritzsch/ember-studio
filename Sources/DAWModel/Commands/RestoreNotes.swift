/// Puts notes back into a MIDI clip with their own IDs: the inverse of `RemoveNotes` and the redo
/// of `AddNotes`. Their place follows from the (start, id) order. Checked like any input
/// (MODEL-031): the IDs must be unused and in range, the notes in range.
public struct RestoreNotes: Command {
    public static let type = "RestoreNotes"

    public var clipID: ModelID
    public var notes: [Note]

    public init(clipID: ModelID, notes: [Note]) {
        self.clipID = clipID
        self.notes = notes
    }

    public var label: String { notes.count == 1 ? "Restore Note" : "Restore Notes" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        _ = try project.midiClip(clipID)
        guard !notes.isEmpty else { throw .invalidArgument("no notes given") }
        for note in notes { try note.validate() }
        try project.claimIDs { body in for note in notes { body(note.id, "note") } }
        try project.updateNotes(ofClip: clipID) { $0 += notes }
        return RemoveNotes(clipID: clipID, noteIDs: notes.map(\.id))
    }
}
