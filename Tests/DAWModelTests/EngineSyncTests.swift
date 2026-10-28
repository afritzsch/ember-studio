import Foundation
import Testing

@testable import DAWModel

@Suite("EngineSync (MODEL-021, MODEL-022, DW-072)")
@MainActor
struct EngineSyncTests {
    init() { TestCommands.register() }

    private func attached(_ project: Project, debounce: Duration = EngineSync.defaultDebounce)
        throws -> (ProjectStore, FakeEngine, EngineSync)
    {
        let store = ProjectStore(project: project)
        let engine = FakeEngine()
        let sync = try store.attachEngine(engine, debounce: debounce)
        return (store, engine, sync)
    }

    private func applies(_ engine: FakeEngine) -> Int {
        engine.calls.filter { if case .applyGraph = $0 { true } else { false } }.count
    }

    private func setParams(_ engine: FakeEngine) -> [ParamID: Float] {
        var out: [ParamID: Float] = [:]
        for case .setParam(let id, let value) in engine.calls { out[id] = value }
        return out
    }

    /// Long enough for any debounce window to have run out.
    private func idle() async throws {
        try await Task.sleep(for: .milliseconds(40))
    }

    // MARK: Attach

    @Test("MODEL-021/022: attaching allocates every slot, writes the values and applies the graph")
    func attach() throws {
        let (store, engine, sync) = try attached(GraphFixtures.routing())
        let p = store.project
        #expect(applies(engine) == 1)
        #expect(engine.appliedGraphs == [GraphDescriptionBuilder.build(p, runtime: sync.runtime)])
        #expect(sync.appliedGraph == engine.appliedGraphs.last)

        let required = GraphDescriptionBuilder.paramRequirements(p, catalog: sync.catalog)
        #expect(sync.runtime.params.mapValues(\.count) == required)
        let allocations = engine.calls.compactMap { if case .allocateParams(let n, _) = $0 { n } else { nil } }
        #expect(allocations.count == required.count)

        let vox = p.tracks[0]
        #expect(engine.getParam(sync.runtime.stripParam(vox.id, ParamLayout.Strip.gain)!) == 1)
        #expect(engine.getParam(sync.runtime.sendLevelParam(vox.sends[0].id)!) == 0.5)
        #expect(engine.getParam(sync.runtime.deviceParam(vox.inserts[0].id, 0)!) == 0.3)
        #expect(engine.telemetry().paramsAllocated == required.values.reduce(0, +))
    }

    // MARK: MODEL-021

    @Test("MODEL-021: param-only changes go to setParam and never apply a graph")
    func setParamDoesNotApplyGraph() async throws {
        let (store, engine, sync) = try attached(GraphFixtures.routing())
        engine.clearCalls()
        let vox = store.project.tracks[0]
        let main = store.project.buses[1]

        try store.edit { $0.tracks[0].strip.gain = 0.25 }
        try store.edit { $0.tracks[0].strip.pan = -1 }
        try store.edit { $0.tracks[0].strip.phaseInvert = true }
        try store.edit { $0.tracks[0].strip.mute = true }
        try store.edit { $0.tracks[0].sends[0].level = 0.75 }
        try store.edit { $0.tracks[0].inserts[0].params = [ParamValue(index: 0, value: 0.6)] }
        try store.edit { $0.buses[1].strip.gain = 2 }
        try store.edit { $0.master.strip.gain = 0.5 }
        try store.perform(TestSetGain(trackID: vox.id, gain: 0.125))
        store.undo()
        store.redo()
        #expect(!sync.hasPendingApply)
        try await idle()

        #expect(applies(engine) == 0)
        let r = sync.runtime
        let written = setParams(engine)
        #expect(written[r.stripParam(vox.id, ParamLayout.Strip.gain)!] == 0.125)
        #expect(written[r.stripParam(vox.id, ParamLayout.Strip.pan)!] == -1)
        #expect(written[r.stripParam(vox.id, ParamLayout.Strip.phase)!] == 1)
        #expect(written[r.stripParam(vox.id, ParamLayout.Strip.mute)!] == 1)
        #expect(written[r.deviceParam(vox.inserts[0].id, 0)!] == 0.6)
        #expect(written[r.stripParam(main.id, ParamLayout.Strip.gain)!] == 2)
        #expect(written[r.stripParam(store.project.master.id, ParamLayout.Strip.gain)!] == 0.5)
        // MIX-007: Vox is muted, so its send's mute slot is on too; the level keeps its value.
        #expect(written[r.sendMuteParam(vox.sends[0].id)!] == 1)
        #expect(written[r.sendLevelParam(vox.sends[0].id)!] == 0.75)
    }

