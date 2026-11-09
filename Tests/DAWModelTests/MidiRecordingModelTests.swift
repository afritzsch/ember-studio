import Foundation
import Testing

@testable import DAWModel

// T-053 model side: MIDI tracks' arming reaches the engine (REC-011), and a finished MIDI take
// becomes one undoable "Record" composite of AddClip + AddNotes (REC-012).

@Suite("MIDI recording, model side (REC-011, REC-012)")
@MainActor
struct MidiRecordingModelTests {
    init() { TestCommands.register() }

    /// 48 kHz, 120 bpm (one tick = 25 samples), an audio track "Mic" and a MIDI track "Keys".
    private func project() -> Project {
        var p = Project(id: GraphFixtures.fixedID, name: "midi rec")
        p.tracks = [
            Track(id: p.ids.allocate(), name: "Mic", kind: .audio),
            Track(id: p.ids.allocate(), name: "Keys", kind: .midi),
        ]
        return p
    }

    private func attached(_ project: Project) throws -> (ProjectStore, FakeEngine, EngineSync) {
        let store = ProjectStore(project: project)
        let engine = FakeEngine()
        let sync = try store.attachEngine(engine, debounce: .zero)
        return (store, engine, sync)
    }

    private func midiArms(_ engine: FakeEngine) -> [FakeEngine.Call] {
        engine.calls.filter { if case .armMidiInput = $0 { true } else { false } }
    }

    private func take(track: NodeIDValue, start: SamplePos = -256, end: SamplePos, notes: [RecordedMidiNote], rate: Double = 48_000) -> RecordedTake {
        RecordedTake(track: track, file: "", startSample: start, frames: 0, sampleRate: rate, endSample: end, notes: notes)
    }

    private func midiClip(_ store: ProjectStore, track: Int = 1) -> MidiClip? {
        guard case .midi(let clip)? = store.project.tracks[track].clips.first else { return nil }
        return clip
    }

    // MARK: Arming (REC-011)

    @Test("REC-011: arming a MIDI track reaches the engine; disarm and removal disarm it; audio tracks stay device input")
    func arming() throws {
        let (store, engine, sync) = try attached(project())
        let mic = store.project.tracks[0].id, keys = store.project.tracks[1].id
        #expect(midiArms(engine).isEmpty)

        try store.perform(ArmTrack(trackID: keys, armed: true))
        #expect(midiArms(engine) == [.armMidiInput(track: keys, armed: true)])
        #expect(engine.calls.contains { if case .armInput = $0 { true } else { false } } == false, "no device input for MIDI")

        engine.clearCalls()
        try store.perform(ArmTrack(trackID: mic, armed: true))
        #expect(midiArms(engine).isEmpty, "audio arming is armInput only")

        engine.clearCalls()
        try store.perform(ArmTrack(trackID: keys, armed: false))
        #expect(midiArms(engine) == [.armMidiInput(track: keys, armed: false)])

        engine.clearCalls()
        try store.perform(ArmTrack(trackID: keys, armed: true))
        try store.perform(RemoveTrack(trackID: keys))
        #expect(midiArms(engine).suffix(1) == [.armMidiInput(track: keys, armed: false)], "a removed armed track is disarmed")

        // Undo brings it back armed.
        engine.clearCalls()
        store.undo()
        #expect(midiArms(engine) == [.armMidiInput(track: keys, armed: true)])

        engine.clearCalls()
        sync.invalidate()
        #expect(midiArms(engine) == [.armMidiInput(track: keys, armed: false)], "detaching disarms")
    }

    @Test("REC-011: a project opened with an armed MIDI track arms it on attach; arming is not undoable")
    func armedOnAttach() throws {
        var p = project()
        p.tracks[1].armed = true
        let (store, engine, _) = try attached(p)
        let keys = store.project.tracks[1].id
        #expect(midiArms(engine) == [.armMidiInput(track: keys, armed: true)])
        #expect(store.undoLabel == nil)
    }

    // MARK: Import (REC-012)

