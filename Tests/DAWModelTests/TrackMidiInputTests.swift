import Foundation
import Testing

@testable import DAWModel

// T-093 (DW-216, REC-011 per track, MODEL-005): `Track.midiInput` and `SetTrackMidiInput`. The
// model shape is docs/autobuild/DECISIONS.md "T-093 model shape": optional in JSON, default all
// sources / omni, an undoable command for MIDI tracks only, pushed to the engine as the track's
// filter whether the track is armed or not.

@Suite("Per-track MIDI input (T-093, REC-011, MODEL-005)")
@MainActor
struct TrackMidiInputTests {
    init() { TestCommands.register() }

    /// An audio track "Mic" and two MIDI tracks "Keys" and "Pads".
    private func project() -> Project {
        var p = Project(id: GraphFixtures.fixedID, name: "midi input")
        p.tracks = [
            Track(id: p.ids.allocate(), name: "Mic", kind: .audio),
            Track(id: p.ids.allocate(), name: "Keys", kind: .midi),
            Track(id: p.ids.allocate(), name: "Pads", kind: .midi),
        ]
        return p
    }

    private func attached(_ project: Project) throws -> (ProjectStore, FakeEngine, EngineSync) {
        let store = ProjectStore(project: project)
        let engine = FakeEngine()
        let sync = try store.attachEngine(engine, debounce: .zero)
        return (store, engine, sync)
    }

    private func inputCalls(_ engine: FakeEngine) -> [FakeEngine.Call] {
        engine.calls.filter { if case .setMidiInput = $0 { true } else { false } }
    }

    // MARK: Command (MODEL-005)

    @Test("MODEL-005: SetTrackMidiInput sets source and channel; its inverse restores the old input exactly")
    func applyAndInverse() throws {
        var p = project()
        let keys = p.tracks[1].id
        let original = p
        #expect(p.tracks[1].midiInput == .default, "default: all sources, omni")

        let inverse = try SetTrackMidiInput(trackID: keys, source: .device(1_000_123), channel: 10).apply(to: &p)
        #expect(p.tracks[1].midiInput == Track.MidiInput(source: .device(1_000_123), channel: 10))
        let redo = try inverse.apply(to: &p)
        #expect(p == original, "back to the default exactly")
        _ = try redo.apply(to: &p)
        #expect(p.tracks[1].midiInput.channel == 10)

        // Channel only, all sources.
        _ = try SetTrackMidiInput(trackID: keys, source: .all, channel: 16).apply(to: &p)
        #expect(p.tracks[1].midiInput == Track.MidiInput(source: .all, channel: 16))
        try p.validate()
    }

    @Test("MODEL-005: MIDI tracks only; channel 0…16; unknown track is notFound; nothing changes on failure")
    func refusals() throws {
        var p = project()
        let mic = p.tracks[0].id, keys = p.tracks[1].id
        let before = p
        #expect(throws: DAWError.self) { _ = try SetTrackMidiInput(trackID: mic, source: .all, channel: 1).apply(to: &p) }
        #expect(throws: DAWError.self) { _ = try SetTrackMidiInput(trackID: keys, source: .all, channel: 17).apply(to: &p) }
        do {
            _ = try SetTrackMidiInput(trackID: 999, source: .all, channel: 0).apply(to: &p)
            Issue.record("expected notFound")
        } catch {
            #expect((error as Any as? DAWError)?.code == "notFound")
        }
        #expect(p == before)
    }

    @Test("MODEL-005: it is undoable (one entry, \"Set MIDI Input\"), dirties the project, and redo reapplies it")
    func undoRedo() throws {
        let store = ProjectStore(project: project())
        let keys = store.project.tracks[1].id
        try store.perform(SetTrackMidiInput(trackID: keys, source: .device(42), channel: 3))
        #expect(store.isDirty)
        #expect(store.undoLabel == "Set MIDI Input")
        #expect(store.project.tracks[1].midiInput == Track.MidiInput(source: .device(42), channel: 3))
        store.undo()
        #expect(store.project.tracks[1].midiInput == .default)
        store.redo()
        #expect(store.project.tracks[1].midiInput == Track.MidiInput(source: .device(42), channel: 3))
    }

