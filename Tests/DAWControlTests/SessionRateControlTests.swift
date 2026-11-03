import DAWControl
import DAWModel
import Foundation
import Testing

// T-056 through the headless dispatcher (CONV §5.5): `command.apply SetSessionSampleRate` on the
// real offline engine re-converts an imported 44.1 kHz asset and the render plays the clip at the
// right pitch and position (IO-033, DW-126); on the fake devices a fallback (`device.simulate`) or
// `device.set` changes the engine's rate and the document follows (DW-130), with the
// assetsReloaded progress in `engine.events` (DW-044).

@MainActor
@Suite("Session sample rate through the control protocol (IO-033, DW-130)")
struct SessionRateControlTests {
    /// A 1 kHz sine, 2 s at 44.1 kHz.
    private func toneFile(in dir: TempDir) throws {
        let sine = TestAudio.sine(frequency: 1000, amplitude: 0.5, sampleRate: 44_100, frames: 88_200)
        try TestAudio.write([sine], sampleRate: 44_100, to: dir.file("tone.wav"))
    }

    /// An audio track with one clip of the asset at 1 s (tick 1920 at 120 bpm), starting 0.5 s
    /// into it (24 000 samples at 48 kHz).
    private func clip(_ dispatcher: Dispatcher) async throws {
        let asset = try await dispatcher.ok(.assetImport, ["path": "tone.wav"])["assetID"]
        let track = try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "A", "kind": "audio"]])
        let trackID = try #require(track["createdIDs"]?.arrayValue?.first)
        _ = try await dispatcher.ok(.commandApply, ["command": [
            "type": "AddClip", "trackID": trackID, "start": 1920, "length": 1920, "assetID": asset ?? .null,
            "sourceOffsetSamples": 24_000,
        ]])
    }

    @Test("IO-033, MODEL-005, DW-126: SetSessionSampleRate re-converts; the render plays 1 kHz from 1 s at 96 kHz; 0 RT violations")
    func offlineRender() async throws {
        let dir = try TempDir()
        try toneFile(in: dir)
        let dispatcher = TestDispatchers.real(workingDirectory: dir.url)
        _ = try await dispatcher.ok(.projectNew, ["name": "sr"])
        try await clip(dispatcher)

        let result = try await dispatcher.ok(.commandApply, ["command": ["type": "SetSessionSampleRate", "sampleRate": 96_000]])
        #expect(result["label"] == "Set Sample Rate")
        #expect(try await dispatcher.ok(.projectGet, ["path": "/sessionSampleRate"]) == 96_000)
        // DW-126: 24 000 at 48 kHz is 48 000 at 96 kHz.
        #expect(offset(dispatcher) == 48_000)
        // Not undoable: undo has nothing but the clip edits before it.
        #expect(try await dispatcher.ok(.undo)["label"] == "Add Clip")
        #expect(dispatcher.store?.project.sessionSampleRate == 96_000)
        _ = try await dispatcher.ok(.redo)

        // The export waits for the re-conversion (IO-033).
        let render = try await dispatcher.ok(.renderOffline, ["from": 0, "to": 3840, "path": "out.wav", "tail": false])
        #expect(render["sampleRate"] == 96_000 && render["rtViolations"] == 0)
        let analysis = try await dispatcher.ok(.audioAnalyze, ["path": "out.wav", "fftSize": 8192, "range": ["start": 110_000, "end": 180_000]])
        let peakHz = try #require(analysis["spectrumPeakHz"]?.doubleValue)
        #expect(abs(peakHz - 1000) < 15, "the clip plays at its pitch: \(peakHz) Hz")
        let whole = try await dispatcher.ok(.audioAnalyze, ["path": "out.wav"])
        let onset = try #require(whole["firstNonSilentSample"]?.doubleValue)
        #expect(onset >= 96_000 && onset <= 96_010, "the clip starts at its tick: sample \(onset)")

        let events = try await dispatcher.ok(.engineEvents)["events"]?.arrayValue ?? []
        let phases = events.compactMap { $0["event"]?["reload"]?["phase"]?.stringValue }
        #expect(phases == ["started", "progress", "finished"])
        #expect(try await dispatcher.ok(.engineTelemetry)["rtViolations"] == 0)
        #expect(await dispatcher.failure(.commandApply, ["command": ["type": "SetSessionSampleRate", "sampleRate": 22_050]])?
            .dawError == "invalidArgument")
    }

    @Test("DW-130, IO-021 (5): a device fallback to 44.1 kHz and device.set back to 48 kHz; the document follows, assets re-convert")
    func followsDevice() async throws {
        let dir = try TempDir()
        try toneFile(in: dir)
        let dispatcher = TestDispatchers.real(workingDirectory: dir.url)
        _ = try await dispatcher.ok(.projectNew, ["name": "dev", "engine": ["mode": "realtime"]])
        try await clip(dispatcher)

        let lost = try await dispatcher.ok(.deviceSimulate, ["kind": "deviceLost"]).decode(DeviceStateResult.self)
        #expect(lost.outputDeviceID == 2 && lost.sampleRate == 44_100)
        #expect(lost.events.contains { $0.event.reload?.phase == .started && $0.event.reload?.sampleRate == 44_100 })
        #expect(dispatcher.store?.project.sessionSampleRate == 44_100)
        #expect(offset(dispatcher) == 22_050)  // 24 000 × 147/160
        #expect(dispatcher.store?.isDirty == true)

        // Wait for the re-conversion to finish, then go back to A at 48 kHz.
        try await waitFinished(dispatcher)
        _ = try await dispatcher.ok(.deviceSimulate, ["kind": "deviceRestored", "deviceID": 1])
        let back = try await dispatcher.ok(.deviceSet, ["outputDevice": 1, "sampleRate": 48_000]).decode(DeviceStateResult.self)
        #expect(back.outputDeviceID == 1 && back.sampleRate == 48_000)
        #expect(dispatcher.store?.project.sessionSampleRate == 48_000)
        #expect(offset(dispatcher) == 24_000)
        try await waitFinished(dispatcher)

        // SetSessionSampleRate on a realtime engine moves the device too; B can't run 96 kHz but A can.
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "SetSessionSampleRate", "sampleRate": 96_000]])
        let telemetry = try await dispatcher.ok(.engineTelemetry)
        #expect(telemetry["sampleRate"] == 96_000 && telemetry["outputDeviceID"] == 1)
        try await waitFinished(dispatcher)
        #expect(try await dispatcher.ok(.engineTelemetry)["rtViolations"] == 0)
    }

    private func offset(_ dispatcher: Dispatcher) -> Int64? {
        guard case .audio(let clip)? = dispatcher.store?.project.tracks.first?.clips.first else { return nil }
        return clip.sourceOffsetSamples
    }

    /// Polls `engine.events` until an assetsReloaded `finished` arrives.
    private func waitFinished(_ dispatcher: Dispatcher, timeout: Duration = .seconds(20)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            let telemetry = try await dispatcher.ok(.engineTelemetry)
            if telemetry["assetsReloadPending"] == 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the re-conversion didn't finish")
    }
}
