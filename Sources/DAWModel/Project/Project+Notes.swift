/// Lookup and placement helpers for notes (T-042).
///
/// MODEL-032: a clip's notes are sorted by `(start, id)`. As with clips (DW-110) the ID tie-break
/// makes the order a function of the notes, so notes moved away and back return to their index
/// and undo restores the project exactly.
///
/// DW-127: a note's start is relative to its clip and may be negative or past the clip's end (a
/// left trim shifts note starts, `ResizeClip`, and keeps notes outside the window so trimming back
/// restores them). Note commands accept such notes; GraphDescriptionBuilder plays only the part
/// inside the window.
extension Project {
    /// Runs `body` on a MIDI clip's notes in place, then puts them back in order. Throws
    /// `notFound` for a missing clip and `invalidArgument` for an audio clip.
    mutating func updateNotes<R>(
        ofClip id: ModelID, _ body: (inout [Note]) throws(DAWError) -> R
    ) throws(DAWError) -> R {
        try updateClip(id) { (clip: inout Clip) throws(DAWError) -> R in
            guard case .midi(var midi) = clip else { throw .invalidArgument("clip \(id) is not a MIDI clip") }
            let result = try body(&midi.notes)
            midi.sortNotes()
            clip = .midi(midi)
            return result
        }
    }

    func midiClip(_ id: ModelID) throws(DAWError) -> MidiClip {
        guard let clip = clip(id) else { throw .notFound(kind: "clip", id: id) }
        guard case .midi(let midi) = clip else { throw .invalidArgument("clip \(id) is not a MIDI clip") }
        return midi
    }
}

extension MidiClip {
    /// MODEL-032: by start, then ID.
    mutating func sortNotes() {
        notes.sort(by: Note.clipOrder)
    }

    /// The indices of `ids` in `notes`, in the order given. Throws for an empty list, a repeated
    /// ID, or an ID that isn't a note of this clip (MODEL-031).
    func noteIndices(_ ids: [ModelID]) throws(DAWError) -> [Int] {
        guard !ids.isEmpty else { throw .invalidArgument("no notes given") }
        var index: [ModelID: Int] = [:]
        for (i, note) in notes.enumerated() { index[note.id] = i }
        var seen = Set<ModelID>()
        var out: [Int] = []
        for id in ids {
            guard seen.insert(id).inserted else { throw .invalidArgument("note \(id) is listed twice") }
            guard let i = index[id] else { throw .notFound(kind: "note in clip \(self.id)", id: id) }
            out.append(i)
        }
        return out
    }
}

extension Note {
    /// MODEL-032: the order of a clip's notes.
    static func clipOrder(_ a: Note, _ b: Note) -> Bool {
        (a.start, a.id) < (b.start, b.id)
    }

    /// MODEL-031/032: start within ±`Tick.timelineEnd` of the clip start (DW-127: it may lie
    /// outside the clip), length 1…`Tick.timelineEnd`, pitch 0…127, velocity 1…127 (a note-on with
    /// velocity 0 is a note-off), channel 0…15. The bounds keep `start + length` and the
    /// builder's absolute positions far from overflow.
    func validate() throws(DAWError) {
        let end = Tick.timelineEnd.raw
        guard (-end...end).contains(start.raw), (1...end).contains(length.raw), pitch <= 127,
            (1...127).contains(velocity), channel <= 15
        else {
            throw .invariant(
                "note \(id) has start \(start.raw), length \(length.raw), pitch \(pitch), velocity \(velocity), channel \(channel)")
        }
    }
}
