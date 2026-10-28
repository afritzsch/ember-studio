/// MODEL-005: splits a clip at `at` (strictly inside it). The clip keeps `[start, at)` and its
/// fade-in; a new clip with a new ID gets `[at, end)`, the fade-out and, for audio, the source
/// offset that keeps its audio in place. MIDI notes starting at or after `at` move to the new clip;
/// a note crossing `at` stays in the first one and is cut there.
///
/// The inverse removes the new clip and puts the original back as a whole (`SetClip`), so undo
/// and redo keep every ID.
public struct SplitClip: Command {
    public static let type = "SplitClip"

    public var clipID: ModelID
    public var at: Tick

    public init(clipID: ModelID, at: Tick) {
        self.clipID = clipID
        self.at = at
    }

    public var label: String { "Split Clip" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let (track, _) = project.clipLocation(clipID), let original = project.clip(clipID) else {
            throw .notFound(kind: "clip", id: clipID)
        }
        let end = original.start.raw + original.length.raw
        guard original.start < at, at.raw < end else {
            throw .invalidArgument("split point \(at.raw) is not inside clip \(clipID) [\(original.start.raw), \(end))")
        }
        let leftLength = Tick(at.raw - original.start.raw)
        let rightLength = Tick(end - at.raw)
        let rightID = project.ids.next
        let left: Clip, right: Clip
        switch original {
        case .audio(let audio):
            var l = audio, r = audio
            l.length = leftLength
            l.fadeOut = 0
            r.id = rightID
            r.start = at
            r.length = rightLength
            r.fadeIn = 0
            r.sourceOffsetSamples += project.samples(from: audio.start, to: at)
            left = .audio(l)
            right = .audio(r)
        case .midi(let midi):
            let moved = midi.notes.filter { $0.start >= leftLength }.map { note in
                var note = note
                note.start.raw -= leftLength.raw
                return note
            }
            left = .midi(MidiClip(id: midi.id, start: midi.start, length: leftLength,
                                  notes: midi.notes.filter { $0.start < leftLength }))
            right = .midi(MidiClip(id: rightID, start: at, length: rightLength, notes: moved))
        }
        _ = try SetClip(clip: left).apply(to: &project)
        try project.insertClip(right, into: track)
        return CompositeCommand(label, [RemoveClip(clipID: rightID), SetClip(clip: original)])
    }
}
