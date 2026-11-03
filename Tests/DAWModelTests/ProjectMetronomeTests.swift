import Foundation
import Testing

@testable import DAWModel

/// TIME-010 (project part) and DW-160, T-026: `Project.metronome`, `SetMetronome` (persisted, not
/// undoable), the metronome node GraphDescriptionBuilder wires into the master, and its slots.
@Suite("Project metronome (TIME-010, DW-160)")
@MainActor
struct ProjectMetronomeTests {
    init() { TestCommands.register() }

    private func attached(_ project: Project = Project()) throws -> (ProjectStore, FakeEngine, EngineSync) {
        let store = ProjectStore(project: project)
        let engine = FakeEngine()
        let sync = try store.attachEngine(engine, debounce: .zero)
        return (store, engine, sync)
    }

    private func applies(_ engine: FakeEngine) -> Int {
        engine.calls.filter { if case .applyGraph = $0 { true } else { false } }.count
    }

    /// The metronome's (on, level, accent) slots as the engine holds them.
    private func slots(_ engine: FakeEngine, _ sync: EngineSync, _ project: Project) throws -> [Float] {
        try [ParamLayout.Metronome.on, ParamLayout.Metronome.level, ParamLayout.Metronome.accent].map {
            engine.getParam(try #require(sync.runtime.metronomeParam(project.master.id, $0)))
        }
    }

    // MARK: Command

    @Test("TIME-010: SetMetronome sets the fields it is given and keeps the rest")
    func setFields() throws {
        var p = Project()
        #expect(p.metronome == MetronomeSettings(enabled: false, level: 0.25, accent: 2))
        let inverse = try SetMetronome(enabled: true).apply(to: &p)
        #expect(p.metronome == MetronomeSettings(enabled: true, level: 0.25, accent: 2))
        _ = try SetMetronome(level: 0.5, accent: 1).apply(to: &p)
        #expect(p.metronome == MetronomeSettings(enabled: true, level: 0.5, accent: 1))
        _ = try SetMetronome(level: MetronomeSettings.maxLevel, accent: 0).apply(to: &p)
        #expect(p.metronome.level == MetronomeSettings.maxLevel && p.metronome.accent == 0)
        // The inverse sets every field back (callers that apply it themselves; the store doesn't).
        let back = try #require(inverse as? SetMetronome)
        #expect(back.enabled == false && back.level == 0.25 && back.accent == 2)
    }

    @Test("TIME-010, MODEL-031: bad SetMetronome arguments throw and change nothing", arguments: [
        SetMetronome(),
        SetMetronome(level: -0.1),
        SetMetronome(level: 4),
        SetMetronome(level: .nan),
        SetMetronome(level: .infinity),
        SetMetronome(enabled: true, accent: -1),
        SetMetronome(accent: .nan),
        SetMetronome(enabled: true, level: 0.5, accent: 10),
    ])
    func rejects(_ command: SetMetronome) throws {
        let store = ProjectStore()
        let before = store.project
        #expect(throws: DAWError.self) { try store.perform(command) }
        #expect(store.project == before && !store.isDirty)
    }

    @Test("TIME-010, MODEL-006: SetMetronome's wire form; fields left out decode as nil")
    func wireForm() throws {
        let data = try CommandRegistry.encode(SetMetronome(enabled: true, level: 0.5))
        #expect(String(decoding: data, as: UTF8.self) == #"{"enabled":true,"level":0.5,"type":"SetMetronome"}"#)
        let decoded = try #require(try CommandRegistry.decode(Data(#"{"type":"SetMetronome","accent":1.5}"#.utf8)) as? SetMetronome)
        #expect(decoded.enabled == nil && decoded.level == nil && decoded.accent == 1.5)
    }

    // MARK: History (07, DECISIONS.md T-026 Q2)

    @Test("TIME-010: SetMetronome marks the project dirty but never enters undo history")
    func notUndoable() async throws {
        let store = ProjectStore()
        try store.perform(TestAddTrack(name: "A"))
        let track = store.project.tracks[0].id
        try store.perform(RenameTrack(trackID: track, name: "B"))
        store.undo()  // a redo entry waits
        store.markClean()
        #expect(!store.isDirty && store.canRedo && store.undoLabel == "Add Track")

        var changes = store.changeStream().makeAsyncIterator()
        try store.perform(SetMetronome(enabled: true))
        let change = await changes.next()
        #expect(change?.cause == .perform && change?.changedFields == [.metronome] && change?.changedIDs.isEmpty == true)
        #expect(store.isDirty, "a metronome change is a document change")
        #expect(store.undoLabel == "Add Track", "no undo entry")
        #expect(store.canRedo && store.redoLabel == "Rename Track", "the redo stack survives")

        // Undo and redo step over it: the click stays on.
        store.redo()
        #expect(store.project.tracks[0].name == "B" && store.project.metronome.enabled)
        store.undo()
        store.undo()
        #expect(store.project.tracks.isEmpty && store.project.metronome.enabled)
        #expect(store.isDirty, "undo can't take it back, so the project stays dirty until saved")
    }

    @Test("TIME-010: inside a gesture SetMetronome is applied but not part of the gesture's entry")
    func gesture() throws {
        let store = ProjectStore()
        try store.perform(TestAddTrack(name: "A"))
        let track = store.project.tracks[0].id
        store.beginGesture("Fader")
        try store.perform(TestSetGain(trackID: track, gain: 0.5))
        try store.perform(SetMetronome(enabled: true, level: 1))
        try store.perform(TestSetGain(trackID: track, gain: 0.25))
        store.endGesture()
        #expect(store.undoLabel == "Fader")
        store.undo()
        #expect(store.project.tracks[0].strip.gain == 1)
        #expect(store.project.metronome == MetronomeSettings(enabled: true, level: 1))
    }

    @Test("TIME-010: a composite edit can't carry SetMetronome into history")
    func notInComposite() throws {
        let store = ProjectStore()
        let composite = CompositeCommand("Batch", [TestAddTrack(name: "A"), SetMetronome(enabled: true)])
        #expect(throws: DAWError.self) { try store.perform(composite) }
        #expect(store.project.tracks.isEmpty && !store.project.metronome.enabled && !store.canUndo)
    }

    // MARK: Persistence

    @Test("TIME-010, MODEL-040: the metronome is saved and opened; save makes the change clean")
    func persisted() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "metronome-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ProjectStore()
        store.autosavePolicy = nil
        try store.perform(SetMetronome(enabled: true, level: 0.5, accent: 1.5))
        #expect(store.isDirty)
        try await store.save(to: folder)
        #expect(!store.isDirty)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "project.json"))) as? [String: Any]
        let saved = try #require(json?["metronome"] as? [String: Any])
        #expect(saved["enabled"] as? Bool == true && saved["level"] as? Double == 0.5 && saved["accent"] as? Double == 1.5)

        let opened = try await ProjectStore.open(folder, recover: false)
        opened.autosavePolicy = nil
        #expect(opened.project.metronome == MetronomeSettings(enabled: true, level: 0.5, accent: 1.5))
        #expect(opened.project == store.project && !opened.isDirty)
    }

