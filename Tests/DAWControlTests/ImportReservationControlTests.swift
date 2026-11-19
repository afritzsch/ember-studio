import DAWControl
import DAWModel
import Foundation
import Testing

// T-112: the Dispatcher's share of DW-339 (asset.import reserves its asset ID before the engine
// load it awaits) and DW-336 (commands it performs are `.control`'s, so in attach mode they never
// join a gesture the app has open).

/// Opened by the test once it has acted inside the load's await.
private final class LoadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var started = false
    func open() { lock.withLock { isOpen = true } }
    var opened: Bool { lock.withLock { isOpen } }
    func markStarted() { lock.withLock { started = true } }
    var loadStarted: Bool { lock.withLock { started } }
}

/// FakeEngine whose asset loads of `slowPath` stay running until the gate opens (FakeEngine itself
/// finishes every job at once), so `asset.import` really waits across an `await`.
private final class SlowLoadEngine: EngineProtocol, @unchecked Sendable {
    let base: FakeEngine
    let slowPath: String
    let gate: LoadGate
    private let lock = NSLock()
    private var slowJobs: Set<JobID> = []

    init(base: FakeEngine, slowPath: String, gate: LoadGate) {
        self.base = base
        self.slowPath = slowPath
        self.gate = gate
    }

    var mode: EngineMode { base.mode }
    func applyGraph(_ graph: EngineGraph) -> UInt64 { base.applyGraph(graph) }
    func graphStatus() -> GraphStatus { base.graphStatus() }
    func waitForGraph(_ version: UInt64, timeout: Duration) -> GraphStatus { base.waitForGraph(version, timeout: timeout) }
    func allocateParams(_ count: UInt32) throws(DAWError) -> ParamID { try base.allocateParams(count) }
    func freeParams(_ first: ParamID, count: UInt32) { base.freeParams(first, count: count) }
    func setParam(_ id: ParamID, _ value: Float) { base.setParam(id, value) }
    func getParam(_ id: ParamID) -> Float { base.getParam(id) }
    func play() { base.play() }
    func stop() { base.stop() }
    func locate(_ tick: Tick) { base.locate(tick) }
    func setLoop(enabled: Bool, start: Tick, end: Tick) { base.setLoop(enabled: enabled, start: start, end: end) }
    func setRecording(_ recording: Bool) { base.setRecording(recording) }
    func transport() -> TransportState { base.transport() }
    func armInput(track: NodeIDValue, inputChannelPair: UInt32, armed: Bool) {
        base.armInput(track: track, inputChannelPair: inputChannelPair, armed: armed)
    }
    func instantiatePlugin(slot: NodeIDValue, _ plugin: PluginDescriptor) -> JobID { base.instantiatePlugin(slot: slot, plugin) }
    func pluginState(slot: NodeIDValue) -> Data { base.pluginState(slot: slot) }
    func setPluginState(slot: NodeIDValue, _ state: Data) { base.setPluginState(slot: slot, state) }
    func devices() -> [AudioDeviceInfo] { base.devices() }
    func setDevice(_ config: DriverConfig) throws(DAWError) { try base.setDevice(config) }
    func simulateDeviceEvent(_ event: DeviceEvent) throws(DAWError) { try base.simulateDeviceEvent(event) }
    func telemetry() -> EngineTelemetry { base.telemetry() }
    func nodeLatencies() -> [NodeLatency] { base.nodeLatencies() }
    func meter(_ node: NodeIDValue) -> MeterReading? { base.meter(node) }
    func pollEvents(max: Int) -> [EngineEvent] { base.pollEvents(max: max) }
    func paramInfoJSON(_ kind: NodeKind) -> String { base.paramInfoJSON(kind) }
    func renderOffline(from: Tick, to: Tick, spec: ExportSpec) -> JobID { base.renderOffline(from: from, to: to, spec: spec) }

    func loadAsset(_ assetID: ModelID, path: String) -> JobID {
        let job = base.loadAsset(assetID, path: path)
        if path == slowPath {
            lock.withLock { _ = slowJobs.insert(job) }
            gate.markStarted()
        }
        return job
    }

    func pollJob(_ job: JobID) -> EngineJobStatus {
        let status = base.pollJob(job)
        guard lock.withLock({ slowJobs.contains(job) }), !gate.opened else { return status }
        var running = status
        running.state = .running
        running.progress = 0.5
        return running
    }

