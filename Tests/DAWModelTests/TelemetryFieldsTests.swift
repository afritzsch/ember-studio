import DAWEngine
import Foundation
import Testing

@testable import DAWModel

// T-099: the telemetry fields of 08 "Contract delta (T-099)" cross the facade into
// `EngineTelemetry` (EngineClient's conversion) and mean what they say, through the real engine in
// offline mode. The engine-level counting is checked in C++ (Tests/DAWEngineTests/
// EngineCounterTests.swift).

@Suite("Telemetry fields (T-099: DW-083, DW-170, DW-192)")
struct TelemetryFieldsTests {
    /// master 1 (limiter slot) ← metronome 2 at full level with a 4× accent, so a downbeat peaks
    /// near 16 and the limiter clips.
    private func clickGraph(engine: EngineClient) throws -> (EngineGraph, limiter: ParamID) {
        let limiter = try engine.allocateParams(1)
        let click = try engine.allocateParams(3)
        engine.setParam(click + 0, 1)  // on
        engine.setParam(click + 1, 3.98)  // level (+12 dB)
        engine.setParam(click + 2, 3.98)  // accent
        let graph = EngineGraph(
            nodes: [.init(id: 1, kind: .master, firstParam: limiter, numParams: 1),
                    .init(id: 2, kind: .metronome, firstParam: click, numParams: 3)],
            edges: [.init(id: 1, from: 2, to: 1)], master: 1)
        return (graph, limiter)
    }

    @Test("DW-083: clippedSamples counts the master limiter's overs since the engine was created; 0 with the limiter off")
    func clippedSamples() async throws {
        let engine = try EngineClient(.offline())
        let (graph, limiter) = try clickGraph(engine: engine)
        engine.applyGraph(graph)
        #expect(engine.telemetry().clippedSamples == 0)

        // Limiter off (the model's default, GraphDescriptionBuilder writes 0): nothing is clipped.
        engine.setParam(limiter, 0)
        var status = await engine.waitForJob(engine.renderOffline(from: 0, to: 1920, spec: ExportSpec(path: "")))
        #expect(status.state == .succeeded)
        #expect(engine.telemetry().clippedSamples == 0)

        engine.setParam(limiter, 1)
        status = await engine.waitForJob(engine.renderOffline(from: 0, to: 1920, spec: ExportSpec(path: "")))
        #expect(status.state == .succeeded)
        let first = engine.telemetry().clippedSamples
        #expect(first > 0)
        // The same render again counts the same overs again (offline renders reset the graph,
        // DW-063), on top: the count is all time, not per render.
        status = await engine.waitForJob(engine.renderOffline(from: 0, to: 1920, spec: ExportSpec(path: "")))
        #expect(status.state == .succeeded)
        #expect(engine.telemetry().clippedSamples == 2 * first)
        // A new master instance (configVersion bump) keeps the count going.
        var replaced = graph
        replaced.nodes[0].configVersion = 7
        engine.applyGraph(replaced)
        status = await engine.waitForJob(engine.renderOffline(from: 0, to: 1920, spec: ExportSpec(path: "")))
        #expect(status.state == .succeeded)
        #expect(engine.telemetry().clippedSamples == 3 * first)
        #expect(engine.telemetry().rtViolations == 0)
    }

    @Test("DW-170, DW-192: midiEventsDropped and bufferFrames start at 0; offline has no device, so no buffer size")
    func offlineDefaults() async throws {
        let engine = try EngineClient(.offline())
        let (graph, _) = try clickGraph(engine: engine)
        engine.applyGraph(graph)
        let status = await engine.waitForJob(engine.renderOffline(from: 0, to: 960, spec: ExportSpec(path: "")))
        #expect(status.state == .succeeded)
        let t = engine.telemetry()
        #expect(t.midiEventsDropped == 0)  // no MIDI edge overflowed (the C++ checks overflow one)
        #expect(t.bufferFrames == 0 && !t.deviceRunning)
        #expect(t.midiInputDrops == 0)  // distinct from midiEventsDropped
    }

    @Test("DW-083/170/192: the new fields are in engine.telemetry's JSON (EngineTelemetry is Codable)")
    func encoded() throws {
        var t = EngineTelemetry()
        t.clippedSamples = 5
        t.midiEventsDropped = 6
        t.bufferFrames = 128
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as? [String: Any]
        #expect(json?["clippedSamples"] as? Int == 5)
        #expect(json?["midiEventsDropped"] as? Int == 6)
        #expect(json?["bufferFrames"] as? Int == 128)
        #expect(json?["deviceInputLatency"] as? Int == 0)  // DW-192: IO-005's input latency
    }
}
