import DAWControl
import DAWModel
import Foundation
import Testing

// CTL-031: long requests report progress while they run, in-process and over the socket.

/// FakeEngine whose offline renders take `duration` and report progress by elapsed time (FakeEngine
/// itself finishes every job at once).
private final class SlowRenderEngine: EngineProtocol, @unchecked Sendable {
    let base: FakeEngine
    let duration: Duration
    private let lock = NSLock()
    private var started: [JobID: ContinuousClock.Instant] = [:]

    init(base: FakeEngine, duration: Duration) {
        self.base = base
        self.duration = duration
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
    func loadAsset(_ assetID: ModelID, path: String) -> JobID { base.loadAsset(assetID, path: path) }
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

    func renderOffline(from: Tick, to: Tick, spec: ExportSpec) -> JobID {
        let job = base.renderOffline(from: from, to: to, spec: spec)
        lock.withLock { started[job] = .now }
        return job
    }

    func pollJob(_ job: JobID) -> EngineJobStatus {
        let status = base.pollJob(job)
        guard let start = lock.withLock({ started[job] }) else { return status }
        let fraction = (ContinuousClock.now - start) / duration
        guard fraction < 1 else { return status }
        var running = status
        running.state = .running
        running.progress = fraction
        return running
    }
}

@MainActor
private func slowDispatcher(_ duration: Duration) -> Dispatcher {
    Dispatcher(configuration: .init(
        makeEngine: { rate throws(DAWError) in SlowRenderEngine(base: FakeEngine(mode: .offline(sampleRate: rate)), duration: duration) },
        workingDirectory: FileManager.default.temporaryDirectory, jobTimeout: .seconds(10), graphTimeout: .seconds(5)))
}

@Suite("Progress (CTL-031)")
@MainActor
struct ProgressTests {
    @Test("CTL-031: render.offline reports progress in rising steps of ≥ 1 % at most every 50 ms, ending at 1")
    func inProcess() async throws {
        let dispatcher = slowDispatcher(.milliseconds(400))
        _ = try await dispatcher.ok(.projectNew, ["name": "p"])
        var updates: [(ContinuousClock.Instant, ControlProgress)] = []
        let path = FileManager.default.temporaryDirectory.appending(path: "progress-\(UUID().uuidString).wav").path
        _ = try await dispatcher.call(.renderOffline, ["from": 0, "to": 960, "path": .string(path)]) { updates.append((.now, $0)) }
        let values = updates.map(\.1.progress)
        #expect(updates.allSatisfy { $0.1.method == "render.offline" })
        #expect(values.count >= 3, "intermediate steps: \(values)")
        #expect(values.last == 1)
        #expect(zip(values, values.dropFirst()).allSatisfy { $1 >= $0 + 0.01 }, "\(values)")
        let gaps = zip(updates, updates.dropFirst()).dropLast().map { $1.0 - $0.0 }
        #expect(gaps.allSatisfy { $0 >= .milliseconds(45) }, "\(gaps)")
        #expect(values.count <= 12, "≤ one every 50 ms of a 400 ms job: \(values)")

        // Without a handler nothing is reported and the call still waits for the job.
        let plain = try await dispatcher.call(.renderOffline, ["from": 0, "to": 960, "path": .string(path)])
        #expect(plain["path"]?.stringValue == path)
    }

    @Test("CTL-031: over the socket, progress arrives as `progress` notifications before the response; none for notifications")
    func overSocket() async throws {
        let dispatcher = slowDispatcher(.milliseconds(300))
        let path = ControlSocketPath.forProcess(Int32.random(in: 1_000_000...Int32.max))
        let server = ControlSocketServer(path: path, dispatcher: dispatcher)
        try server.start()
        defer { server.stop() }
        let client = try ControlSocketClient(path: path)
        defer { client.close() }
        _ = try await client.call(.projectNew, ["name": "p"])

        let collected = Collected<ControlProgress>()
        let out = FileManager.default.temporaryDirectory.appending(path: "progress-\(UUID().uuidString).wav").path
        let result = try await client.call(.renderOffline, ["from": 0, "to": 960, "path": .string(out)]) { collected.add($0) }
        #expect(result["path"]?.stringValue == out)
        let values = collected.values.map(\.progress)
        #expect(values.count >= 2 && values.last == 1, "\(values)")
        #expect(collected.values.allSatisfy { $0.method == "render.offline" })

        // The raw notification shape (13 Protocol details).
        let notifications = Collected<RPCRequest>()
        let response = try await client.send(RPCRequest(42, .renderOffline, ["from": 0, "to": 960, "path": .string(out)])) {
            notifications.add($0)
        }
        #expect(response?.id == .int(42) && response?.error == nil)
        let first = try #require(notifications.values.first)
        #expect(first.id == nil && first.method == "progress")
        #expect(first.params?["id"] == 42 && first.params?["method"] == "render.offline")
        #expect(first.params?["progress"]?.doubleValue != nil)
    }
}

private final class Collected<Item: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Item] = []
    func add(_ item: Item) { lock.withLock { items.append(item) } }
    var values: [Item] { lock.withLock { items } }
}
