import Foundation
import Testing

@testable import DAWModel

/// T-056: MODEL-005 `SetSessionSampleRate` (history-exempt, decided in docs/autobuild/DECISIONS.md
/// "T-056 undo"), its inverse `RestoreSessionSampleRate`, DW-126 (session-rate sample quantities
/// rescaled), and the engine side through `EngineSync`/`ProjectStore`: the engine is asked first,
/// a refusal changes nothing, and the document follows an engine-side change (DW-130).
@Suite("SetSessionSampleRate (MODEL-005, DW-126, DW-130)")
@MainActor
struct SessionSampleRateTests {
    /// Two audio clips (offsets 0 and 48 000 + 80, i.e. 1 s and a half-sample case at 44.1 kHz), a
    /// MIDI track whose sampler has a looped zone, at 48 kHz.
    private func fixture() throws -> Project {
        var p = Project()
        let asset = AssetRef(id: p.ids.next, path: "/tmp/a.wav", channels: 2, originalSampleRate: 44_100, frames: 441_000)
        _ = try ImportAsset(asset: asset).apply(to: &p)
        _ = try AddTrack(name: "Audio", kind: .audio).apply(to: &p)
        let audio = p.tracks[0].id
        _ = try AddClip(trackID: audio, start: Tick(0), length: Tick(960), assetID: asset.id, sourceOffsetSamples: 0).apply(to: &p)
        _ = try AddClip(trackID: audio, start: Tick(1920), length: Tick(960), assetID: asset.id,
                        sourceOffsetSamples: 48_080).apply(to: &p)
        _ = try AddTrack(name: "Keys", kind: .midi).apply(to: &p)
        let midi = p.tracks[1].id
        _ = try SetInstrument(trackID: midi, device: .builtin(.sampler),
                              zones: [SamplerZone(assetID: asset.id, loopStart: 4_800, loopEnd: 96_000),
                                      SamplerZone(assetID: asset.id, rootKey: 72)]).apply(to: &p)
        return p
    }

    private func offsets(_ p: Project) -> [Int64] {
        p.tracks.flatMap(\.clips).compactMap { if case .audio(let c) = $0 { c.sourceOffsetSamples } else { nil } }
    }

    private func loops(_ p: Project) -> [[Int64?]] {
        p.allDeviceSlots.flatMap(\.zones).map { [$0.loopStart, $0.loopEnd] }
    }

    // MARK: Command (MODEL-005, DW-126)

    @Test("MODEL-005, DW-126: SetSessionSampleRate sets the rate and tempo map and rescales clip offsets and zone loops")
    func rescales() throws {
        var p = try fixture()
        _ = try SetSessionSampleRate(sampleRate: 44_100).apply(to: &p)
        #expect(p.sessionSampleRate == 44_100 && p.tempoMap.sampleRate == 44_100)
        // 48 080 × 147/160 = 44 173.5 → 44 174 (halves up).
        #expect(offsets(p) == [0, 44_174])
        // 4 800 → 4 410, 96 000 → 88 200; the unlooped zone stays unlooped.
        #expect(loops(p) == [[4_410, 88_200], [nil, nil]])
        // Ticks don't move (D-06): clip starts and lengths are the same.
        #expect(p.tracks[0].clips.map(\.start) == [Tick(0), Tick(1920)])
        try p.validate()
    }

    @Test("MODEL-005: apply → JSON-decoded inverse → redo round-trips exactly, through the wire form")
    func roundTrip() throws {
        let original = try fixture()
        for rate in [44_100.0, 88_200, 96_000] {
            var p = original
            let command = try CommandRegistry.decode(CommandRegistry.encode(SetSessionSampleRate(sampleRate: rate)))
            let inverse = try command.apply(to: &p)
            let changed = p
            #expect(changed.sessionSampleRate == rate)
            let decodedInverse = try CommandRegistry.decode(CommandRegistry.encode(inverse))
            #expect(decodedInverse is RestoreSessionSampleRate)
            let redo = try decodedInverse.apply(to: &p)
            #expect(p == original, "the inverse restores the exact offsets, not a rescale back")
            _ = try CommandRegistry.decode(CommandRegistry.encode(redo)).apply(to: &p)
            #expect(p == changed)
        }
        // The same rate changes nothing.
        var same = original
        _ = try SetSessionSampleRate(sampleRate: 48_000).apply(to: &same)
        #expect(same == original)
    }