    @Test("TIME-010, MODEL-042: a file without the metronome key opens with it off at default levels")
    func oldFiles() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Project())) as? [String: Any])
        json["metronome"] = nil
        let old = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.metronome == MetronomeSettings())
        #expect(old.formatVersion == Project.currentFormatVersion)

        json["metronome"] = ["enabled": true]  // partial, hand-written
        let partial = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(partial.metronome == MetronomeSettings(enabled: true))

        json["metronome"] = ["enabled": true, "level": 9]
        let bad = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(throws: DAWError.self, "MODEL-032 checks the levels") { try bad.validate() }
    }

    // MARK: Graph and slots (MODEL-020/021)

    @Test("TIME-010: one metronome node, wired straight into the master node, whatever the project")
    func graph() throws {
        for project in [Project(), GraphFixtures.routing(), try GraphFixtures.midiTempo()] {
            let graph = GraphDescriptionBuilder.build(project, runtime: .sequential(for: project))
            let id = GraphNodeID.metronome(of: project.master.id)
            #expect(graph.nodes.filter { $0.kind == .metronome }.map(\.id) == [id])
            #expect(graph.nodes.first { $0.id == id }?.numParams == ParamLayout.Metronome.count)
            #expect(graph.edges.filter { $0.from == id }.map(\.to) == [graph.master], "past master inserts and fader")
            #expect(!graph.edges.contains { $0.to == id }, "nothing feeds it")
            #expect(GraphNodeID.owner(of: id) == project.master.id && GraphNodeID.role(of: id) == .metronome)
        }
    }

    @Test("TIME-010, MODEL-021: switching and levels are slot writes, never a rebuild")
    func slotWrites() throws {
        var routed = GraphFixtures.routing()
        routed.tracks[0].strip.solo = true  // MIX-006 solo and mute don't reach the click
        routed.tracks[1].strip.mute = true
        let (store, engine, sync) = try attached(routed)
        #expect(try slots(engine, sync, store.project) == [0, 0.25, 2], "off at attach, default levels")
        engine.clearCalls()

        try store.perform(SetMetronome(enabled: true))
        #expect(try slots(engine, sync, store.project) == [1, 0.25, 2])
        try store.perform(SetMetronome(level: 0.5, accent: 1.5))
        #expect(try slots(engine, sync, store.project) == [1, 0.5, 1.5])
        try store.perform(SetMetronome(enabled: false))
        #expect(try slots(engine, sync, store.project) == [0, 0.5, 1.5])
        #expect(applies(engine) == 0 && !sync.hasPendingApply)
        let writes = engine.calls.filter { if case .setParam = $0 { true } else { false } }
        #expect(writes.count == 4, "only the slots that changed")
    }

    @Test("TIME-010 (DECISIONS.md T-026 Q1): an export suppresses the click through the on slot only")
    func suppression() throws {
        let (store, engine, sync) = try attached()
        try store.perform(SetMetronome(enabled: true))
        engine.clearCalls()
        let on = try #require(sync.runtime.metronomeParam(store.project.master.id, ParamLayout.Metronome.on))

        sync.isMetronomeSuppressed = true
        #expect(engine.getParam(on) == 0)
        try store.perform(SetMetronome(enabled: true, level: 1))  // an edit during the export
        #expect(engine.getParam(on) == 0, "stays off while suppressed")
        sync.isMetronomeSuppressed = false
        #expect(try slots(engine, sync, store.project) == [1, 1, 2], "follows the project again")
        #expect(applies(engine) == 0)

        // Suppressing a metronome that is off writes nothing.
        try store.perform(SetMetronome(enabled: false))
        engine.clearCalls()
        sync.isMetronomeSuppressed = true
        sync.isMetronomeSuppressed = false
        #expect(engine.calls.isEmpty)
    }

    @Test("DW-160: the engine publishes Metronome's slots, and the model's layout and defaults match")
    func engineParamInfo() throws {
        struct Info: Decodable { var index: UInt32; var id: String; var min: Float; var max: Float; var `default`: Float }
        let engine = try EngineClient(.offline())
        let infos = try JSONDecoder().decode([Info].self, from: Data(engine.paramInfoJSON(.metronome).utf8))
        #expect(infos.map(\.id) == ["on", "level", "accent"])
        #expect(infos.map(\.index) == [ParamLayout.Metronome.on, ParamLayout.Metronome.level, ParamLayout.Metronome.accent])
        #expect(UInt32(infos.count) == ParamLayout.Metronome.count)
        let defaults = MetronomeSettings()
        #expect(infos[1].default == defaults.level && infos[2].default == defaults.accent)
        #expect(abs(infos[1].max - MetronomeSettings.maxLevel) < 1e-5 && abs(infos[2].max - MetronomeSettings.maxLevel) < 1e-5)

        // GainNode (sends, MIX-007): level then mute, as ParamLayout.Send.
        let gain = try JSONDecoder().decode([Info].self, from: Data(engine.paramInfoJSON(.gain).utf8))
        #expect(gain.map(\.id) == ["level", "mute"])
        #expect(gain.map(\.index) == [ParamLayout.Send.level, ParamLayout.Send.mute])
    }

    /// `routing` is left out: its EQ, compressor and delay have no engine nodes yet (06).
    @Test("TIME-010: the real engine builds fixture graphs with the metronome node in them")
    func realEngineAcceptsGraph() async throws {
        for project in [Project(), GraphFixtures.audioTracks(), try GraphFixtures.midiTempo()] {
            let engine = try EngineClient(.offline())
            let store = ProjectStore(project: project)
            let sync = try store.attachEngine(engine, debounce: .zero)
            try store.perform(SetMetronome(enabled: true))
            let version = engine.graphStatus().submittedVersion
            let status = engine.waitForGraph(version, timeout: .seconds(10))
            #expect(status.completedVersion >= version && status.lastError == nil, "\(project.name): \(String(describing: status.lastError))")
            #expect(sync.lastError == nil)
            #expect(engine.telemetry().rtViolations == 0)
            store.detachEngine()
        }
    }
}
