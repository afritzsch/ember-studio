import DAWControl
import DAWModel
import Foundation
import Testing

// T-052: recording through the control protocol. `transport.setPunch` sets the punch range
// (REC-005), `transport.record` goes through engine sync (the recordings folder first, REC-002),
// and a finished take is imported (REC-004) before transport.stop/record answer.

@Suite("Recording control (REC-001..005, T-052)")
@MainActor
struct RecordingControlTests {
    @Test("REC-005: transport.setPunch sets and validates the punch range; disabling keeps it")
    func setPunch() async throws {
        let (dispatcher, box) = TestDispatchers.fake()
        #expect(await dispatcher.failure(.transportSetPunch, ["enabled": true, "start": 0, "end": 960])?.dawError == "noProject")
        _ = try await dispatcher.ok(.projectNew, ["name": "p"])

        let on = try await dispatcher.ok(.transportSetPunch, ["enabled": true, "start": 480, "end": 3360])
        #expect(on["punchEnabled"] == true && on["punchIn"] == 480 && on["punchOut"] == 3360)
        #expect(box.last.calls.contains(.setPunch(enabled: true, start: 480, end: 3360)))

        let off = try await dispatcher.ok(.transportSetPunch, ["enabled": false])
        #expect(off["punchEnabled"] == false && off["punchIn"] == 480 && off["punchOut"] == 3360, "the range stays")
        // Enabling again without a range reuses the kept one.
        let again = try await dispatcher.ok(.transportSetPunch, ["enabled": true])
        #expect(again["punchEnabled"] == true && again["punchIn"] == 480 && again["punchOut"] == 3360)

        for bad: JSONValue in [["enabled": true, "start": 960, "end": 960], ["enabled": true, "start": -10, "end": 10],
                               ["enabled": true, "start": 4000]]
        {
            #expect(await dispatcher.failure(.transportSetPunch, bad)?.dawError == "invalidArgument", "\(bad.jsonString())")
        }
        #expect(await dispatcher.failure(.transportSetPunch, ["enabled": false, "start": 0])?.code == -32602)
        #expect(await dispatcher.failure(.transportSetPunch, ["start": 0, "end": 10])?.code == -32602)
        let state = try await dispatcher.ok(.transportPlay)
        #expect(state["punchIn"] == 480 && state["punchOut"] == 3360, "failures change nothing")
        #expect(dispatcher.store?.isDirty == false, "punch is transport state, not the project")
    }

    @Test("REC-001, REC-002, REC-004: arm, record into the recordings folder, and the finished take is a clip by the time transport.stop answers")
    func recordFlow() async throws {
        let (dispatcher, box) = TestDispatchers.fake()
        _ = try await dispatcher.ok(.projectNew, ["name": "r"])
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "Mic", "kind": "audio"]])
        let store = try #require(dispatcher.store)
        let mic = try #require(store.project.tracks.first?.id)
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "ArmTrack", "trackID": .int(Int64(mic)), "armed": true, "inputPair": 1]])
        #expect(box.last.calls.contains(.armInput(track: mic, pair: 1, armed: true)))
        #expect(store.undoLabel == "Add Track", "arming isn't undoable")

        box.last.clearCalls()
        _ = try await dispatcher.ok(.transportRecord, ["enabled": true])
        let folder = EngineSync.temporaryRecordingsDirectory(for: store.project).path
        // Arming already pointed the engine at the folder; recording doesn't push it again.
        #expect(box.last.recordingDirectory == folder)
        #expect(box.last.calls == [.setRecording(true)])
        _ = try await dispatcher.ok(.transportPlay)

        // What the engine posts when stop finalizes the take.
        let file = folder + "/Track \(mic) Take 1.caf"
        box.last.post(EngineEvent(recording: RecordedTake(track: mic, file: file, startSample: 12_000, frames: 24_000,
                                                          sampleRate: 48_000, inputPair: 1)))
        _ = try await dispatcher.ok(.transportStop)
        let clips = try await dispatcher.ok(.projectGet, ["path": "/tracks/0/clips"])
        #expect(clips[0]?["start"] == 480 && clips[0]?["sourceOffsetSamples"] == 0)
        #expect(store.project.assets.contains { $0.path == file && $0.frames == 24_000 })
        #expect(try await dispatcher.ok(.undo)["label"] == "Record")
        #expect(store.project.tracks[0].clips.isEmpty && store.project.assets.isEmpty)
    }
}
