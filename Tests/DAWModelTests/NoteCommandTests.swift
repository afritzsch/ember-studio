import DAWModel
import Foundation
import Testing

// MODEL-005 (note subset), MODEL-031, MODEL-032 and DW-127: AddNotes, RemoveNotes, RestoreNotes,
// MoveNotes, SetNoteProps (T-042). The project is ClipProject (ClipCommandTests):
//
//   Keys: [clip @3840 +3840: notes @0 +480 (60), @960 +480 (64)]

@Suite("Note commands")
struct NoteCommandTests {
    init() { TestCommands.register() }

    let p = ClipProject.make()
    var clip: ModelID { p.keys.clips[0].id }
    var notes: [Note] { p.keys.clips[0].midiNotes }

    // MARK: MODEL-005

    @Test("MODEL-005: AddNotes adds notes with consecutive new IDs, in (start, id) order, with default velocity and channel")
    func addNotes() throws {
        let added = try expectApplyRoundTrip(
            AddNotes(clipID: clip, notes: [.init(start: 960, length: 240, pitch: 67, velocity: 90, channel: 3),
                                           .init(start: 480, length: 120, pitch: 62)]), on: p)
        let next = p.ids.next
        #expect(added.midiClip(clip)?.notes == [
            notes[0],
            Note(id: next + 1, start: 480, length: 120, pitch: 62, velocity: 100, channel: 0),
            notes[1],
            Note(id: next, start: 960, length: 240, pitch: 67, velocity: 90, channel: 3),
        ], "same start as note 64: the higher ID goes after it")
        #expect(added.ids.next == next + 2)
    }

    @Test("MODEL-005: RemoveNotes removes notes; the inverse restores them with their IDs (RestoreNotes)")
    func removeNotes() throws {
        let removed = try expectApplyRoundTrip(RemoveNotes(clipID: clip, noteIDs: [notes[1].id]), on: p)
        #expect(removed.midiClip(clip)?.notes == [notes[0]])
        let all = try expectApplyRoundTrip(RemoveNotes(clipID: clip, noteIDs: [notes[1].id, notes[0].id]), on: p)
        #expect(all.midiClip(clip)?.notes == [])

        var empty = p
        _ = try RemoveNotes(clipID: clip, noteIDs: notes.map(\.id)).applyChecked(to: &empty)
        let restored = try expectApplyRoundTrip(RestoreNotes(clipID: clip, notes: notes.reversed()), on: empty)
        #expect(restored == p, "restored notes take their places by (start, id)")
    }

    @Test("MODEL-005: MoveNotes moves notes in time and pitch together; the inverse is the opposite move")
    func moveNotes() throws {
        let moved = try expectApplyRoundTrip(MoveNotes(clipID: clip, noteIDs: [notes[0].id], ticks: 1200, semitones: -12), on: p)
        #expect(moved.midiClip(clip)?.notes == [notes[1], Note(id: notes[0].id, start: 1200, length: 480, pitch: 48)],
                "order follows the new start")
        let both = try expectApplyRoundTrip(MoveNotes(clipID: clip, noteIDs: notes.map(\.id), ticks: -960, semitones: 63), on: p)
        #expect(both.midiClip(clip)?.notes.map(\.start) == [-960, 0], "DW-127: a note may move before the clip start")
        #expect(both.midiClip(clip)?.notes.map(\.pitch) == [123, 127])
        let past = try expectApplyRoundTrip(MoveNotes(clipID: clip, noteIDs: [notes[1].id], ticks: 10_000), on: p)
        #expect(past.midiClip(clip)?.notes.last?.start == 10_960, "DW-127: or past its end")
    }

    @Test("MODEL-005: SetNoteProps sets each note's own values; the inverse sets back only the fields given")
    func setNoteProps() throws {
        let velocities = try expectApplyRoundTrip(
            SetNoteProps(clipID: clip, notes: [.init(id: notes[0].id, velocity: 20), .init(id: notes[1].id, velocity: 127)]), on: p)
        #expect(velocities.midiClip(clip)?.notes.map(\.velocity) == [20, 127])

        let all = try expectApplyRoundTrip(
            SetNoteProps(clipID: clip, notes: [.init(id: notes[1].id, start: -100, length: 5, pitch: 0, velocity: 1, channel: 15)]), on: p)
        #expect(all.midiClip(clip)?.notes == [Note(id: notes[1].id, start: -100, length: 5, pitch: 0, velocity: 1, channel: 15), notes[0]])

        var q = p
        let inverse = try SetNoteProps(clipID: clip, notes: [.init(id: notes[0].id, length: 960)]).applyChecked(to: &q)
        let back = try #require(inverse as? SetNoteProps)
        #expect(back.notes == [.init(id: notes[0].id, length: 480)])
    }

    @Test("MODEL-005: redoing AddNotes recreates the same note IDs, so later history entries still apply")
    func redoKeepsNoteIDs() throws {
        var project = p
        var stack = UndoStack()
        try stack.perform(AddNotes(clipID: clip, notes: [.init(start: 0, length: 100, pitch: 72)]), on: &project)
        let id = p.ids.next
        try stack.perform(MoveNotes(clipID: clip, noteIDs: [id], ticks: 50, semitones: 1), on: &project)
        try stack.perform(SetNoteProps(clipID: clip, notes: [.init(id: id, velocity: 10)]), on: &project)
        try stack.perform(RemoveNotes(clipID: clip, noteIDs: [notes[0].id, id]), on: &project)
        let final = project
        while try stack.undo(&project) != nil {}
        #expect(project == p)
        while try stack.redo(&project) != nil {}
        #expect(project == final)
    }

    @Test("MODEL-003: a 100-step note drag is one undo entry and undoes exactly")
    func dragIsOneEntry() throws {
        var project = p
        var stack = UndoStack()
        stack.beginGesture("Move Notes")
        for _ in 0..<100 {
            try stack.perform(MoveNotes(clipID: clip, noteIDs: notes.map(\.id), ticks: 7, semitones: 0), on: &project)
        }
        stack.endGesture()
        #expect(stack.undoEntries.count == 1)
        #expect(project.midiClip(clip)?.notes.map(\.start) == [700, 1660])
        try stack.undo(&project)
        #expect(project == p)
    }

    @Test("DW-127: after a left trim, notes before the clip start can be edited, moved, removed and added")
    func notesOutsideTheWindow() throws {
        var trimmed = p
        _ = try ResizeClip(clipID: clip, start: 4800, length: 2880).applyChecked(to: &trimmed)
        let outside = try #require(trimmed.midiClip(clip)?.notes.first)
        #expect(outside.start == -960)

        _ = try expectApplyRoundTrip(SetNoteProps(clipID: clip, notes: [.init(id: outside.id, velocity: 1)]), on: trimmed)
        _ = try expectApplyRoundTrip(MoveNotes(clipID: clip, noteIDs: [outside.id], ticks: -10, semitones: 2), on: trimmed)
        _ = try expectApplyRoundTrip(RemoveNotes(clipID: clip, noteIDs: [outside.id]), on: trimmed)
        let added = try expectApplyRoundTrip(AddNotes(clipID: clip, notes: [.init(start: -2000, length: 100, pitch: 1)]), on: trimmed)
        #expect(added.midiClip(clip)?.notes.first?.start == -2000)

        // Trimming back brings the edited note back into the window, and the builder plays it.
        var store = trimmed
        store.tracks[1].instrument = DeviceSlot(id: store.ids.allocate(), kind: .builtin(.sampler))
        _ = try SetNoteProps(clipID: clip, notes: [.init(id: outside.id, velocity: 1)]).applyChecked(to: &store)
        _ = try ResizeClip(clipID: clip, start: 3840, length: 3840).applyChecked(to: &store)
        let graph = GraphDescriptionBuilder.build(store, runtime: RuntimeIDs())
        #expect(graph.notes.first { $0.pitch == 60 }?.velocity == 1 && graph.notes.first { $0.pitch == 60 }?.start == 3840)
    }

    @Test("MODEL-006: note commands' wire shapes")
    func wireShapes() throws {
        let json = #"{"type":"AddNotes","clipID":5,"notes":[{"start":-10,"length":480,"pitch":60}]}"#
        let add = try #require(try CommandRegistry.decode(Data(json.utf8)) as? AddNotes)
        #expect(add.notes == [.init(start: -10, length: 480, pitch: 60)])
        func wire(_ command: any Command) throws -> String { String(decoding: try CommandRegistry.encode(command), as: UTF8.self) }
        #expect(try wire(MoveNotes(clipID: 5, noteIDs: [6, 7], ticks: -480, semitones: 2))
            == #"{"clipID":5,"noteIDs":[6,7],"semitones":2,"ticks":-480,"type":"MoveNotes"}"#)
        #expect(try wire(SetNoteProps(clipID: 5, notes: [.init(id: 6, velocity: 30)]))
            == #"{"clipID":5,"notes":[{"id":6,"velocity":30}],"type":"SetNoteProps"}"#)
        #expect(try wire(RemoveNotes(clipID: 5, noteIDs: [6])) == #"{"clipID":5,"noteIDs":[6],"type":"RemoveNotes"}"#)
        #expect(try wire(RestoreNotes(clipID: 5, notes: [Note(id: 6, start: 0, length: 1, pitch: 2)]))
            == #"{"clipID":5,"notes":[{"channel":0,"id":6,"length":1,"pitch":2,"start":0,"velocity":100}],"type":"RestoreNotes"}"#)
    }

    // MARK: MODEL-031

    @Test("MODEL-031: unknown IDs and bad arguments throw and change nothing")
    func invalidCommands() {
        let missing: ModelID = 999
        let audio = p.gtr.clips[0].id
        let (a, b) = (notes[0].id, notes[1].id)
        let end = Tick.timelineEnd.raw
        let next = p.ids.next
        let cases: [(any Command, DAWError)] = [
            (AddNotes(clipID: missing, notes: [.init(start: 0, length: 1, pitch: 60)]), .notFound(kind: "clip", id: missing)),
            (AddNotes(clipID: audio, notes: [.init(start: 0, length: 1, pitch: 60)]), .invalidArgument("clip \(audio) is not a MIDI clip")),
            (AddNotes(clipID: clip, notes: []), .invalidArgument("no notes given")),
            (AddNotes(clipID: clip, notes: [.init(start: 0, length: 0, pitch: 60)]),
             .brokenInvariant("note \(next) has start 0, length 0, pitch 60, velocity 100, channel 0")),
            (AddNotes(clipID: clip, notes: [.init(start: 0, length: 1, pitch: 128)]),
             .brokenInvariant("note \(next) has start 0, length 1, pitch 128, velocity 100, channel 0")),
            (AddNotes(clipID: clip, notes: [.init(start: 0, length: 1, pitch: 60, velocity: 0)]),
             .brokenInvariant("note \(next) has start 0, length 1, pitch 60, velocity 0, channel 0")),
            (AddNotes(clipID: clip, notes: [.init(start: 0, length: 1, pitch: 60, velocity: 128)]),
             .brokenInvariant("note \(next) has start 0, length 1, pitch 60, velocity 128, channel 0")),
            (AddNotes(clipID: clip, notes: [.init(start: 0, length: 1, pitch: 60), .init(start: 0, length: 1, pitch: 60, channel: 16)]),
             .brokenInvariant("note \(next + 1) has start 0, length 1, pitch 60, velocity 100, channel 16")),
            (AddNotes(clipID: clip, notes: [.init(start: Tick(-end - 1), length: 1, pitch: 60)]),
             .brokenInvariant("note \(next) has start \(-end - 1), length 1, pitch 60, velocity 100, channel 0")),
            (AddNotes(clipID: clip, notes: [.init(start: 0, length: Tick(end + 1), pitch: 60)]),
             .brokenInvariant("note \(next) has start 0, length \(end + 1), pitch 60, velocity 100, channel 0")),

            (RemoveNotes(clipID: missing, noteIDs: [a]), .notFound(kind: "clip", id: missing)),
            (RemoveNotes(clipID: audio, noteIDs: [a]), .invalidArgument("clip \(audio) is not a MIDI clip")),
            (RemoveNotes(clipID: clip, noteIDs: []), .invalidArgument("no notes given")),
            (RemoveNotes(clipID: clip, noteIDs: [a, a]), .invalidArgument("note \(a) is listed twice")),
            (RemoveNotes(clipID: clip, noteIDs: [a, missing]), .notFound(kind: "note in clip \(clip)", id: missing)),
            (RemoveNotes(clipID: clip, noteIDs: [audio]), .notFound(kind: "note in clip \(clip)", id: audio)),

            (RestoreNotes(clipID: clip, notes: [notes[0]]), .invalidArgument("note id \(a) is already in use")),
            (RestoreNotes(clipID: clip, notes: [Note(id: audio, start: 0, length: 1, pitch: 1)]),
             .invalidArgument("note id \(audio) is already in use")),
            (RestoreNotes(clipID: clip, notes: [Note(id: 0, start: 0, length: 1, pitch: 1)]),
             .invalidArgument("note id 0 is outside 1…\(GraphNodeID.maxModelID)")),
            (RestoreNotes(clipID: clip, notes: [Note(id: 900, start: 0, length: 1, pitch: 1), Note(id: 900, start: 1, length: 1, pitch: 1)]),
             .invalidArgument("note id 900 is already in use")),
            (RestoreNotes(clipID: clip, notes: [Note(id: 900, start: 0, length: -1, pitch: 1)]),
             .brokenInvariant("note 900 has start 0, length -1, pitch 1, velocity 100, channel 0")),
            (RestoreNotes(clipID: clip, notes: []), .invalidArgument("no notes given")),
            (RestoreNotes(clipID: audio, notes: [Note(id: 900, start: 0, length: 1, pitch: 1)]),
             .invalidArgument("clip \(audio) is not a MIDI clip")),

            (MoveNotes(clipID: clip, noteIDs: [a], semitones: 68), .invalidArgument("note \(a) would move to pitch 128")),
            (MoveNotes(clipID: clip, noteIDs: [b, a], semitones: -61), .invalidArgument("note \(a) would move to pitch -1")),
            (MoveNotes(clipID: clip, noteIDs: [a], ticks: Tick(end + 1)),
             .invalidArgument("note \(a) would start \(end + 1) ticks from its clip")),
            (MoveNotes(clipID: clip, noteIDs: [a], ticks: Tick(Int64.min)),
             .invalidArgument("a move by \(Int64.min) ticks, 0 semitones is out of range")),
            (MoveNotes(clipID: clip, noteIDs: [a], semitones: Int.max),
             .invalidArgument("a move by 0 ticks, \(Int.max) semitones is out of range")),
            (MoveNotes(clipID: clip, noteIDs: [], ticks: 1), .invalidArgument("no notes given")),
            (MoveNotes(clipID: clip, noteIDs: [b, b], ticks: 1), .invalidArgument("note \(b) is listed twice")),
            (MoveNotes(clipID: missing, noteIDs: [a], ticks: 1), .notFound(kind: "clip", id: missing)),

            (SetNoteProps(clipID: clip, notes: [.init(id: a, length: 0)]),
             .brokenInvariant("note \(a) has start 0, length 0, pitch 60, velocity 100, channel 0")),
            (SetNoteProps(clipID: clip, notes: [.init(id: b, velocity: 0)]),
             .brokenInvariant("note \(b) has start 960, length 480, pitch 64, velocity 0, channel 0")),
            (SetNoteProps(clipID: clip, notes: [.init(id: a, pitch: 200)]),
             .brokenInvariant("note \(a) has start 0, length 480, pitch 200, velocity 100, channel 0")),
            (SetNoteProps(clipID: clip, notes: [.init(id: a, start: Tick(end + 1))]),
             .brokenInvariant("note \(a) has start \(end + 1), length 480, pitch 60, velocity 100, channel 0")),
            (SetNoteProps(clipID: clip, notes: [.init(id: a, velocity: 1), .init(id: a, velocity: 2)]),
             .invalidArgument("note \(a) is listed twice")),
            (SetNoteProps(clipID: clip, notes: []), .invalidArgument("no notes given")),
            (SetNoteProps(clipID: clip, notes: [.init(id: missing, velocity: 1)]), .notFound(kind: "note in clip \(clip)", id: missing)),
            (SetNoteProps(clipID: audio, notes: [.init(id: a, velocity: 1)]), .invalidArgument("clip \(audio) is not a MIDI clip")),
        ]
        for (command, error) in cases {
            var q = p
            #expect(throws: error, "\(type(of: command).type)") { _ = try command.applyChecked(to: &q) }
            #expect(q == p)
        }
    }

    @Test("MODEL-031: fuzz — random note, instrument, zone and clip commands, valid or not, never break an invariant; undo-all restores the start")
    func fuzz() throws {
        var rng = SplitMix64(seed: 0x7_0042)
        var performed = 0
        var rejected = 0
        for _ in 0..<150 {
            var project = p
            var stack = UndoStack()
            for _ in 0..<40 {
                let command = Int.random(in: 0..<4, using: &rng) == 0
                    ? randomClipCommand(for: project, using: &rng) : randomNoteCommand(for: project, using: &rng)
                let before = project
                do {
                    try stack.perform(command, on: &project)
                    performed += 1
                } catch {
                    rejected += 1
                    #expect(project == before)
                }
                try project.validate()
            }
            let final = project
            while try stack.undo(&project) != nil { try project.validate() }
            #expect(project == p)
            while try stack.redo(&project) != nil { try project.validate() }
            #expect(project == final)
        }
        #expect(performed > 1500 && rejected > 1500, "performed \(performed), rejected \(rejected)")
    }

    // MARK: MODEL-032

    @Test("MODEL-032: notes are sorted by (start, id) and in range; open repairs the order only")
    func validation() throws {
        func edited(_ edit: (inout [Note]) -> Void) -> Project {
            var q = p
            guard case .midi(var midi) = q.tracks[1].clips[0] else { return q }
            edit(&midi.notes)
            q.tracks[1].clips[0] = .midi(midi)
            return q
        }
        let (a, b) = (notes[0].id, notes[1].id)
        let tie = edited { $0[1].start = 0; $0.reverse() }
        #expect(throws: DAWError.brokenInvariant("notes of clip \(clip) are not sorted by start (then id)")) { try tie.validate() }
        #expect(throws: DAWError.brokenInvariant("note \(b) has start 960, length 480, pitch 64, velocity 0, channel 0")) {
            try edited { $0[1].velocity = 0 }.validate()
        }
        #expect(throws: DAWError.brokenInvariant("note \(a) has start \(-Tick.timelineEnd.raw - 1), length 480, pitch 60, velocity 100, channel 0")) {
            try edited { $0[0].start = Tick(-Tick.timelineEnd.raw - 1) }.validate()
        }
        #expect(throws: Never.self, "DW-127: notes outside the clip are valid") {
            try edited { $0[0].start = -5000; $0[1].start = 50_000 }.validate()
        }

        // DW-111: an unsorted tie is repaired on open (the order is a function of the notes).
        var repaired = tie
        let repairs = try ProjectFile.validateOrRepair(&repaired)
        #expect(repairs == ["sorted the notes of clip \(clip) by start (then id)"])
        #expect(repaired.midiClip(clip)?.notes.map(\.id) == [a, b])
    }

    // MARK: Engine sync (DW-051, DW-072)

    @Test("DW-072: note edits reach the engine as a new graph with the MIDI player's configVersion bumped")
    @MainActor
    func engineSync() async throws {
        var project = p
        project.tracks[1].instrument = DeviceSlot(id: project.ids.allocate(), kind: .builtin(.sampler))
        let store = ProjectStore(project: project)
        let engine = FakeEngine()
        let sync = try store.attachEngine(engine)
        let player = GraphNodeID.source(of: p.keys.id)
        func version() throws -> UInt32 { try #require(engine.appliedGraphs.last?.nodes.first { $0.id == player }).configVersion }
        let v0 = try version()

        try store.perform(AddNotes(clipID: clip, notes: [.init(start: 100, length: 100, pitch: 70)]))
        await sync.settle()
        #expect(try version() > v0)
        #expect(engine.appliedGraphs.last?.notes.count == 3)

        let v1 = try version()
        try store.perform(SetNoteProps(clipID: clip, notes: [.init(id: notes[0].id, velocity: 5)]))
        await sync.settle()
        #expect(try version() > v1)
        #expect(engine.appliedGraphs.last?.notes.first?.velocity == 5)

        let applied = engine.appliedGraphs.count
        try store.perform(MoveNotes(clipID: clip, noteIDs: [notes[0].id], ticks: -500))
        await sync.settle()
        #expect(engine.appliedGraphs.count == applied + 1)
        #expect(engine.appliedGraphs.last?.notes.contains { $0.pitch == 60 } == false,
                "DW-127: a note moved out of the window (start −500, length 480) isn't played")
    }
}