    /// The loads the engine was asked for, in order.
    var loadedIDs: [ModelID] {
        base.calls.compactMap { if case .loadAsset(let id, _) = $0 { id } else { nil } }
    }
}

@MainActor
private final class SlowEngineBox {
    var engine: SlowLoadEngine?
}

@Suite("asset.import ID reservation and control gesture owner (T-112: DW-339, DW-336)")
@MainActor
struct ImportReservationControlTests {
    private func dispatcher(_ dir: TempDir, slowPath: String, gate: LoadGate, mode: Dispatcher.Mode = .headless)
        -> (Dispatcher, SlowEngineBox)
    {
        let box = SlowEngineBox()
        let config = Dispatcher.Configuration(
            mode: mode,
            makeEngine: { rate throws(DAWError) in
                let engine = SlowLoadEngine(base: FakeEngine(mode: .offline(sampleRate: rate)), slowPath: slowPath, gate: gate)
                box.engine = engine
                return engine
            },
            workingDirectory: dir.url, jobTimeout: .seconds(20), graphTimeout: .seconds(5))
        return (Dispatcher(configuration: config), box)
    }

    @Test("DW-339: a recording import and an asset.import interleaved across the load's await get distinct asset IDs",
          .timeLimit(.minutes(1)))
    func interleavedImports() async throws {
        let dir = try TempDir()
        try TestAudio.write([[0, 0.5, 0]], sampleRate: 48_000, to: dir.file("a.wav"))
        try TestAudio.write([[0, 0.25, 0]], sampleRate: 48_000, to: dir.file("take.caf"))  // the recorder's file
        let gate = LoadGate()
        let (dispatcher, engine) = dispatcher(dir, slowPath: dir.file("a.wav").path, gate: gate)
        _ = try await dispatcher.ok(.projectNew, ["name": "p"])
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "Mic", "kind": "audio"]])
        let store = try #require(dispatcher.store)
        let mic = store.project.tracks[0].id

        let importing = Task { try await dispatcher.ok(.assetImport, ["path": "a.wav"]) }
        while !gate.loadStarted { await Task.yield() }  // asset.import is awaiting its load
        // A take finishes meanwhile (on the main actor, as EngineSync delivers it).
        let take = RecordedTake(track: mic, file: dir.file("take.caf").path, startSample: 0, frames: 48_000, sampleRate: 48_000)
        let recorded = try #require(try store.importRecording(take))
        gate.open()
        let result = try await importing.value
        let imported = try #require(result["assetID"]?.int64Value.map { ModelID($0) })

        #expect(imported != recorded)
        #expect(Set(store.project.assets.map(\.id)) == [imported, recorded])
        #expect(store.project.assets.first { $0.id == imported }?.path == dir.file("a.wav").path)
        #expect(store.project.assets.first { $0.id == recorded }?.path == dir.file("take.caf").path)
        let loads = try #require(engine.engine).loadedIDs
        #expect(Set(loads) == [imported, recorded] && loads.count == 2, "one engine asset per import: \(loads)")
        try store.project.validate()
    }

    @Test("DW-336: in attach mode a command.apply during the app's \"Set Gain\" drag is its own undo entry and survives one undo")
    func controlCommandDuringUIGesture() async throws {
        let (dispatcher, _) = TestDispatchers.fake(mode: .attach)
        _ = try await dispatcher.ok(.projectNew, ["name": "p"])
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "T", "kind": "audio"]])
        let store = try #require(dispatcher.store)
        let track = store.project.tracks[0].id
        store.beginGesture("Set Gain")
        try store.perform(SetParam(target: .strip(channel: track, param: .gain), value: 0.5))
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "MCP", "kind": "audio"]])
        _ = try await dispatcher.ok(.commandBatch, ["commands": [["type": "AddBus", "name": "Bus"]], "atomic": true])
        #expect(store.hasOpenGesture(owner: .ui), "the control's commands don't end the app's gesture")
        try store.perform(SetParam(target: .strip(channel: track, param: .gain), value: 0.25))
        store.endGesture()
        #expect(store.undoLabel == "Set Gain")
        store.undo()
        #expect(store.project.tracks[0].strip.gain == 1)
        #expect(store.project.tracks.map(\.name) == ["T", "MCP"] && store.project.buses.count == 1)
        #expect(store.undoLabel == "Add Bus")
    }
}