    @Test("MODEL-021, MIX-006: solo flips other strips' mute slots without a rebuild")
    func soloIsParamOnly() async throws {
        let (store, engine, sync) = try attached(GraphFixtures.routing())
        engine.clearCalls()
        let p = store.project
        let (vox, kick) = (p.tracks[0], p.tracks[1])
        let (group, main, verb) = (p.buses[0], p.buses[1], p.buses[2])
        func muted(_ id: NodeIDValue) -> Bool { engine.getParam(sync.runtime.stripParam(id, ParamLayout.Strip.mute)!) == 1 }
        func sendMuted(_ send: Send) -> Bool { engine.getParam(sync.runtime.sendMuteParam(send.id)!) == 1 }
        func sendLevel(_ send: Send) -> Float? { engine.getParam(sync.runtime.sendLevelParam(send.id)!) }

        try store.edit { $0.tracks[0].strip.solo = true }
        #expect(!muted(vox.id) && muted(kick.id))
        #expect(!muted(group.id) && !muted(main.id) && !muted(verb.id), "buses Vox feeds stay audible")
        // MIX-007: Kick's pre-fader send is muted with it, so solo doesn't leak; its level stays.
        #expect(!sendMuted(vox.sends[0]) && sendMuted(kick.sends[0]))
        #expect(sendLevel(kick.sends[0]) == kick.sends[0].level)
        try store.edit { $0.tracks[0].strip.solo = false }
        #expect(!muted(kick.id) && !sendMuted(kick.sends[0]))
        try await idle()
        #expect(applies(engine) == 0)
    }

    @Test("MODEL-021: a name change touches nothing in the engine")
    func renameIsInert() async throws {
        let (store, engine, _) = try attached(GraphFixtures.audioTracks())
        engine.clearCalls()
        try store.perform(RenameTrack(trackID: store.project.tracks[0].id, name: "x"))
        try await idle()
        #expect(engine.calls.isEmpty)
    }

    @Test("MODEL-021: structural changes apply once per 10 ms window, from the latest project")
    func structuralDebounced() async throws {
        let (store, engine, sync) = try attached(GraphFixtures.audioTracks())
        engine.clearCalls()
        let track = store.project.tracks[1].id
        for i in 0..<5 {
            try store.perform(TestAddClip(trackID: track, start: Tick(Int64(i) * 960), length: 960))
        }
        #expect(applies(engine) == 0, "nothing until the window ends")
        #expect(sync.hasPendingApply)
        await sync.settle()
        #expect(applies(engine) == 1)
        let applied = try #require(engine.appliedGraphs.last)
        #expect(applied.audioClips.filter { $0.player == GraphNodeID.source(of: track) }.count == 5)
        #expect(applied == GraphDescriptionBuilder.build(store.project, runtime: sync.runtime))

        store.undo()
        await sync.settle()
        #expect(applies(engine) == 2, "undoing a structural change is structural")
        try await idle()
        #expect(applies(engine) == 2)
    }

    @Test("MODEL-021: a zero debounce applies inside perform; flush applies a waiting change now")
    func synchronousApply() throws {
        let (store, engine, _) = try attached(GraphFixtures.audioTracks(), debounce: .zero)
        engine.clearCalls()
        try store.perform(TestAddTrack(name: "New"))
        #expect(applies(engine) == 1)

        let (store2, engine2, sync2) = try attached(GraphFixtures.audioTracks())
        engine2.clearCalls()
        try store2.perform(TestAddTrack(name: "New"))
        sync2.flush()
        #expect(applies(engine2) == 1 && !sync2.hasPendingApply)
    }

    @Test("MODEL-003/021: a 100-step fader drag writes the slot 100 times and rebuilds nothing")
    func faderGesture() async throws {
        let (store, engine, sync) = try attached(GraphFixtures.audioTracks())
        engine.clearCalls()
        let track = store.project.tracks[0].id
        let slot = sync.runtime.stripParam(track, ParamLayout.Strip.gain)!
        store.beginGesture("Fader")
        for i in 1...100 { try store.perform(TestSetGain(trackID: track, gain: Float(i) / 100)) }
        store.endGesture()
        try await idle()
        #expect(applies(engine) == 0)
        let writes = engine.calls.filter { if case .setParam(slot, _) = $0 { true } else { false } }
        #expect(writes.count == 100)
        #expect(engine.getParam(slot) == 1)
    }

    @Test("MODEL-021, DW-072: a clip drag coalesces into one apply and bumps only that player")
    func clipGesture() async throws {
        let (store, engine, sync) = try attached(GraphFixtures.audioTracks())
        engine.clearCalls()
        let (a, b) = (store.project.tracks[0], store.project.tracks[1])
        store.beginGesture("Move Clip")
        for _ in 0..<50 { try store.perform(TestNudgeClip(trackID: a.id, clipID: a.clips[0].id, delta: 10)) }
        store.endGesture()
        await sync.settle()
        #expect(applies(engine) == 1)
        let nodes = try #require(engine.appliedGraphs.last).nodes
        #expect(nodes.first { $0.id == GraphNodeID.source(of: a.id) }?.configVersion == 1)
        #expect(nodes.first { $0.id == GraphNodeID.source(of: b.id) }?.configVersion == 0)
        #expect(sync.runtime.configVersions[GraphNodeID.source(of: a.id)] == 1)
    }

    // MARK: DW-072

