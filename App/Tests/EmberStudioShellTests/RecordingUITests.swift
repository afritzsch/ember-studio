import DAWControl
import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// T-055 follow-up: arm/monitor/input buttons in the track headers (ArmTrack, SetMonitoring,
// REC-001/REC-020, DW-200), the record toggle through engine sync (DW-198, REC-002), and
// recording toasts (UI-004: takes finalized, dropped audio, not saved, not added).

@MainActor
@Suite("Track header recording controls and recording toasts (REC-001, REC-020, UI-004)", .serialized)
struct RecordingUITests {
    @Test("REC-001: track.<id>.arm arms through ArmTrack (no undo entry); engine sync arms the input")
    func arm() throws {
        let (window, engine) = try makeWindow(tracks: ["Gtr"])
        let track = window.project.tracks[0].id
        let undo = window.store.undoLabel
        try window.control("track.\(track).arm").action()
        #expect(window.project.tracks[0].armed)
        #expect(try window.control("track.\(track).arm").isOn == true)
        #expect(window.trackHeaders[0].armed)
        #expect(window.store.undoLabel == undo, "history-exempt: ⌘Z doesn't disarm")
        #expect(window.store.isDirty)
        #expect(engine.calls.contains(.armInput(track: track, pair: 0, armed: true)))
        try window.control("track.\(track).arm").action()
        #expect(!window.project.tracks[0].armed)
        #expect(engine.calls.last { if case .armInput = $0 { true } else { false } } == .armInput(track: track, pair: 0, armed: false))
    }

    @Test("REC-020: track.<id>.monitor.off|auto|on set the mode through SetMonitoring (no undo entry)")
    func monitoring() throws {
        let (window, _) = try makeWindow(tracks: ["Gtr"])
        let track = window.project.tracks[0].id
        let undo = window.store.undoLabel
        #expect(try window.control("track.\(track).monitor.auto").isOn == true, "new tracks monitor auto")
        try window.control("track.\(track).monitor.on").action()
        #expect(window.project.tracks[0].monitoring == .on)
        #expect(try window.control("track.\(track).monitor.on").isOn == true)
        #expect(try window.control("track.\(track).monitor.auto").isOn == false)
        try window.control("track.\(track).monitor.off").action()
        #expect(window.project.tracks[0].monitoring == .off && window.store.undoLabel == undo)
    }

    @Test("DW-200: an audio track offers the input pairs the device has (and its own); MIDI tracks have none; offline only its own")
    func inputPairs() async throws {
        let app = AppModel(engine: .fake)
        let window = app.newProject()
        window.addTrack(.audio)
        window.addTrack(.midi)
        let audio = window.project.tracks[0].id
        let midi = window.project.tracks[1].id
        app.pump()
        // Both fake devices have 2 inputs: one pair.
        #expect(window.audioPrefs.inputPairCount == 1)
        #expect(window.trackHeaders[0].inputControls.map(\.id) == ["track.\(audio).input.0"])
        #expect(window.trackHeaders[1].inputControls.isEmpty)
        #expect(window.controls.contains { $0.id == "track.\(midi).arm" } && window.controls.contains { $0.id == "track.\(midi).monitor.on" })

        // A pair set elsewhere (control layer, an older device) still shows, so it can be changed back.
        window.perform(ArmTrack(trackID: audio, armed: true, inputPair: 3))
        #expect(window.trackHeaders[0].inputControls.map(\.id) == ["track.\(audio).input.0", "track.\(audio).input.3"])
        #expect(try window.control("track.\(audio).input.3").isOn == true)
        try window.control("track.\(audio).input.0").action()
        #expect(window.project.tracks[0].inputPair == 0 && window.project.tracks[0].armed, "keeps it armed")
        #expect(window.trackHeaders[0].inputControls.map(\.id) == ["track.\(audio).input.0"])
        #expect(TrackHeaderModel.inputTitle(0) == "In 1-2" && TrackHeaderModel.inputTitle(3) == "In 7-8")
        #expect(window.telemetry.rtViolations == 0)
        await app.quit()

        let (offline, _) = try makeWindow(tracks: ["Gtr"])
        let id = offline.project.tracks[0].id
        #expect(offline.audioPrefs.inputPairCount == 0)
        #expect(offline.trackHeaders[0].inputControls.map(\.id) == ["track.\(id).input.0"])
    }

