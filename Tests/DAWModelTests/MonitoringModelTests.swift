import Foundation
import Testing

@testable import DAWModel

// T-054 model side (REC-020..022): the monitoring mode reaches the engine as a slot write (no
// graph applied), arming and the input pair as a new graph, and `on` monitoring switches the
// device input on without an arm.

@Suite("Input monitoring, model side (REC-020..022)")
@MainActor
struct MonitoringModelTests {
    init() { TestCommands.register() }

    /// An audio track "Mic" and a MIDI track "Keys" (default monitoring: auto).
    private func project() -> Project {
        var p = Project(id: GraphFixtures.fixedID, name: "mon")
        p.tracks = [
            Track(id: p.ids.allocate(), name: "Mic", kind: .audio),
            Track(id: p.ids.allocate(), name: "Keys", kind: .midi),
        ]
        return p
    }

    private func attached(_ project: Project) throws -> (ProjectStore, FakeEngine, EngineSync) {
        let store = ProjectStore(project: project)
        let engine = FakeEngine()
        let sync = try store.attachEngine(engine, debounce: .zero)
        return (store, engine, sync)
    }

    private func applies(_ engine: FakeEngine) -> Int {
        engine.calls.filter { if case .applyGraph = $0 { true } else { false } }.count
    }

    private func monitorInputs(_ engine: FakeEngine) -> [Bool] {
        engine.calls.compactMap { if case .setMonitorInput(let on) = $0 { on } else { nil } }
    }

    @Test("REC-022: SetMonitoring is a slot write (no graph applied); ArmTrack and the input pair are structural")
    func modeIsASlotArmIsStructural() throws {
        let (store, engine, sync) = try attached(project())
        let mic = store.project.tracks[0]
        let graph = try #require(sync.appliedGraph)
        let monitor = try #require(graph.monitors.first { $0.player == GraphNodeID.source(of: mic.id) })
        #expect(graph.monitors.count == 1, "the MIDI track has none")
        #expect(!monitor.armed && monitor.inputPair == 0)
        #expect(engine.getParam(monitor.modeSlot) == 2, "auto, the default")

        // SetMonitoring: the slot changes, no graph is applied, the graph version stays.
        let before = applies(engine)
        let version = engine.graphStatus().publishedVersion
        for (mode, value) in [(Track.Monitoring.on, Float(1)), (.off, 0), (.auto, 2)] {
            try store.perform(SetMonitoring(trackID: mic.id, mode: mode))
            #expect(engine.getParam(monitor.modeSlot) == value)
            #expect(engine.calls.contains(.setParam(monitor.modeSlot, value)))
        }
        #expect(applies(engine) == before && engine.graphStatus().publishedVersion == version)
        #expect(!sync.hasPendingApply)

        // ArmTrack: a new graph with the arm (and armInput, T-052).
        try store.perform(ArmTrack(trackID: mic.id, armed: true))
        #expect(applies(engine) == before + 1)
        #expect(sync.appliedGraph?.monitors.first?.armed == true)
        #expect(engine.graphStatus().publishedVersion > version)
        // A new input pair too.
        try store.perform(ArmTrack(trackID: mic.id, armed: true, inputPair: 2))
        #expect(applies(engine) == before + 2)
        #expect(sync.appliedGraph?.monitors.first?.inputPair == 2)
        #expect(sync.appliedGraph?.monitors.first?.modeSlot == monitor.modeSlot, "the slot is kept")
    }

    @Test("REC-020: `on` monitoring switches the device input on without an arm (setMonitorInput); auto and off don't")
    func onMonitoringWantsInput() throws {
        let (store, engine, sync) = try attached(project())
        let mic = store.project.tracks[0].id
        let keys = store.project.tracks[1].id
        #expect(monitorInputs(engine).isEmpty, "auto needs no input until armed")
        try store.perform(SetMonitoring(trackID: mic, mode: .on))
        #expect(monitorInputs(engine) == [true] && engine.telemetry().monitorInput)
        try store.perform(SetMonitoring(trackID: keys, mode: .on))  // MIDI: doesn't count
        try store.perform(SetMonitoring(trackID: mic, mode: .auto))
        #expect(monitorInputs(engine) == [true, false])
        try store.perform(SetMonitoring(trackID: mic, mode: .on))
        sync.invalidate()  // a detached sync leaves no input running for itself
        #expect(monitorInputs(engine) == [true, false, true, false])
    }

    @Test("REC-020..022: the monitors cross the bridge and the real engine accepts them; SetMonitoring publishes no new graph")
    func realEngineAcceptsMonitors() async throws {
        let engine = try EngineClient(.realtime(DriverConfig(sampleRate: 48_000, driver: .fake)))
        let store = ProjectStore(project: project())
        let sync = try store.attachEngine(engine, debounce: .zero)
        let mic = store.project.tracks[0].id
        let applied = engine.waitForGraph(engine.graphStatus().submittedVersion, timeout: .seconds(5))
        #expect(applied.lastError == nil && applied.publishedVersion == applied.submittedVersion)
        try store.perform(SetMonitoring(trackID: mic, mode: .on))
        #expect(engine.graphStatus().submittedVersion == applied.submittedVersion, "a slot write, no graph")
        #expect(engine.telemetry().monitorInput)
        try store.perform(ArmTrack(trackID: mic, armed: true, inputPair: 1))
        let rearmed = engine.waitForGraph(engine.graphStatus().submittedVersion, timeout: .seconds(5))
        #expect(rearmed.submittedVersion > applied.submittedVersion && rearmed.lastError == nil)
        #expect(rearmed.publishedVersion == rearmed.submittedVersion)
        sync.invalidate()
        #expect(!engine.telemetry().monitorInput && engine.telemetry().rtViolations == 0)
    }

    @Test("REC-020: a project opened with `on` monitoring asks for input at attach")
    func onAtAttach() throws {
        var p = project()
        p.tracks[0].monitoring = .on
        let (_, engine, sync) = try attached(p)
        #expect(monitorInputs(engine) == [true])
        let slot = try #require(sync.appliedGraph?.monitors.first?.modeSlot)
        #expect(engine.getParam(slot) == 1)
    }
}
