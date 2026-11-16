import DAWControl
import DAWModel
import Foundation
import Testing

// TEST-008 (T-084): performance smoke. 64 audio tracks, each with an EQ and a compressor insert and
// a post-fader send, into 8 buses with a reverb each, at 48 kHz in 128-frame blocks, rendered
// offline through the production path (Dispatcher → EngineClient → facade → OfflineDriver, as
// `dawctl` runs it). Target ≥ 20× realtime on Apple Silicon; the test fails under 10×.
//
// The bound is wall-clock, so it is strict only with DAW_PERF_TESTS=1 (the `perf` CI job,
// `scripts/ci.sh perf`, which runs it alone in a release build, like UI-010 since T-090). Without
// it the test renders a short version under whatever else runs in parallel and only reports.
// Either way it prints the ratio, and with DAW_PERF_REPORT=<path> it writes the ratio and the
// engine's telemetry snapshot to that file as JSON (the perf job's telemetry output).

@Suite("Perf smoke (TEST-008)")
struct PerfSmokeTests {
    static let strict = ProcessInfo.processInfo.environment["DAW_PERF_TESTS"] == "1"
    static let rate = 48000.0
    static let blockSize: UInt32 = 128
    static let tracks = 64
    static let buses = 8
    /// The test asset: 1 s of a 440 Hz sine at 48 kHz (1920 ticks at the default 120 bpm).
    static let clipTicks: Int64 = 1920
    /// Audio rendered: 30 s strict; 1 s otherwise, since a Debug engine (C++ at -O0) renders this
    /// scene well below realtime. Ticks at 120 bpm, 960 PPQ: 1920 per second.
    static let seconds: Int64 = strict ? 30 : 1
    static let minimumRatio = 10.0
    static let targetRatio = 20.0

    /// EQ with every band and both filters on, so no band is skipped (06 DSP-030, nodes/Eq.h).
    static let eqParams: [ParamValue] = [
        (0, 1), (1, 40), (3, 1), (5, 2), (7, 1), (9, 3), (11, 1), (13, -2), (15, 1), (17, 1.5), (19, 1), (20, 16000),
    ].map { ParamValue(index: $0.0, value: $0.1) }
    /// Compressor: threshold −24 dB, ratio 4, attack 5 ms, release 120 ms, knee 6, makeup 4 dB (as m7_scene).
    static let compParams: [ParamValue] = [(0, -24), (1, 4), (2, 5), (3, 120), (4, 6), (5, 4)]
        .map { ParamValue(index: $0.0, value: $0.1) }
    /// Reverb: size 0.7, decay 1.2 s, damping 0.5, pre-delay 20 ms, mix 1 (as m7_scene).
    static let reverbParams: [ParamValue] = [(0, 0.7), (1, 1.2), (2, 0.5), (3, 20), (4, 1)]
        .map { ParamValue(index: $0.0, value: $0.1) }

    /// The scene as one atomic `command.batch`: 8 reverb buses, then 64 tracks with their clips.
    /// IDs start at `firstID`, above everything `project.new` and `asset.import` handed out.
    static func sceneCommands(asset: ModelID, firstID: ModelID) throws -> [JSONValue] {
        var next = firstID
        func id() -> ModelID { defer { next += 1 }; return next }
        var commands: [JSONValue] = []
        var busIDs: [ModelID] = []
        for b in 0..<buses {
            let bus = Bus(id: id(), name: "Verb \(b)",
                          inserts: [DeviceSlot(id: id(), kind: .builtin(.reverb), params: reverbParams)])
            busIDs.append(bus.id)
            commands.append(["type": "RestoreBus", "index": .int(Int64(b)), "bus": try JSONValue(encoding: bus)])
        }
        let clipsPerTrack = (seconds * 1920 + clipTicks - 1) / clipTicks
        for t in 0..<tracks {
            var strip = ChannelStripState()
            strip.gain = 0.05  // 64 sines into one master stay below full scale
            strip.pan = Float(t % 9 - 4) / 4
            let clips = (0..<clipsPerTrack).map { c in
                Clip.audio(AudioClip(id: id(), assetID: asset, start: Tick(c * clipTicks), length: Tick(clipTicks)))
            }
            let track = Track(
                id: id(), name: "Track \(t)", kind: .audio, clips: clips,
                inserts: [DeviceSlot(id: id(), kind: .builtin(.eq), params: eqParams),
                          DeviceSlot(id: id(), kind: .builtin(.compressor), params: compParams)],
                strip: strip, sends: [Send(id: id(), target: busIDs[t % buses], level: 0.3)])
            commands.append(["type": "RestoreTrack", "index": .int(Int64(t)), "track": try JSONValue(encoding: track)])
        }
        return commands
    }

