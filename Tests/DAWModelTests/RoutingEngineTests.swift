import Foundation
import Testing

@testable import DAWModel

// Routing commands driving the engine (MODEL-021): param commands are slot writes, routing
// commands rebuild; and against the real engine, a project routed only with commands renders
// through its buses with 0 RT violations.

@Suite("Routing commands and the engine")
@MainActor
struct RoutingEngineTests {
    init() { TestCommands.register() }

    private func applies(_ engine: FakeEngine) -> Int {
        engine.calls.filter { if case .applyGraph = $0 { true } else { false } }.count
    }

    @Test("MODEL-021, DW-094: SetParam and SetSendLevel write slots and never apply a graph; routing commands rebuild")
    func paramVersusStructural() async throws {
        var p = RoutingProject.make()
        // FakeEngine publishes no ParamInfo, so the compressor gets slots only for stored values.
        p.tracks[0].inserts[0].params = [ParamValue(index: 0, value: 0.5)]
        let store = ProjectStore(project: p)
        let engine = FakeEngine()
        let sync = try store.attachEngine(engine, debounce: .milliseconds(1))
        engine.clearCalls()

        store.beginGesture("Fader")
        for i in 0...100 {
            try store.perform(SetParam(target: .strip(channel: p.vox.id, param: .gain), value: Float(i) / 100))
        }
        store.endGesture()
        try store.perform(SetSendLevel(sendID: p.vox.sends[0].id, level: 0.1))
        try store.perform(SetParam(target: .strip(channel: p.kick.id, param: .solo), value: 1))
        try store.perform(SetParam(target: .device(slot: p.vox.inserts[0].id, index: 0), value: 0.4))
        #expect(store.undoLabel == "Set Parameter" && store.canUndo)
        try await Task.sleep(for: .milliseconds(20))
        #expect(applies(engine) == 0 && !sync.hasPendingApply)
        #expect(engine.getParam(sync.runtime.stripParam(p.vox.id, ParamLayout.Strip.gain)!) == 1)
        #expect(engine.getParam(sync.runtime.sendLevelParam(p.vox.sends[0].id)!) == 0.1)
        #expect(engine.getParam(sync.runtime.deviceParam(p.vox.inserts[0].id, 0)!) == 0.4)
        // MIX-006/007: soloing Kick solo-mutes Vox's strip and its send; Kick's pre-send keeps A audible.
        #expect(engine.getParam(sync.runtime.stripParam(p.vox.id, ParamLayout.Strip.mute)!) == 1)
        #expect(engine.getParam(sync.runtime.sendMuteParam(p.vox.sends[0].id)!) == 1)
        #expect(engine.getParam(sync.runtime.stripParam(p.a.id, ParamLayout.Strip.mute)!) == 0)

        try store.perform(AddSend(channelID: p.a.id, busID: p.b.id))
        sync.flush()
        #expect(applies(engine) == 1)
        let send = store.project.a.sends[0].id
        #expect(sync.appliedGraph?.nodes.contains { $0.id == send && $0.kind == .gain && $0.numParams == 2 } == true)
        #expect(sync.appliedGraph?.edges.contains { $0.from == send && $0.to == GraphNodeID.input(of: p.b.id) } == true)
    }

    /// A mono 16-bit WAV of a 1 kHz sine at half scale.
    private func writeSineWAV(_ url: URL, frames: Int) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frames * 2))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(48_000)); append(UInt32(96_000)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(frames * 2))
        for i in 0..<frames { append(Int16(16_384 * sin(2 * Double.pi * 1000 * Double(i) / 48_000))) }
        try data.write(to: url)
    }

    @Test("MODEL-005, MODEL-030: a project routed with commands renders through its buses in the real engine; 0 RT violations")
    func realEngine() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appending(path: "sine.wav")
        try writeSineWAV(wav, frames: 48_000)

        let engine = try EngineClient(.offline(sampleRate: 48_000))
        let store = ProjectStore(project: Project(name: "routed"))
        let sync = try store.attachEngine(engine)

        // Src → Group → master; Src pre-fader send → FX; FX → Group.
        try store.perform(AddBus(name: "Group"))
        try store.perform(AddBus(name: "FX"))
        let group = store.project.buses[0].id, fx = store.project.buses[1].id
        try store.perform(AddTrack(name: "Src", kind: .audio, output: .bus(group)))
        let src = store.project.tracks[0].id
        try store.perform(AddSend(channelID: src, busID: fx, level: 1, tap: .preFader))
        try store.perform(SetTrackOutput(channelID: fx, output: .bus(group)))
        #expect(throws: DAWError.routingCycle(path: [group, fx, group])) {
            try store.perform(AddSend(channelID: group, busID: fx))
        }
        // No clip commands yet (T-030): put the asset and clip in directly.
        try store.edit { p in
            let asset = p.ids.allocate()
            p.assets = [AssetRef(id: asset, path: wav.path, channels: 1, originalSampleRate: 48_000, frames: 48_000)]
            p.tracks[0].clips = [.audio(AudioClip(id: p.ids.allocate(), assetID: asset, start: 0, length: 7680))]
        }
        let asset = store.project.assets[0].id
        #expect(await engine.waitForJob(engine.loadAsset(asset, path: wav.path)).state == .succeeded)
        _ = sync.pollEvents()
        await sync.settle()
        let status = await engine.graphApplied(engine.graphStatus().submittedVersion)
        #expect(status.lastError == nil, "the routed graph compiles: \(String(describing: status.lastError))")

        let spec = ExportSpec(path: "", blockSize: 512, tailEnabled: false)
        func render() async throws -> (src: Float, fx: Float, group: Float) {
            let result = try #require(await engine.waitForJob(engine.renderOffline(from: 0, to: 960, spec: spec)).render)
            #expect(result.rtViolations == 0)
            return (try #require(engine.meter(src)).peak, try #require(engine.meter(fx)).peak, try #require(engine.meter(group)).peak)
        }
        var peaks = try await render()
        #expect(peaks.src > 0.1 && peaks.fx > 0.1 && peaks.group > peaks.src, "Group sums Src and FX")

        // Fader down: the pre-fader send keeps FX fed; a slot write, no rebuild.
        let version = engine.graphStatus().submittedVersion
        try store.perform(SetParam(target: .strip(channel: src, param: .gain), value: 0))
        _ = try await render()
        peaks = try await render()
        #expect(peaks.src == 0 && peaks.fx > 0.1)

        // Muting Src silences its pre-fader send too (MIX-007).
        try store.perform(SetParam(target: .strip(channel: src, param: .mute), value: 1))
        _ = try await render()
        peaks = try await render()
        #expect(peaks.fx == 0 && peaks.group == 0)
        #expect(engine.graphStatus().submittedVersion == version, "param commands never rebuild")

        // Removing FX reroutes nothing else and the graph still compiles.
        try store.perform(RemoveBus(busID: fx))
        await sync.settle()
        let after = await engine.graphApplied(engine.graphStatus().submittedVersion)
        #expect(after.lastError == nil && store.project.tracks[0].sends.isEmpty)
        #expect(engine.telemetry().rtViolations == 0)
    }
}
