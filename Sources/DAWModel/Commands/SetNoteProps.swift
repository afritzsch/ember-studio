/// MODEL-005: sets properties of notes in a MIDI clip, each note its own values (a velocity-lane
/// edit, quantize, a length change). A field left out keeps its value. The inverse sets the old
/// values of exactly the fields that were given.
public struct SetNoteProps: Command {
    public static let type = "SetNoteProps"

    /// New values for one note.
    public struct Change: Hashable, Sendable, Codable {
        public var id: ModelID
        /// Relative to the clip; may lie outside it (DW-127).
        public var start: Tick?
        public var length: Tick?
        public var pitch: UInt8?
        public var velocity: UInt8?
        public var channel: UInt8?

        public init(id: ModelID, start: Tick? = nil, length: Tick? = nil, pitch: UInt8? = nil, velocity: UInt8? = nil,
                    channel: UInt8? = nil) {
            self.id = id
            self.start = start
            self.length = length
            self.pitch = pitch
            self.velocity = velocity
            self.channel = channel
        }
    }

    public var clipID: ModelID
    public var notes: [Change]

    public init(clipID: ModelID, notes: [Change]) {
        self.clipID = clipID
        self.notes = notes
    }

    public var label: String { "Edit Notes" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        let indices = try project.midiClip(clipID).noteIndices(notes.map(\.id))
        let old = try project.updateNotes(ofClip: clipID) { (all: inout [Note]) throws(DAWError) -> [Change] in
            var old: [Change] = []
            for (change, i) in zip(notes, indices) {
                var note = all[i]
                var was = Change(id: note.id)
                if let start = change.start { was.start = note.start; note.start = start }
                if let length = change.length { was.length = note.length; note.length = length }
                if let pitch = change.pitch { was.pitch = note.pitch; note.pitch = pitch }
                if let velocity = change.velocity { was.velocity = note.velocity; note.velocity = velocity }
                if let channel = change.channel { was.channel = note.channel; note.channel = channel }
                try note.validate()
                all[i] = note
                old.append(was)
            }
            return old
        }
        return SetNoteProps(clipID: clipID, notes: old)
    }
}
