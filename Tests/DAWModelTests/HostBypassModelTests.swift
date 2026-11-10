import Foundation
import Testing

@testable import DAWModel

// T-064: the model halves of PLUG-018 (SetDeviceBypass, bypassed devices stay in the graph with a
// bypass slot) and PLUG-021 (safe mode, the running marker). The engine halves are in
// DAWEngineTests (BypassTests, VST3PluginTests, AUPluginTests); the golden null is in GoldenTests.

@MainActor
private func bypassProject() -> (Project, au: ModelID, vst3: ModelID, eq: ModelID, sampler: ModelID, midi: ModelID) {
    var p = Project(name: "bypass")
    let audio = p.ids.allocate()
    let au = p.ids.allocate()
    let eq = p.ids.allocate()
    let midi = p.ids.allocate()
    let sampler = p.ids.allocate()
    let vst3 = p.ids.allocate()
    p.tracks = [
        Track(id: audio, name: "Audio", kind: .audio,
              inserts: [DeviceSlot(id: au, kind: .au(AUDescriptor(identifier: "aufx:dely:appl", name: "AUDelay"))),
                        DeviceSlot(id: eq, kind: .builtin(.eq), bypass: true)]),
        Track(id: midi, name: "MIDI", kind: .midi, instrument: DeviceSlot(id: sampler, kind: .builtin(.sampler), bypass: true)),
    ]
    p.master.inserts = [DeviceSlot(id: vst3, kind: .vst3(VST3Descriptor(identifier: "/x.vst3#00", name: "Again")))]
    return (p, au, vst3, eq, sampler, midi)
}

@Suite("Host bypass, model side (PLUG-018, MODEL-005 SetDeviceBypass)")
@MainActor
struct HostBypassModelTests {
    private func applies(_ engine: FakeEngine) -> Int {
        engine.calls.filter { if case .applyGraph = $0 { true } else { false } }.count
    }

    private func bypassValue(_ sync: EngineSync, _ engine: FakeEngine, _ slot: ModelID) -> Float? {
        sync.runtime.paramID(GraphNodeID.bypass(of: slot), 0).map { engine.getParam($0) }
    }

    @Test("MODEL-005: SetDeviceBypass applies, inverts (JSON round trip) and redoes on inserts, instruments and master inserts")
    func roundTrip() throws {
        let (original, au, vst3, eq, sampler, _) = bypassProject()
        for (slot, value) in [(au, true), (eq, false), (sampler, false), (vst3, true)] {
            var p = original
            let inverse = try SetDeviceBypass(slotID: slot, bypass: value).apply(to: &p)
            var found: Bool?
            p.forEachDeviceSlot { s, _ in if s.id == slot { found = s.bypass } }
            #expect(found == value)
            try p.validate()
            let decoded = try CommandRegistry.decode(try JSONEncoder().encode(AnyCommand(inverse)))
            var undone = p
            let redo = try decoded.apply(to: &undone)
            #expect(undone == original)
            _ = try redo.apply(to: &undone)
            #expect(undone == p)
        }
        var p = original
        #expect(throws: DAWError.notFound(kind: "device slot", id: 999)) {
            try SetDeviceBypass(slotID: 999, bypass: true).apply(to: &p)
        }
        #expect(p == original)
    }

    @Test("PLUG-018: bypassed devices stay in the graph with a bypass slot; a bypassed instrument keeps its clip player")
    func graphKeepsBypassed() throws {
        let (p, au, vst3, eq, sampler, midi) = bypassProject()
        let catalog = ParamCatalog()
        var runtime = RuntimeIDs()
        var next: ParamID = 0
        for (node, count) in GraphDescriptionBuilder.paramRequirements(p, catalog: catalog).sorted(by: { $0.key < $1.key }) {
            runtime.params[node] = .init(first: next, count: count)
            next += count
        }
        let graph = GraphDescriptionBuilder.build(p, runtime: runtime)
        for slot in [au, vst3, eq, sampler] {
            let node = try #require(graph.nodes.first { $0.id == slot })
            #expect(node.bypassParam == runtime.paramID(GraphNodeID.bypass(of: slot), 0))
        }
        #expect(graph.nodes.contains { $0.id == GraphNodeID.source(of: midi) })
        #expect(graph.edges.contains { $0.from == GraphNodeID.source(of: midi) && $0.to == sampler && $0.kind == .midi })
        // Bypass is a param value, not structure.
        var toggled = p
        _ = try SetDeviceBypass(slotID: eq, bypass: false).apply(to: &toggled)
        _ = try SetDeviceBypass(slotID: sampler, bypass: false).apply(to: &toggled)
        #expect(GraphDescriptionBuilder.build(toggled, runtime: runtime) == graph)
        let values = GraphDescriptionBuilder.paramValues(p, runtime: runtime, catalog: catalog)
        #expect(values[runtime.paramID(GraphNodeID.bypass(of: eq), 0)!] == 1)
        #expect(values[runtime.paramID(GraphNodeID.bypass(of: au), 0)!] == 0)
    }

    @Test("MODEL-021, PLUG-018: SetDeviceBypass is a slot write, never applyGraph; undo writes it back")
    func toggleIsSlotWrite() throws {
        let (p, au, _, _, _, _) = bypassProject()
        let store = ProjectStore(project: p)
        let engine = FakeEngine()
        let sync = try store.attachEngine(engine, debounce: .zero)
        let before = applies(engine)
        #expect(bypassValue(sync, engine, au) == 0)
        try store.perform(SetDeviceBypass(slotID: au, bypass: true))
        #expect(bypassValue(sync, engine, au) == 1)
        #expect(store.undoLabel == "Bypass Device")
        store.undo()
        #expect(bypassValue(sync, engine, au) == 0)
        store.redo()
        #expect(bypassValue(sync, engine, au) == 1)
        #expect(applies(engine) == before)
    }
}