    @Test("MODEL-006: wire form {type, trackID, source: \"all\" | \"<unique ID>\", channel}; a bad source is refused")
    func wireForm() throws {
        let decoded = try CommandRegistry.decode(Data(#"{"type":"SetTrackMidiInput","trackID":2,"source":"-77","channel":5}"#.utf8))
        let command = try #require(decoded as? SetTrackMidiInput)
        #expect(command.trackID == 2 && command.source == .device(-77) && command.channel == 5)
        let all = try #require(try CommandRegistry.decode(Data(#"{"type":"SetTrackMidiInput","trackID":2,"source":"all","channel":0}"#.utf8)) as? SetTrackMidiInput)
        #expect(all.source == .all)
        let json = String(decoding: try CommandRegistry.encode(command), as: UTF8.self)
        #expect(json.contains(#""source":"-77""#), "\(json)")
        for bad in [#""source":"usb""#, #""source":5"#, #""source":"99999999999""#] {
            #expect(throws: DAWError.self) {
                _ = try CommandRegistry.decode(Data(#"{"type":"SetTrackMidiInput","trackID":2,\#(bad),"channel":0}"#.utf8))
            }
        }
    }

    // MARK: Persistence (MODEL-040, MODEL-042: additive, no migration)

    @Test("Persistence: a set input round-trips; the default isn't written, and a file without it reads all/omni")
    func persistence() throws {
        var p = project()
        _ = try SetTrackMidiInput(trackID: p.tracks[2].id, source: .device(123_456), channel: 2).apply(to: &p)
        let data = try ProjectFile.encode(p)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.components(separatedBy: "\"midiInput\"").count == 2, "only Pads writes it")
        #expect(text.contains("\"source\" : \"123456\""), "\(text)")
        let back = try ProjectFile.decode(data).project
        #expect(back == p)
        #expect(back.tracks[1].midiInput == .default)
        #expect(back.tracks[2].midiInput == Track.MidiInput(source: .device(123_456), channel: 2))

        // A pre-T-093 file (no key at all) opens with the default, and saves byte-identical.
        let old = try ProjectFile.encode(project())
        #expect(!String(decoding: old, as: UTF8.self).contains("midiInput"))
        let reopened = try ProjectFile.decode(old).project
        #expect(reopened.tracks.allSatisfy { $0.midiInput == .default })
        #expect(try ProjectFile.encode(reopened) == old)

        // Setting the default back stores nothing.
        var q = back
        _ = try SetTrackMidiInput(trackID: q.tracks[2].id, source: .all, channel: 0).apply(to: &q)
        #expect(!String(decoding: try ProjectFile.encode(q), as: UTF8.self).contains("midiInput"))
    }

    @Test("Validation on open: a channel above 16, an audio track with a MIDI input, or a bad source is invalidProject")
    func validationOnOpen() throws {
        let text = String(decoding: try ProjectFile.encode(project()), as: UTF8.self)
        // Inject a midiInput into a track's JSON (tracks are written in order: Mic, Keys, Pads).
        func with(_ input: String, onTrackNamed name: String) -> Data {
            Data(text.replacingOccurrences(of: "\"name\" : \"\(name)\"", with: "\"midiInput\" : \(input),\n      \"name\" : \"\(name)\"").utf8)
        }
        #expect(try ProjectFile.decode(with(#"{"source": "5", "channel": 16}"#, onTrackNamed: "Keys")).project.tracks[1].midiInput.channel == 16)
        for bad in [with(#"{"source": "5", "channel": 17}"#, onTrackNamed: "Keys"),
                    with(#"{"source": "5", "channel": 1}"#, onTrackNamed: "Mic"),
                    with(#"{"source": "five", "channel": 1}"#, onTrackNamed: "Keys")] {
            do {
                var opened = try ProjectFile.decode(bad).project
                _ = try ProjectFile.validateOrRepair(&opened)  // DW-111, as open does
                Issue.record("expected invalidProject")
            } catch {
                #expect((error as Any as? DAWError)?.code == "invalidProject")
            }
        }
    }

    // MARK: Engine sync (REC-011)

    @Test("REC-011: engine sync pushes a MIDI track's input when it changes (armed or not); undo, removal and detach put the default back")
    func engineSync() throws {
        let (store, engine, sync) = try attached(project())
        let keys = store.project.tracks[1].id, pads = store.project.tracks[2].id
        #expect(inputCalls(engine).isEmpty, "defaults aren't pushed")

        engine.clearCalls()
        try store.perform(SetTrackMidiInput(trackID: keys, source: .device(7), channel: 1))
        #expect(inputCalls(engine) == [.setMidiInput(track: keys, Track.MidiInput(source: .device(7), channel: 1))])
        #expect(engine.calls.contains { if case .applyGraph = $0 { true } else { false } } == false, "not structural")

        engine.clearCalls()
        try store.perform(ArmTrack(trackID: keys, armed: true))
        #expect(inputCalls(engine).isEmpty, "arming doesn't repeat it: the engine keeps the filter")

        engine.clearCalls()
        store.undo()  // the input (arming is history-exempt)
        #expect(inputCalls(engine) == [.setMidiInput(track: keys, .default)])
        #expect(engine.midiInputFilters.isEmpty)
        store.redo()
        #expect(engine.midiInputFilters == [keys: Track.MidiInput(source: .device(7), channel: 1)])

        try store.perform(SetTrackMidiInput(trackID: pads, source: .all, channel: 9))
        engine.clearCalls()
        try store.perform(RemoveTrack(trackID: pads))
        #expect(inputCalls(engine) == [.setMidiInput(track: pads, .default)], "a removed track's filter goes")

        engine.clearCalls()
        sync.invalidate()
        #expect(inputCalls(engine) == [.setMidiInput(track: keys, .default)], "detaching leaves no filter behind (DW-156 hand-over)")
        #expect(engine.midiInputFilters.isEmpty)
    }

    @Test("REC-011: a project opened with a MIDI input set pushes it on attach, before the track is armed")
    func pushedOnAttach() throws {
        var p = project()
        let keys = p.tracks[1].id
        _ = try SetTrackMidiInput(trackID: keys, source: .device(99), channel: 0).apply(to: &p)
        p.tracks[1].armed = true
        let (_, engine, _) = try attached(p)
        let midi = engine.calls.filter {
            switch $0 {
            case .setMidiInput, .armMidiInput: true
            default: false
            }
        }
        #expect(midi == [.setMidiInput(track: keys, Track.MidiInput(source: .device(99), channel: 0)),
                         .armMidiInput(track: keys, armed: true)])
    }
}