    @Test("DW-198, REC-002: R starts recording through engine sync, which sets the recordings folder first")
    func recordThroughEngineSync() throws {
        let (window, engine) = try makeWindow(tracks: ["Gtr"])
        try window.control("transport.record").action()
        let calls = engine.calls
        let folder = try #require(calls.firstIndex { if case .setRecordingDirectory = $0 { true } else { false } })
        let start = try #require(calls.firstIndex(of: .setRecording(true)))
        #expect(folder < start, "the folder is set before recording starts")
        #expect(engine.recordingDirectory == EngineSync.temporaryRecordingsDirectory(for: window.project).path,
                "an unsaved project records into its temporary folder")
        #expect(window.isRecording)
        try window.control("transport.record").action()
        #expect(engine.calls.last == .setRecording(false))
    }

    @Test("UI-004, REC-004: a take the store imported toasts once per batch; drops, unsaved, empty and unadded takes say so")
    func recordingToasts() throws {
        let (window, engine) = try makeWindow(tracks: ["Gtr", "Bass"])
        let gtr = window.project.tracks[0].id
        let bass = window.project.tracks[1].id
        let dir = try TempDir()
        func take(_ track: NodeIDValue, _ n: Int, frames: Int64 = 96_000, dropped: UInt64 = 0) -> RecordedTake {
            RecordedTake(track: track, file: dir.file("Track \(track) Take \(n).caf").path, startSample: 48_000, frames: frames,
                         sampleRate: 48_000, droppedFrames: dropped)
        }
        func deliver(_ events: [EngineEvent]) {
            for event in events { engine.post(event) }
            // The store imports first (EngineSync → importRecording), then the window toasts.
            window.engineEventsArrived(window.store.engineSync?.pollEvents() ?? [])
        }

        // Two armed tracks stop together: both imported, one toast.
        deliver([EngineEvent(recording: take(gtr, 1)), EngineEvent(recording: take(bass, 1))])
        #expect(window.project.assets.count == 2 && window.project.tracks.allSatisfy { $0.clips.count == 1 })
        #expect(window.toasts.toasts.map(\.kind) == [.recordingFinalized])
        #expect(window.toasts.toasts.last?.title == "2 takes recorded")
        #expect(window.toasts.toasts.last?.message == "Gtr (2.0 s), Bass (2.0 s)")
        #expect(window.toasts.toasts.last?.severity == .info)

        // Dropped frames: the take is kept (and imported) with silence in the gaps.
        deliver([EngineEvent(recording: take(gtr, 2, dropped: 480), error: .engine(code: .io, detail: "480 frames dropped"))])
        let drops = try #require(window.toasts.toasts.last)
        #expect(drops.kind == .recordingDropped && drops.severity == .warning && drops.title == "Recording dropped audio")
        #expect(drops.message == "Gtr: 480 frames (10 ms) were lost; the gaps are silent.")
        #expect(window.project.tracks[0].clips.count == 2)

        // Not written: no file, an error toast that stays.
        var unsaved = take(bass, 2)
        unsaved.file = ""
        deliver([EngineEvent(recording: unsaved, error: .fileIO(path: "/x.caf", detail: "disk full"))])
        let failed = try #require(window.toasts.toasts.last)
        #expect(failed.kind == .recordingFailed && failed.severity == .error && failed.expiresAt == nil)
        #expect(failed.title == "Recording not saved" && failed.message.hasPrefix("Bass: "))

        // Empty take: nothing imported, an info.
        deliver([EngineEvent(recording: take(bass, 3, frames: 0))])
        #expect(window.toasts.toasts.last?.title == "Nothing recorded" && window.project.tracks[1].clips.count == 1)

        // Not added: its track is gone by the time the event arrives.
        try window.store.perform(RemoveTrack(trackID: bass))
        deliver([EngineEvent(recording: take(bass, 4))])
        let notAdded = try #require(window.toasts.toasts.last)
        #expect(notAdded.kind == .recordingFailed && notAdded.title == "Take not added")
        #expect(notAdded.message.contains("Track \(bass): ") && notAdded.message.contains("Take 4.caf"))
    }

    @Test("UI-004: without a take (older engines) only an error toasts, as before")
    func legacyEvents() {
        let center = ToastCenter()
        center.handle([EngineEvent(kind: .recordingFinalized)])
        #expect(center.toasts.isEmpty)
        center.handle([EngineEvent(kind: .recordingFinalized, error: .engine(code: .io, detail: "dropped"))])
        #expect(center.toasts.map(\.kind) == [.recordingDropped])
    }

    @Test("UI-050: ui.state tracks carry armed, inputPair and monitoring")
    func uiState() throws {
        let (window, _) = try makeWindow(tracks: ["Gtr"])
        let track = window.project.tracks[0].id
        window.perform(ArmTrack(trackID: track, armed: true, inputPair: 1))
        window.perform(SetMonitoring(trackID: track, mode: .on))
        let json = UIStateDumper.dump(window, isMain: true)["tracks"]?[0]
        #expect(json?["armed"] == true && json?["inputPair"] == 1 && json?["monitoring"] == "on")
    }
}