@Suite("Safe mode and the running marker (PLUG-021)")
@MainActor
struct SafeModeTests {
    private func bypassValue(_ sync: EngineSync, _ engine: FakeEngine, _ slot: ModelID) -> Float? {
        sync.runtime.paramID(GraphNodeID.bypass(of: slot), 0).map { engine.getParam($0) }
    }

    @Test("PLUG-021: safe mode host-bypasses every AU/VST3 slot as a session override; the document is untouched")
    func safeModeOverride() throws {
        let (p, au, vst3, eq, sampler, _) = bypassProject()
        let store = ProjectStore(project: p)
        let engine = FakeEngine()
        let sync = try store.attachEngine(engine, debounce: .zero)
        let applied = engine.appliedGraphs.count
        store.isSafeMode = true
        #expect(bypassValue(sync, engine, au) == 1 && bypassValue(sync, engine, vst3) == 1)
        #expect(bypassValue(sync, engine, eq) == 1 && bypassValue(sync, engine, sampler) == 1)  // their own bypass
        #expect(store.project == p && !store.isDirty && !store.canUndo)
        #expect(engine.appliedGraphs.count == applied)  // slot writes only
        // Built-ins follow the document in safe mode; plugins stay bypassed whatever it says.
        try store.perform(SetDeviceBypass(slotID: eq, bypass: false))
        try store.perform(SetDeviceBypass(slotID: au, bypass: false))
        #expect(bypassValue(sync, engine, eq) == 0 && bypassValue(sync, engine, au) == 1)
        store.isSafeMode = false
        #expect(bypassValue(sync, engine, au) == 0 && bypassValue(sync, engine, vst3) == 0)
    }

