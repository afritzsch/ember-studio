/// MODEL-005: adds notes with new IDs to a MIDI clip. Starts are relative to the clip and may lie
/// outside it (DW-127); only the part inside the clip window plays. The notes get consecutive IDs
/// in the order given and take their place in the clip's (start, id) order (MODEL-032). The inverse
/// is `RemoveNotes`, whose inverse `RestoreNotes` puts the same IDs back, so redo keeps them.
public struct AddNotes: Command {
    public static let type = "AddNotes"

    /// A note to add: everything but the ID.
    public struct NoteSpec: Hashable, Sendable, Codable {
        public var start: Tick
        public var length: Tick
        public var pitch: UInt8
        /// Default 100.
        public var velocity: UInt8?
        /// Default 0.
        public var channel: UInt8?

        public init(start: Tick, length: Tick, pitch: UInt8, velocity: UInt8? = nil, channel: UInt8? = nil) {
            self.start = start
            self.length = length
            self.pitch = pitch
            self.velocity = velocity
            self.channel = channel
        }
    }

    public var clipID: ModelID
    public var notes: [NoteSpec]

    public init(clipID: ModelID, notes: [NoteSpec]) {
        self.clipID = clipID
        self.notes = notes
    }

    public var label: String { notes.count == 1 ? "Add Note" : "Add Notes" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        _ = try project.midiClip(clipID)
        guard !notes.isEmpty else { throw .invalidArgument("no notes given") }
        var added: [Note] = []
        for spec in notes {
            let note = Note(id: project.ids.allocate(), start: spec.start, length: spec.length, pitch: spec.pitch,
                            velocity: spec.velocity ?? 100, channel: spec.channel ?? 0)
            try note.validate()
            added.append(note)
        }
        try project.updateNotes(ofClip: clipID) { $0 += added }
        return RemoveNotes(clipID: clipID, noteIDs: added.map(\.id))
    }
}