    @Test("DW-072: assetLoaded bumps the players whose clips use the asset")
    func assetLoaded() async throws {
        var p = GraphFixtures.audioTracks()
        let other = p.ids.allocate()
        p.assets.append(AssetRef(id: other, path: "Audio/other.wav", channels: 1, originalSampleRate: 44_100, frames: 10))
        let (store, engine, sync) = try attached(p)
        let asset = store.project.assets[0].id
        let player = GraphNodeID.source(of: store.project.tracks[0].id)
        engine.clearCalls()

        _ = engine.loadAsset(asset, path: "Audio/loop.wav")
        let events = sync.pollEvents()
        #expect(events.contains { $0.kind == .assetLoaded && $0.subject == asset })
        await sync.settle()
        #expect(applies(engine) == 1)
        let nodes = try #require(engine.appliedGraphs.last).nodes
        #expect(nodes.first { $0.id == player }?.configVersion == 1)
        #expect(nodes.first { $0.id == GraphNodeID.source(of: store.project.tracks[1].id) }?.configVersion == 0)

        // No clip uses `other`: nothing to rebuild.
        _ = engine.loadAsset(other, path: "Audio/other.wav")
        _ = sync.pollEvents()
        try await idle()
        #expect(applies(engine) == 1)
    }

    @Test("DW-072: a rejected graph is reported in lastError")
    func graphRejected() async throws {
        let (store, engine, sync) = try attached(GraphFixtures.audioTracks(), debounce: .zero)
        engine.rejectNextGraph(with: .routingCycle(path: [1, 2]))
        try store.perform(TestAddTrack(name: "x"))
        _ = sync.pollEvents()
        #expect(sync.lastError == .routingCycle(path: [1, 2]))
    }

    // MARK: MODEL-022

    @Test("MODEL-022: new nodes get slots; removed nodes' slots are freed after the apply")
    func paramLifecycle() async throws {
        let (store, engine, sync) = try attached(GraphFixtures.audioTracks())
        engine.clearCalls()
        try store.perform(TestAddTrack(name: "C"))
        let added = store.project.tracks[2].id
        let range = try #require(sync.runtime.params[added])
        #expect(range.count == ParamLayout.Strip.count)
        #expect(engine.calls.first == .allocateParams(count: ParamLayout.Strip.count, first: range.first),
                "allocated before the graph that uses it")
        #expect(engine.getParam(range.first + ParamLayout.Strip.gain) == 1, "initial values written at once")
        await sync.settle()

        engine.clearCalls()
        store.undo()
        #expect(sync.runtime.params[added] != nil, "kept until the graph without it is applied")
        await sync.settle()
        #expect(sync.runtime.params[added] == nil)
        #expect(engine.calls.first == .applyGraph(version: 3))
        #expect(engine.calls.contains(.freeParams(first: range.first, count: range.count)))

        store.redo()
        let again = try #require(sync.runtime.params[added])
        #expect(again.count == ParamLayout.Strip.count)
    }

    @Test("MODEL-022: slots are runtime-only and reallocated when a project is opened again")
    func reallocatedOnLoad() throws {
        let original = GraphFixtures.routing()
        let json = try JSONEncoder().encode(original)
        #expect(!String(decoding: json, as: UTF8.self).contains("firstParam"))

        // Another engine already has slots in use, as after a previous session's project.
        let engine = FakeEngine()
        _ = try engine.allocateParams(100)
        let store = ProjectStore(project: try JSONDecoder().decode(Project.self, from: json))
        let sync = try store.attachEngine(engine)
        #expect(sync.runtime.params.values.allSatisfy { $0.first >= 100 })
        #expect(sync.runtime.params.count == GraphDescriptionBuilder.paramRequirements(original, catalog: sync.catalog).count)
        #expect(sync.runtime.configVersions.isEmpty)
    }

    @Test("MODEL-022: device param counts and defaults come from the kind's ParamInfo")
    func catalogDefaults() throws {
        let engine = FakeEngine()
        let sync = try EngineSync(engine: engine, project: GraphFixtures.routing(), catalog: testCatalog)
        let vox = GraphFixtures.routing().tracks[0]
        let eq = vox.inserts[0]
        #expect(sync.runtime.params[eq.id]?.count == 3)
        #expect(engine.getParam(sync.runtime.deviceParam(eq.id, 0)!) == 0.3, "stored value")
        #expect(engine.getParam(sync.runtime.deviceParam(eq.id, 2)!) == 1, "ParamInfo default")
        #expect(ParamCatalog.parseDefaults(#"[{"index":1,"default":0.5},{"index":0,"default":2}]"#) == [2, 0.5])
        #expect(ParamCatalog.parseDefaults("not json").isEmpty)
    }

    @Test("MODEL-022: detaching frees every slot")
    func detach() throws {
        let (store, engine, _) = try attached(GraphFixtures.routing())
        #expect(engine.telemetry().paramsAllocated > 0)
        store.detachEngine()
        #expect(engine.telemetry().paramsAllocated == 0)
        engine.clearCalls()
        try store.edit { $0.tracks[0].strip.gain = 0 }
        #expect(engine.calls.isEmpty && store.engineSync == nil)
    }
}