    @Test("REC-012: a MIDI take becomes one undoable \"Record\" (AddClip + AddNotes) on its track at the compensated start")
    func importsOneUndoableComposite() throws {
        let (store, engine, _) = try attached(project())
        let keys = store.project.tracks[1].id
        // 480 ticks in (12000 samples), one quarter (24000 samples) long.
        engine.post(EngineEvent(recording: take(track: keys, start: 12_000, end: 12_000 + 48_000, notes: [
            RecordedMidiNote(start: 12_000, end: 12_000 + 24_000, pitch: 60, velocity: 101, channel: 2),
        ])))
        _ = store.engineSync?.pollEvents()

        let clip = try #require(midiClip(store))
        #expect(clip.start == 480, "the compensated record start, in ticks")
        #expect(clip.length == 1920, "the record range: 2 beats")
        #expect(clip.notes.map(\.start) == [0] && clip.notes.map(\.length) == [960])
        #expect(clip.notes[0].pitch == 60 && clip.notes[0].velocity == 101 && clip.notes[0].channel == 2)
        #expect(store.undoLabel == "Record")
        store.undo()
        #expect(store.project.tracks[1].clips.isEmpty)
    }

    @Test("REC-012: a note lands at its tick; the clip covers every note; exact ticks round-trip; notes starting before 0 clamp to 0")
    func placement() throws {
        let store = ProjectStore(project: project())
        let keys = store.project.tracks[1].id
        // Notes between tick 40 and tick 100: 40 × 25 = 1000 samples.
        let t = take(track: keys, start: 750, end: 2500, notes: [
            RecordedMidiNote(start: 1000, end: 2000, pitch: 64),
            RecordedMidiNote(start: 3000, end: 4000, pitch: 65),  // past the stop: the clip reaches it
        ])
        let command = try #require(RecordingImport.midiCommand(for: t, in: store.project))
        try store.perform(command)
        let clip = try #require(midiClip(store))
        #expect(clip.start == 30, "the compensated record start (750 samples)")
        #expect(clip.length == 130, "reaches the last note's end, tick 160")
        #expect(clip.notes.map(\.start) == [10, 90])
        #expect(clip.notes.map(\.length) == [40, 40])

        // A note in the first L samples is "heard before 0": clamps to 0 when it is still sounding.
        store.undo()
        let early = take(track: keys, start: -300, end: 2400, notes: [
            RecordedMidiNote(start: -100, end: 2000, pitch: 60),
            RecordedMidiNote(start: -300, end: -50, pitch: 62),  // over before tick 0: dropped
        ])
        try store.perform(try #require(RecordingImport.midiCommand(for: early, in: store.project)))
        let clamped = try #require(midiClip(store))
        #expect(clamped.start == 0 && clamped.notes.count == 1 && clamped.notes[0].start == 0)
        #expect(clamped.notes[0].length == 80)
    }

    @Test("REC-012: no notes means no clip and no undo entry; a take for a missing or audio track isn't imported")
    func nothingPlayedIsNothing() throws {
        let (store, engine, _) = try attached(project())
        let keys = store.project.tracks[1].id, mic = store.project.tracks[0].id
        #expect(RecordingImport.midiCommand(for: take(track: keys, end: 100, notes: []), in: store.project) == nil)

        // Audio track or missing track: not imported, undo stays empty (the engine event path logs it).
        engine.post(EngineEvent(recording: take(track: mic, end: 100, notes: [RecordedMidiNote(start: 0, end: 50, pitch: 60)])))
        engine.post(EngineEvent(recording: take(track: 999, end: 100, notes: [RecordedMidiNote(start: 0, end: 50, pitch: 60)])))
        _ = store.engineSync?.pollEvents()
        #expect(store.project.tracks[0].clips.isEmpty && store.project.tracks[1].clips.isEmpty)
        #expect(store.undoLabel == nil)
        #expect(throws: DAWError.self) {
            try store.importMidiRecording(take(track: mic, end: 100, notes: [RecordedMidiNote(start: 0, end: 50, pitch: 60)]))
        }
    }

    @Test("REC-012: a take recorded at another session rate scales to the current one")
    func scalesRate() throws {
        let store = ProjectStore(project: project())
        let keys = store.project.tracks[1].id
        let t = take(track: keys, start: 0, end: 96_000, notes: [RecordedMidiNote(start: 48_000, end: 72_000, pitch: 60)],
                     rate: 96_000)
        try store.perform(try #require(RecordingImport.midiCommand(for: t, in: store.project)))
        let clip = try #require(midiClip(store))
        #expect(clip.start == 0 && clip.length == 1920)
        #expect(clip.notes[0].start == 960 && clip.notes[0].length == 480)
    }

    @Test("REC-012: an audio take still imports as audio (notes nil)")
    func audioTakeIsNotMidi() {
        let audio = RecordedTake(track: 1, file: "/tmp/x.caf", startSample: 0, frames: 10, sampleRate: 48_000)
        #expect(!audio.isMidi)
        let midi = take(track: 1, end: 10, notes: [])
        #expect(midi.isMidi)
    }
}
