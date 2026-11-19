/// MODEL-047 (T-128): a read MIDI file as one undoable edit on a MIDI track: `AddClip` of
/// `lengthTicks` at `start`, plus `AddNotes` with the file's notes, as one `CompositeCommand`
/// (one undo entry). The notes are relative to the clip, so the file's tick 0 lands at `start`.
public enum MidiFileImport {
    public static let label = "Import MIDI File"

    /// `project` is the project the command will be performed on: `AddClip` gives the clip
    /// `project.ids.next`, and `AddNotes` names it by that ID (like `RecordingImport.midiCommand`).
    /// A file without notes gives an empty clip (`AddNotes` refuses an empty list). The track's
    /// kind and the timeline bound are checked when the command is applied, like any command.
    public static func commands(file: MidiFile, track: NodeIDValue, at start: Tick, in project: Project) -> CompositeCommand {
        var commands: [any Command] = [AddClip(trackID: track, start: start, length: file.lengthTicks)]
        if !file.notes.isEmpty {
            commands.append(AddNotes(clipID: project.ids.next, notes: file.notes.map {  // AddClip claims this ID
                AddNotes.NoteSpec(start: $0.start, length: $0.length, pitch: $0.pitch, velocity: $0.velocity, channel: $0.channel)
            }))
        }
        return CompositeCommand(label, commands)
    }
}
