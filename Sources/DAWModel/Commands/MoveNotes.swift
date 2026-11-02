/// MODEL-005: moves notes of a MIDI clip by the same amount in time (`ticks`) and pitch
/// (`semitones`), as a piano-roll drag does. A note may end up outside the clip window (DW-127),
/// but every note must stay in range (MODEL-031): nothing is clamped, so the inverse, the opposite
/// move, restores the project exactly.
public struct MoveNotes: Command {
    public static let type = "MoveNotes"

    public var clipID: ModelID
    public var noteIDs: [ModelID]
    public var ticks: Tick
    public var semitones: Int

    public init(clipID: ModelID, noteIDs: [ModelID], ticks: Tick = 0, semitones: Int = 0) {
        self.clipID = clipID
        self.noteIDs = noteIDs
        self.ticks = ticks
        self.semitones = semitones
    }

    public var label: String { noteIDs.count == 1 ? "Move Note" : "Move Notes" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        let indices = try project.midiClip(clipID).noteIndices(noteIDs)
        let end = Tick.timelineEnd.raw
        // Bounds first, so the arithmetic below can't overflow.
        guard (-2 * end...2 * end).contains(ticks.raw), (-127...127).contains(semitones) else {
            throw .invalidArgument("a move by \(ticks.raw) ticks, \(semitones) semitones is out of range")
        }
        try project.updateNotes(ofClip: clipID) { (notes: inout [Note]) throws(DAWError) in
            for i in indices {
                let pitch = Int(notes[i].pitch) + semitones
                guard (0...127).contains(pitch) else {
                    throw .invalidArgument("note \(notes[i].id) would move to pitch \(pitch)")
                }
                notes[i].pitch = UInt8(pitch)
                notes[i].start.raw += ticks.raw
                guard (-end...end).contains(notes[i].start.raw) else {
                    throw .invalidArgument("note \(notes[i].id) would start \(notes[i].start.raw) ticks from its clip")
                }
            }
        }
        return MoveNotes(clipID: clipID, noteIDs: noteIDs, ticks: Tick(-ticks.raw), semitones: -semitones)
    }
}