/// Half of these name real clips and notes; the rest pick from all IDs or a missing one.
func randomNoteCommand(for project: Project, using rng: inout SplitMix64) -> any Command {
    var clips: [ModelID] = []
    var notes: [ModelID: [ModelID]] = [:]
    for track in project.tracks where track.kind == .midi {
        for clip in track.clips {
            clips.append(clip.id)
            notes[clip.id] = clip.midiNotes.map(\.id)
        }
    }
    let audioClips = project.tracks.filter { $0.kind == .audio }.flatMap(\.clips).map(\.id)
    let anything = clips + audioClips + notes.values.flatMap { $0 } + [project.tracks[0].id, 999]
    func pick(_ ids: [ModelID]) -> ModelID {
        (Int.random(in: 0..<8, using: &rng) != 0 ? ids.randomElement(using: &rng) : nil) ?? anything.randomElement(using: &rng)!
    }
    let clip = pick(clips)
    func someNotes() -> [ModelID] {
        let own = notes[clip] ?? []
        var out = own.filter { _ in Bool.random(using: &rng) }
        if out.isEmpty || Int.random(in: 0..<16, using: &rng) == 0 { out.append(pick(own)) }
        return out
    }
    func tick() -> Tick { Tick([-5000, -480, -1, 0, 1, 240, 960, 3840, 9000].randomElement(using: &rng)!) }
    // About one value in ten is out of range.
    func length() -> Tick { Tick([0, 1, 120, 480, 480, 960, 4000, 4000, 1 << 41].randomElement(using: &rng)!) }
    func pitch() -> UInt8 { [0, 36, 48, 60, 64, 72, 100, 127, 128].randomElement(using: &rng)! }
    func velocity() -> UInt8 { [0, 1, 20, 64, 80, 100, 110, 127, 200].randomElement(using: &rng)! }
    func channel() -> UInt8 { [0, 0, 1, 2, 9, 9, 10, 15, 16].randomElement(using: &rng)! }
    func maybe<T>(_ value: () -> T) -> T? { Bool.random(using: &rng) ? value() : nil }

    let tracks = project.tracks.map(\.id)
    var slots: [NodeIDValue] = []
    project.forEachDeviceSlot { slot, _ in slots.append(slot.id) }
    func zones() -> [SamplerZone] {
        (0..<Int.random(in: 0...2, using: &rng)).map { _ in
            SamplerZone(assetID: pick(project.assets.map(\.id)), rootKey: pitch(), lowKey: [0, 60].randomElement(using: &rng)!,
                        highKey: [59, 127].randomElement(using: &rng)!, tune: [0, -1.5, 200].randomElement(using: &rng)!)
        }
    }

    switch Int.random(in: 0..<8, using: &rng) {
    case 0:
        let count = Int.random(in: 0...3, using: &rng)
        return AddNotes(clipID: clip, notes: (0..<count).map { _ in
            .init(start: tick(), length: length(), pitch: pitch(), velocity: maybe(velocity), channel: maybe(channel))
        })
    case 1: return RemoveNotes(clipID: clip, noteIDs: someNotes())
    case 2:
        return MoveNotes(clipID: clip, noteIDs: someNotes(), ticks: tick(), semitones: [-128, -12, -1, 0, 0, 1, 5, 12, 70].randomElement(using: &rng)!)
    case 3:
        return SetNoteProps(clipID: clip, notes: someNotes().map { id in
            .init(id: id, start: maybe(tick), length: maybe(length), pitch: maybe(pitch), velocity: maybe(velocity),
                  channel: maybe(channel))
        })
    case 5:
        let device: DeviceSlot.Kind = [.builtin(.sampler), .builtin(.sampler), .builtin(.eq),
                                       .au(AUDescriptor(identifier: "aumu:x:y", name: "AU"))].randomElement(using: &rng)!
        return SetInstrument(trackID: pick(tracks), device: device, zones: Bool.random(using: &rng) ? zones() : nil)
    case 6:
        return Bool.random(using: &rng) ? RemoveInstrument(trackID: pick(tracks)) : SetSamplerZones(slotID: pick(slots), zones: zones())
    default:
        let restored = Note(id: Bool.random(using: &rng) ? project.ids.next + 50 : pick(anything), start: tick(), length: length(),
                            pitch: pitch(), velocity: velocity(), channel: channel())
        return RestoreNotes(clipID: clip, notes: [restored])
    }
}
