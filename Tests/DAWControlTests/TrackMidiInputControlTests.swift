import DAWControl
import DAWModel
import Foundation
import Testing

// T-093 (DW-216): the per-track MIDI input through the control protocol. `SetTrackMidiInput` is an
// ordinary command (command.apply, undo), it reaches the engine as the track's filter, and
// `midi.inject` can pose as a source (`source`, additive) so the filter can be driven headless.

@Suite("Per-track MIDI input control (T-093)")
@MainActor
struct TrackMidiInputControlTests {
    @Test("MODEL-005, REC-011: SetTrackMidiInput via command.apply sets the filter in the engine and the project; undo restores it")
    func commandAndUndo() async throws {
        let (dispatcher, box) = TestDispatchers.fake()
        _ = try await dispatcher.ok(.projectNew, ["name": "m"])
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "Keys", "kind": "midi"]])
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "Mic", "kind": "audio"]])
        let store = try #require(dispatcher.store)
        let keys = store.project.tracks[0].id, mic = store.project.tracks[1].id

        let applied = try await dispatcher.ok(.commandApply, ["command": [
            "type": "SetTrackMidiInput", "trackID": .int(Int64(keys)), "source": "7", "channel": 10,
        ]])
        #expect(applied["label"] == "Set MIDI Input")
        #expect(store.project.tracks[0].midiInput == Track.MidiInput(source: .device(7), channel: 10))
        #expect(box.last.midiInputFilters == [keys: Track.MidiInput(source: .device(7), channel: 10)])
        let project = try await dispatcher.ok(.projectGet)
        #expect(project["tracks"]?[0]?["midiInput"]?["source"] == "7", "\(project.jsonString())")

        _ = try await dispatcher.ok(.undo)
        #expect(store.project.tracks[0].midiInput == .default)
        #expect(box.last.midiInputFilters.isEmpty)

        #expect(await dispatcher.failure(.commandApply, ["command": [
            "type": "SetTrackMidiInput", "trackID": .int(Int64(mic)), "source": "all", "channel": 1,
        ]])?.dawError == "invalidArgument", "audio tracks have no MIDI input")
        #expect(await dispatcher.failure(.commandApply, ["command": [
            "type": "SetTrackMidiInput", "trackID": .int(Int64(keys)), "source": "all", "channel": 17,
        ]])?.dawError == "invalidArgument")
    }

    @Test("T-093: midi.inject forwards an optional per-event source; without one it is the plain seam")
    func injectFromSource() async throws {
        let (dispatcher, box) = TestDispatchers.fake()
        _ = try await dispatcher.ok(.projectNew, ["name": "m"])
        let result = try await dispatcher.ok(.midiInject, ["events": [
            ["framesFromNow": 0, "status": 0x90, "data1": 60, "data2": 100, "source": 1234],
            ["framesFromNow": 0, "status": 0x90, "data1": 61, "data2": 100],
        ]])
        #expect(result["accepted"] == 2)
        let injected = box.last.calls.filter {
            switch $0 {
            case .injectMidi, .injectMidiFromSource: true
            default: false
            }
        }
        #expect(injected == [
            .injectMidiFromSource(1234, status: 0x90, data1: 60, data2: 100),
            .injectMidi(atSample: 0, relativeToNow: true, status: 0x90, data1: 61, data2: 100),
        ])
        #expect(await dispatcher.failure(.midiInject, ["events": [["framesFromNow": 0, "status": 0x90, "source": "x"]]])?.code == -32602)
    }
}