    @Test("DW-126: rounding is to the nearest sample, halves up, exact in integers; clamped to 2^48")
    func rounding() {
        #expect(Project.rescaleSamples(1, from: 48_000, to: 44_100) == 1)        // 0.91875
        #expect(Project.rescaleSamples(80, from: 48_000, to: 44_100) == 74)      // 73.5 → 74
        #expect(Project.rescaleSamples(160, from: 48_000, to: 44_100) == 147)
        #expect(Project.rescaleSamples(147, from: 44_100, to: 48_000) == 160)
        #expect(Project.rescaleSamples(1, from: 96_000, to: 44_100) == 0)        // 0.459…
        #expect(Project.rescaleSamples(0, from: 44_100, to: 96_000) == 0)
        #expect(Project.rescaleSamples(1 << 47, from: 44_100, to: 96_000) == AudioClip.maxSourceOffset)
        let big: Int64 = 123_456_789_012
        #expect(Project.rescaleSamples(big, from: 48_000, to: 96_000) == 2 * big)
    }

    @Test("DW-126: a tiny zone loop keeps at least one frame")
    func tinyLoop() throws {
        var p = Project(name: "t")
        let asset = AssetRef(id: p.ids.next, path: "/tmp/a.wav", channels: 1, originalSampleRate: 96_000, frames: 10)
        _ = try ImportAsset(asset: asset).apply(to: &p)
        _ = try AddTrack(name: "Keys", kind: .midi).apply(to: &p)
        _ = try SetInstrument(trackID: p.tracks[0].id, device: .builtin(.sampler),
                              zones: [SamplerZone(assetID: asset.id, loopStart: 0, loopEnd: 1)]).apply(to: &p)
        _ = try SetSessionSampleRate(sampleRate: 96_000).apply(to: &p)
        _ = try SetSessionSampleRate(sampleRate: 44_100).apply(to: &p)  // 1 × 147/320 rounds to 0
        #expect(loops(p) == [[0, 1]])
        try p.validate()
    }

    @Test("MODEL-031: a rate that isn't 44.1/48/88.2/96 kHz throws and changes nothing", arguments: [0.0, -48_000, 22_050, 192_000, 48_000.5, .nan])
    func rejects(_ rate: Double) throws {
        let original = try fixture()
        var p = original
        #expect(throws: DAWError.self) { _ = try SetSessionSampleRate(sampleRate: rate).apply(to: &p) }
        #expect(throws: DAWError.self) { _ = try RestoreSessionSampleRate(sampleRate: rate).apply(to: &p) }
        #expect(p == original)
    }

    @Test("MODEL-031: RestoreSessionSampleRate refuses unknown clips and zones and offsets out of range")
    func restoreRejects() throws {
        let original = try fixture()
        let slot = original.tracks[1].instrument!.id
        for bad in [
            RestoreSessionSampleRate(sampleRate: 44_100, clipOffsets: [.init(clipID: 999, sourceOffsetSamples: 0)]),
            RestoreSessionSampleRate(sampleRate: 44_100, clipOffsets: [.init(clipID: original.tracks[0].clips[0].id, sourceOffsetSamples: -1)]),
            RestoreSessionSampleRate(sampleRate: 44_100, zoneLoops: [.init(slotID: slot, zone: 1, loopStart: 0, loopEnd: 5)]),
            RestoreSessionSampleRate(sampleRate: 44_100, zoneLoops: [.init(slotID: slot, zone: 0, loopStart: 5, loopEnd: 5)]),
            RestoreSessionSampleRate(sampleRate: 44_100, zoneLoops: [.init(slotID: 999, zone: 0, loopStart: 0, loopEnd: 5)]),
        ] {
            var p = original
            #expect(throws: DAWError.self) { _ = try bad.applyAtomically(to: &p) }
            #expect(p == original)
        }
    }

    // MARK: History (decided: history-exempt)

