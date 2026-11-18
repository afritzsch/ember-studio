import DAWControl
import DAWModel
import Foundation
import Testing

// T-096 (Contract delta (T-096), 08/13): render-job cancel (DW-220), render.offline dither (DW-219),
// engine.meters (DW-174) and engine.previewNote (DW-189), on the real engine where it matters.

@MainActor
@Suite("Control follow-ups (T-096)", .serialized)
struct ControlFollowupTests {
    /// A MIDI track (ID 2) whose sampler (slot 4) plays a 440 Hz sine at 0.5 rooted at A4 and
    /// looping, and a compressor insert (slot 5); `note: true` adds a clip (ID 6) holding A4 over
    /// ticks [0, 3840) at velocity 127.
    private func samplerProject(_ dispatcher: Dispatcher, _ dir: TempDir, engine: JSONValue? = nil, note: Bool) async throws {
        let sine = dir.file("a440.wav")
        try TestAudio.write([TestAudio.sine(frequency: 440, amplitude: 0.5, sampleRate: 48_000, frames: 48_000)],
                            sampleRate: 48_000, to: sine)
        var newParams: [String: JSONValue] = ["name": "t096", "sampleRate": 48_000]
        if let engine { newParams["engine"] = engine }
        _ = try await dispatcher.ok(.projectNew, .object(newParams))
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "Keys", "kind": "midi"]])
        _ = try await dispatcher.ok(.assetImport, ["path": .string(sine.path)])  // asset 3
        _ = try await dispatcher.ok(.commandApply, ["command": [
            "type": "SetInstrument", "trackID": 2, "device": ["format": "builtin", "node": "sampler"],
            "zones": [["assetID": 3, "rootKey": 69, "loopStart": 0, "loopEnd": 48_000]],
        ]])
        _ = try await dispatcher.ok(.commandApply, ["command": [
            "type": "InsertDevice", "channel": 2, "device": ["format": "builtin", "node": "compressor"],
        ]])
        guard note else { return }
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddClip", "trackID": 2, "start": 0, "length": 3840]])
        _ = try await dispatcher.ok(.commandApply, ["command": [
            "type": "AddNotes", "clipID": 6, "notes": [["start": 0, "length": 3840, "pitch": 69, "velocity": 127]],
        ]])
    }

    private func meters(_ dispatcher: Dispatcher, _ params: JSONValue? = nil) async throws -> [Int64: JSONValue] {
        let result = try await dispatcher.ok(.engineMeters, params)
        var byNode: [Int64: JSONValue] = [:]
        for meter in result["meters"]?.arrayValue ?? [] { byNode[meter["node"]?.int64Value ?? -1] = meter }
        return byNode
    }

    // MARK: DW-220 render.cancel

    @Test("DW-220, CTL-031: render.cancel stops a running render.offline mid-way: it fails with cancelled (-32005), its progress rose but never reached 1, the partial file is gone, 0 RT violations, and the engine renders again")
    func cancelMidRender() async throws {
        let dir = try TempDir()
        let dispatcher = TestDispatchers.real(workingDirectory: dir.url)
        _ = try await dispatcher.ok(.projectNew, ["name": "long", "sampleRate": 48_000])
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "A", "kind": "audio"]])
        #expect(try await dispatcher.ok(.renderCancel)["cancelled"] == .bool(false), "nothing running: nothing to cancel")

        // Ten minutes at 120 bpm; the cancel goes out at the first progress above 0.
        let path = dir.file("long.wav")
        var progress: [Double] = []
        var cancel: Task<JSONValue, any Error>?
        let request = RPCRequest(id: .int(7), method: ControlMethod.renderOffline.rawValue, params: [
            "from": 0, "to": .int(Int64(600 * 2 * 960)), "path": .string(path.path), "tail": false, "sampleFormat": "int16",
        ])
        let response = await dispatcher.handle(request) { update in
            progress.append(update.progress)
            if update.progress > 0, cancel == nil {
                #expect(FileManager.default.fileExists(atPath: path.path), "the render is writing its file")
                cancel = Task { @MainActor in
                    // Another id doesn't match the running render.
                    let other = try await dispatcher.call(.renderCancel, ["id": 8])
                    #expect(other["cancelled"] == .bool(false))
                    return try await dispatcher.call(.renderCancel, ["id": 7])
                }
            }
        }
        let error = try #require(response?.error)
        #expect(error.code == -32005 && error.dawError == "cancelled", "\(error.message)")
        let cancelResult = try #require(await cancel?.value)
        #expect(cancelResult["cancelled"] == .bool(true) && cancelResult["id"] == .int(7))
        #expect(!progress.isEmpty && progress.allSatisfy { $0 < 1 }, "progress never reached 1: \(progress)")
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0 < $1 }, "progress rose: \(progress)")
        #expect(!FileManager.default.fileExists(atPath: path.path), "the partial file is deleted")
        let telemetry = try await dispatcher.ok(.engineTelemetry)
        #expect(telemetry["rtViolations"] == .int(0))

        // The engine is fine afterwards.
        let render = try await dispatcher.ok(.renderOffline, ["from": 0, "to": 1920, "path": "after.wav", "tail": false])
        #expect(render["frames"] == .int(48_000))
        #expect(try await dispatcher.ok(.renderCancel)["cancelled"] == .bool(false), "nothing running any more")
    }

    @Test("DW-220: the engine's cancelJob ends a queued render at once and a running one before its next block; files deleted, finished and other jobs refused")
    func engineCancelJob() async throws {
        let dir = try TempDir()
        let dispatcher = TestDispatchers.real(workingDirectory: dir.url)
        _ = try await dispatcher.ok(.projectNew, ["name": "jobs", "sampleRate": 48_000])
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "A", "kind": "audio"]])
        let engine = try #require(dispatcher.engine)
        let long = Tick(Int64(600 * 2 * 960))
        let first = engine.renderOffline(from: Tick(0), to: long, spec: ExportSpec(path: dir.file("1.wav").path, tailEnabled: false))
        let second = engine.renderOffline(from: Tick(0), to: long, spec: ExportSpec(path: dir.file("2.wav").path, tailEnabled: false))
        #expect(engine.cancelJob(second), "queued behind the first")
        #expect(engine.pollJob(second).state == .cancelled, "a queued render is cancelled at once")
        #expect(!engine.cancelJob(second), "already finished")
        // Let the first one start writing. DW-231 (T-101): wait on the job, not ~1 s of wall clock (a
        // loaded machine can take longer to start the render); stop early if it ends some other way.
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            let poll = engine.pollJob(first)
            if poll.progress > 0 || poll.state.isFinished { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(engine.pollJob(first).progress > 0, "the first render has started writing")
        #expect(engine.pollJob(first).state == .running)
        #expect(engine.cancelJob(first))
        let status = await engine.waitForJob(first, timeout: .seconds(10))
        #expect(status.state == .cancelled && status.error == nil)
        #expect(status.render.map { $0.framesWritten > 0 && $0.rtViolations == 0 } == true, "the stats so far")
        #expect(!FileManager.default.fileExists(atPath: dir.file("1.wav").path))
        #expect(!FileManager.default.fileExists(atPath: dir.file("2.wav").path))
        #expect(!engine.cancelJob(first) && !engine.cancelJob(9999))
        let load = engine.loadAsset(99, path: dir.file("missing.wav").path)
        #expect(!engine.cancelJob(load), "only renders can be cancelled")
    }

    // MARK: DW-219 dither

    @Test("DW-219, IO-035: render.offline dithers int16 by default (seeded, so repeatable), dither: false doesn't, and float32 ignores it")
    func dither() async throws {
        let dir = try TempDir()
        let dispatcher = TestDispatchers.real(workingDirectory: dir.url)
        try await samplerProject(dispatcher, dir, note: true)
        func render(_ name: String, _ extra: [String: JSONValue]) async throws {
            var params: [String: JSONValue] = ["from": 0, "to": 1920, "path": .string(name), "tail": false]
            params.merge(extra) { _, new in new }
            _ = try await dispatcher.ok(.renderOffline, .object(params))
        }
        try await render("i16_default.wav", ["sampleFormat": "int16"])
        try await render("i16_on.wav", ["sampleFormat": "int16", "dither": true])
        try await render("i16_off.wav", ["sampleFormat": "int16", "dither": false])
        try await render("f32_on.wav", ["dither": true])
        try await render("f32_off.wav", ["dither": false])
        func residual(_ a: String, _ b: String) async throws -> Double {
            try #require(try await dispatcher.ok(.audioCompare, ["a": .string(a), "b": .string(b), "toleranceDb": -300])["nullResidualDb"]?.doubleValue)
        }
        #expect(try await residual("i16_default.wav", "i16_on.wav") == -240, "default = dither on, bit-identical")
        let dithered = try await residual("i16_default.wav", "i16_off.wav")
        #expect(dithered > -240 && dithered < -80, "dither changes int16 output by about an LSB: \(dithered) dB")
        #expect(try await residual("f32_on.wav", "f32_off.wav") == -240, "float32 is never dithered")
    }

    // MARK: DW-174 engine.meters

    @Test("DW-174, MIX-005, DSP-031: engine.meters after an offline render: strip levels in dBFS and the compressor's gain reduction; nodes filters; non-meters refused")
    func metersOffline() async throws {
        let dir = try TempDir()
        let dispatcher = TestDispatchers.real(workingDirectory: dir.url)
        try await samplerProject(dispatcher, dir, note: true)
        let before = try await meters(dispatcher)
        #expect(before.keys.sorted() == [1, 2, 5], "track, master, compressor")
        #expect(before[2]?["peakDb"]?[0]?.doubleValue == -240 && before[5]?["gainReductionDb"]?.doubleValue == 0, "nothing rendered yet")
        _ = try await dispatcher.ok(.renderOffline, ["from": 0, "to": 1920, "path": "m.wav", "tail": false])
        let after = try await meters(dispatcher)
        let track = try #require(after[2])
        #expect(track["kind"] == "track" && track["peakDb"]?.arrayValue?.count == 1 && track["rmsDb"]?.arrayValue?.count == 1)
        let peak = try #require(track["peakDb"]?[0]?.doubleValue), rms = try #require(track["rmsDb"]?[0]?.doubleValue)
        #expect(peak > -20 && peak <= 0 && rms < peak, "the held note: peak \(peak), rms \(rms)")
        #expect(after[2]?["gainReductionDb"] == nil)
        let master = try #require(after[1]?["peakDb"]?[0]?.doubleValue)
        #expect(after[1]?["kind"] == "master" && abs(master - (peak - 3.01)) < 0.1, "centre pan on the master: \(master)")
        let compressor = try #require(after[5])
        #expect(compressor["kind"] == "compressor" && compressor["peakDb"] == [] && compressor["rmsDb"] == [])
        let gr = try #require(compressor["gainReductionDb"]?.doubleValue)
        #expect(gr < -1 && gr >= -60, "a 0.5 sine over the −20 dB threshold is reduced: \(gr) dB")

        #expect(try await meters(dispatcher, ["nodes": [5, 1]]).keys.sorted() == [1, 5])
        let notMeter = await dispatcher.failure(.engineMeters, ["nodes": [3]])
        #expect(notMeter?.dawError == "invalidArgument", "an asset has no meter")
        #expect(await dispatcher.failure(.engineMeters, ["nodes": [4242]])?.dawError == "notFound")
        #expect(try await dispatcher.ok(.engineTelemetry)["rtViolations"] == .int(0))
    }

    @Test("DW-174: engine.meters converts the engine's linear readings (FakeEngine)")
    func metersConversion() async throws {
        let (dispatcher, engines) = TestDispatchers.fake()
        _ = try await dispatcher.ok(.projectNew, ["name": "m"])
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "A", "kind": "audio"]])
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddBus", "name": "B"]])
        engines.last.setMeter(2, MeterReading(peak: 0.5, rms: 0.25))
        let result = try await meters(dispatcher)
        #expect(result.count == 3)
        #expect(abs((result[2]?["peakDb"]?[0]?.doubleValue ?? 0) + 6.0206) < 1e-3)
        #expect(abs((result[2]?["rmsDb"]?[0]?.doubleValue ?? 0) + 12.0412) < 1e-3)
        #expect(result[3]?["kind"] == "bus" && result[3]?["peakDb"]?[0]?.doubleValue == -240, "no reading reads as silence")
    }

    // MARK: DW-189 engine.previewNote

    @Test("DW-189: engine.previewNote is notSupported (-32006) on an offline engine")
    func previewOffline() async throws {
        let dir = try TempDir()
        let dispatcher = TestDispatchers.real(workingDirectory: dir.url)
        try await samplerProject(dispatcher, dir, note: false)
        let error = await dispatcher.failure(.enginePreviewNote, ["track": 2, "pitch": 69])
        #expect(error?.code == -32006 && error?.dawError == "notSupported")
    }

    @Test("DW-189, UI-021: engine.previewNote on a realtime engine sends the note on now and its note-off after durationMs; bad tracks and values are refused")
    func previewCalls() async throws {
        let (dispatcher, engines) = TestDispatchers.fake(engineMode: .realtime(DriverConfig(sampleRate: 48_000, driver: .fake)))
        _ = try await dispatcher.ok(.projectNew, ["name": "p"])
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "Keys", "kind": "midi"]])
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "Audio", "kind": "audio"]])
        #expect(await dispatcher.failure(.enginePreviewNote, ["track": 2, "pitch": 60])?.dawError == "invalidArgument", "no instrument")
        _ = try await dispatcher.ok(.commandApply, ["command": [
            "type": "SetInstrument", "trackID": 2, "device": ["format": "builtin", "node": "sampler"],
        ]])
        let result = try await dispatcher.ok(.enginePreviewNote, ["track": 2, "pitch": 60, "durationMs": 30])
        #expect(result == ["track": 2, "pitch": 60, "velocity": 100, "durationMs": 30])
        let engine = engines.last
        func previews() -> [FakeEngine.Call] { engine.calls.filter { if case .previewNote = $0 { true } else { false } } }
        #expect(previews() == [.previewNote(track: 2, pitch: 60, velocity: 100, on: true)])
        for _ in 0..<200 where previews().count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(previews().last == .previewNote(track: 2, pitch: 60, velocity: 0, on: false))

        #expect(await dispatcher.failure(.enginePreviewNote, ["track": 3, "pitch": 60])?.dawError == "invalidArgument", "audio track")
        #expect(await dispatcher.failure(.enginePreviewNote, ["track": 99, "pitch": 60])?.dawError == "notFound")
        #expect(await dispatcher.failure(.enginePreviewNote, ["track": 2, "pitch": 128])?.dawError == "invalidParams")
        #expect(await dispatcher.failure(.enginePreviewNote, ["track": 2, "pitch": 60, "velocity": 0])?.dawError == "invalidParams")
        #expect(await dispatcher.failure(.enginePreviewNote, ["track": 2, "pitch": 60, "durationMs": 0])?.dawError == "invalidParams")
    }

    @Test("DW-189, DW-174: on a realtime engine (fake device) a previewed note is audible on the track meter, and stops after its duration; 0 RT violations")
    func previewAudible() async throws {
        let dir = try TempDir()
        let dispatcher = TestDispatchers.real(workingDirectory: dir.url)
        try await samplerProject(dispatcher, dir, engine: ["mode": "realtime", "driver": "fake"], note: false)
        func trackPeak() async throws -> Double { try #require(try await meters(dispatcher, ["nodes": [2]])[2]?["peakDb"]?[0]?.doubleValue) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await trackPeak() == -240, "silent before the note")
        _ = try await dispatcher.ok(.enginePreviewNote, ["track": 2, "pitch": 69, "velocity": 127, "durationMs": 300])
        var peak = -240.0
        for _ in 0..<100 where peak < -20 {
            try await Task.sleep(for: .milliseconds(10))
            peak = try await trackPeak()
        }
        #expect(peak > -20, "the note sounds: \(peak) dB")
        // Off after 300 ms, then the 0.2 s release; the meter's 300 ms window and peak fall-off follow.
        var after = peak
        for _ in 0..<300 where after > -100 {
            try await Task.sleep(for: .milliseconds(10))
            after = try await trackPeak()
        }
        #expect(after <= -100, "the note ended: \(after) dB")
        #expect(try await dispatcher.ok(.engineTelemetry)["rtViolations"] == .int(0))
    }
}