    @Test("PLUG-021: open(safeMode:) bypasses the plugins before the first graph; slots, params and state are kept")
    func openInSafeMode() async throws {
        let folder = try TempFolder("safe-mode")
        defer { folder.remove() }
        var (p, au, vst3, _, _, _) = bypassProject()
        p.tracks[0].inserts[0].params = [ParamValue(index: 0, value: 0.5)]
        p.tracks[0].inserts[0].pluginState = Data([1, 2, 3])
        let url = folder.url.appending(path: "Safe.dawproject")
        let saved = ProjectStore(project: p)
        saved.autosavePolicy = nil
        try await saved.save(to: url)

        let store = try await ProjectStore.open(url, recover: false, safeMode: true)
        store.autosavePolicy = nil
        #expect(store.isSafeMode)
        #expect(store.project.tracks[0].inserts[0].pluginState == Data([1, 2, 3]))
        #expect(store.project.tracks[0].inserts[0].params == [ParamValue(index: 0, value: 0.5)])
        #expect(!store.project.tracks[0].inserts[0].bypass && !store.isDirty)
        let engine = FakeEngine()
        let sync = try store.attachEngine(engine, debounce: .zero)
        let bypassIDs = Set([au, vst3].compactMap { sync.runtime.paramID(GraphNodeID.bypass(of: $0), 0) })
        #expect(bypassIDs.count == 2)
        // Every bypass slot holds 1 before the first applyGraph.
        var written: [ParamID: Float] = [:]
        for call in engine.calls {
            if case .setParam(let id, let value) = call { written[id] = value }
            if case .applyGraph = call { break }
        }
        #expect(bypassIDs.allSatisfy { written[$0] == 1 })
        // Nothing reached the document: saving gives back the same project.
        #expect(store.project == p)
        await store.close()
        let normal = try await ProjectStore.open(url, recover: false)
        #expect(!normal.isSafeMode)
        await normal.close()
    }

    @Test("PLUG-021: the running marker lists open projects and plugins, follows changes, and a clean end removes it")
    func runningMarker() async throws {
        let folder = try TempFolder("marker")
        defer { folder.remove() }
        let (p, au, vst3, _, _, _) = bypassProject()
        var open: [CrashMarker.OpenProject] = [CrashMarker.OpenProject(project: p, folder: URL(filePath: "/tmp/Bypass.dawproject"))]
        let session = CrashMarkerSession.start(directory: folder.url) { open }
        #expect(session.crashedSessions.isEmpty)
        let marker = try #require(CrashMarker.read(session.fileURL))
        #expect(marker.processID == ProcessInfo.processInfo.processIdentifier)
        #expect(marker.projects.count == 1 && marker.projects[0].name == "bypass" && marker.projects[0].path == "/tmp/Bypass.dawproject")
        #expect(marker.projects[0].plugins == [
            .init(slotID: au, format: "au", identifier: "aufx:dely:appl", name: "AUDelay"),
            .init(slotID: vst3, format: "vst3", identifier: "/x.vst3#00", name: "Again"),
        ])
        // This process is alive: its marker isn't a crashed session's.
        #expect(CrashMarker.leftByCrashedSessions(in: folder.url).isEmpty)

        open = []
        session.refresh()
        #expect(CrashMarker.read(session.fileURL)?.projects == [])
        session.end()
        #expect(!FileManager.default.fileExists(atPath: session.fileURL.path))
    }

    @Test("PLUG-021: a marker whose process is gone is a crashed session; the next start hands it over once")
    func crashedSession() throws {
        let folder = try TempFolder("crashed")
        defer { folder.remove() }
        // A pid that surely ended: a child that has exited.
        let child = Process()
        child.executableURL = URL(filePath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        let (p, au, _, _, _, _) = bypassProject()
        let left = CrashMarker(processID: child.processIdentifier, launched: Date(timeIntervalSince1970: 1_700_000_000),
                               projects: [CrashMarker.OpenProject(project: p, folder: nil)])
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try #require(left.encoded()).write(to: CrashMarker.fileURL(processID: left.processID, in: folder.url))

        #expect(CrashMarker.leftByCrashedSessions(in: folder.url) == [left])
        let session = CrashMarkerSession.start(directory: folder.url) { [] }
        #expect(session.crashedSessions == [left])
        #expect(session.crashedSessions.first?.projects.first?.plugins.first?.slotID == au)
        #expect(CrashMarker.leftByCrashedSessions(in: folder.url).isEmpty)  // handed over, not again
        session.end()
        #expect(CrashMarker.markerFiles(in: folder.url).isEmpty)
    }
}