    @Test("MODEL-005 (DECISIONS T-056 undo): persisted and dirty, never in undo history, refused in a composite")
    func historyExempt() async throws {
        let store = ProjectStore(project: try fixture())
        try store.perform(RenameTrack(trackID: store.project.tracks[0].id, name: "Drums"))
        let undoLabel = store.undoLabel
        var changes: [ProjectChange] = []
        let stream = store.changeStream()
        try store.perform(SetSessionSampleRate(sampleRate: 96_000))
        #expect(store.project.sessionSampleRate == 96_000 && store.isDirty)
        #expect(store.undoLabel == undoLabel, "the rate change left no undo entry")
        store.undo()
        #expect(store.project.sessionSampleRate == 96_000, "undo steps over it")
        #expect(store.project.tracks[0].name == "Audio")
        for await change in stream {
            changes.append(change)
            if changes.count == 2 { break }
        }
        #expect(changes[0].cause == .perform && changes[0].changedFields.contains(.sessionSampleRate))
        #expect(throws: DAWError.self) {
            try store.perform(CompositeCommand("x", [SetSessionSampleRate(sampleRate: 44_100)]))
        }
        #expect(store.project.sessionSampleRate == 96_000)
        // Saved and reopened, the rate and offsets are kept (MODEL-040).
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(store.project))
        #expect(decoded == store.project)
    }

    // MARK: Engine (IO-033 model side, DW-130)

    private func attached(_ project: Project) throws -> (ProjectStore, FakeEngine, EngineSync) {
        let store = ProjectStore(project: project)
        let engine = FakeEngine()
        let sync = try store.attachEngine(engine, debounce: .zero)
        return (store, engine, sync)
    }

    @Test("IO-033: the engine changes rate first, then gets the graph with the rescaled offsets")
    func engineFirst() throws {
        let (store, engine, sync) = try attached(try fixture())
        engine.clearCalls()
        try store.perform(SetSessionSampleRate(sampleRate: 44_100))
        let calls = engine.calls
        let rateCall = try #require(calls.firstIndex(of: .setSessionSampleRate(44_100)))
        let applyCall = try #require(calls.firstIndex { if case .applyGraph = $0 { true } else { false } })
        #expect(rateCall < applyCall)
        #expect(engine.appliedGraphs.last?.audioClips.map(\.sourceOffsetSamples) == [0, 44_174])
        #expect(sync.engineSampleRate == 44_100 && engine.telemetry().sampleRate == 44_100)
        // Its own events don't make the document move again.
        engine.clearCalls()
        let events = sync.pollEvents()
        #expect(events.contains { $0.reload?.phase == .started && $0.reload?.sampleRate == 44_100 })
        #expect(store.project.sessionSampleRate == 44_100)
        #expect(!engine.calls.contains { if case .setSessionSampleRate = $0 { true } else { false } })
    }

    @Test("IO-033: a rate the engine refuses (its device can't run it) changes nothing, not even the dirty flag")
    func engineRefuses() throws {
        let (store, engine, _) = try attached(try fixture())
        let before = store.project
        engine.refuseSessionRate(96_000)
        #expect(throws: DAWError.notImplemented("the device can't run at 96000.0 Hz")) {
            try store.perform(SetSessionSampleRate(sampleRate: 96_000))
        }
        #expect(store.project == before && !store.isDirty)
        #expect(engine.telemetry().sampleRate == 48_000)
        // A bad rate never reaches the engine.
        engine.clearCalls()
        #expect(throws: DAWError.self) { try store.perform(SetSessionSampleRate(sampleRate: 12_345)) }
        #expect(engine.calls.isEmpty)
    }

    @Test("DW-130: the document follows a rate change the engine made by itself (device fallback), not undoable")
    func followsEngine() throws {
        let (store, engine, sync) = try attached(try fixture())
        engine.clearCalls()
        engine.simulateEngineRateChange(to: 44_100)
        _ = sync.pollEvents()
        #expect(store.project.sessionSampleRate == 44_100)
        #expect(offsets(store.project) == [0, 44_174])
        #expect(store.isDirty && !store.canUndo)
        // The engine already runs at it: nothing is sent back.
        #expect(!engine.calls.contains { if case .setSessionSampleRate = $0 { true } else { false } })
        #expect(engine.appliedGraphs.last?.audioClips.map(\.sourceOffsetSamples) == [0, 44_174])
    }

    @Test("DW-130: events older than the engine's state don't bounce the document back")
    func staleEvents() throws {
        let (store, engine, sync) = try attached(try fixture())
        try store.perform(SetSessionSampleRate(sampleRate: 44_100))
        try store.perform(SetSessionSampleRate(sampleRate: 96_000))
        engine.clearCalls()
        _ = sync.pollEvents()  // started 48 → 44.1 … then 44.1 → 96
        #expect(store.project.sessionSampleRate == 96_000 && engine.telemetry().sampleRate == 96_000)
        #expect(!engine.calls.contains { if case .setSessionSampleRate = $0 { true } else { false } })
    }
}