    @Test("TEST-008: 64 tracks × (EQ + compressor) + 8 reverb buses at 48 kHz / 128 frames render offline ≥ 10× realtime (target 20×)")
    @MainActor func offlineRealtimeRatio() async throws {
        let work = FileManager.default.temporaryDirectory
            .appending(path: "perf-smoke-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let dispatcher = Dispatcher(configuration: .init(mode: .headless, workingDirectory: work))

        _ = try await dispatcher.call(.projectNew, ["name": "perf_smoke", "sampleRate": .double(Self.rate)])
        let asset = GoldenHarness.fixturesDirectory.appending(path: "assets/a440_48k.wav").path
        let imported = try await dispatcher.call(.assetImport, ["path": .string(asset)])
        let assetID = try #require(imported["assetID"]?.int64Value)
        let commands = try Self.sceneCommands(asset: ModelID(assetID), firstID: 1000)
        _ = try await dispatcher.call(.commandBatch, ["commands": .array(commands), "atomic": true])

        let project = try await dispatcher.call(.projectGet)
        #expect(project["tracks"]?.arrayValue?.count == Self.tracks)
        #expect(project["buses"]?.arrayValue?.count == Self.buses)

        let response = try await dispatcher.call(.renderOffline, [
            "from": 0, "to": .int(Self.seconds * 1920), "path": "perf_smoke.wav",
            "blockSize": .int(Int64(Self.blockSize)), "tail": false,
        ])
        let render = try response.decode(RenderOfflineResult.self)
        let telemetry = try await dispatcher.call(.engineTelemetry)
        let ratio = render.durationSec / max(render.renderTimeSec, 1e-9)

        print(String(format: "TEST-008: %d tracks × (EQ + comp) + %d reverb buses, %.0f s at %.0f Hz / %u frames: "
                     + "rendered in %.3f s = %.1f× realtime (target %.0f×, fail < %.0f×; %@)",
                     Self.tracks, Self.buses, render.durationSec, render.sampleRate, Self.blockSize,
                     render.renderTimeSec, ratio, Self.targetRatio, Self.minimumRatio,
                     Self.strict ? "strict, DAW_PERF_TESTS=1" : "report only"))
        if Self.strict && ratio < Self.targetRatio {
            print("TEST-008: warning: \(String(format: "%.1f", ratio))× is below the \(Self.targetRatio)× target")
        }
        if let path = ProcessInfo.processInfo.environment["DAW_PERF_REPORT"] {
            let report: JSONValue = [
                "test": "TEST-008", "strict": .bool(Self.strict), "tracks": .int(Int64(Self.tracks)),
                "buses": .int(Int64(Self.buses)), "sampleRate": .double(render.sampleRate),
                "blockSize": .int(Int64(Self.blockSize)), "audioSeconds": .double(render.durationSec),
                "renderSeconds": .double(render.renderTimeSec), "realtimeRatio": .double(ratio),
                "targetRatio": .double(Self.targetRatio), "minimumRatio": .double(Self.minimumRatio),
                "rtViolations": .int(Int64(render.rtViolations)), "telemetry": telemetry,
            ]
            try Data(report.jsonString().utf8).write(to: URL(fileURLWithPath: path))
        }

        #expect(render.frames == Self.seconds * Int64(Self.rate))
        #expect(render.rtViolations == 0)  // CONV §5.3
        #expect(telemetry["rtViolations"]?.int64Value == 0)
        if Self.strict {
            #expect(ratio >= Self.minimumRatio, "TEST-008: \(ratio)× realtime, needs ≥ \(Self.minimumRatio)×")
        }
    }
}
