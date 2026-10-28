import Foundation
import Synchronization

/// BRIDGE-007: an in-memory `EngineProtocol` for model, control and UI tests. It renders nothing,
/// and does what the real engine promises synchronously:
///   - `applyGraph` records the graph and publishes it at once (unless `rejectNextGraph` is set);
///   - params live in a dictionary, transport commands apply immediately;
///   - `loadAsset` succeeds at once with `assetInfo(for:)` (or fails if the path is in
///     `failingAssetPaths`) and queues the same events the engine would;
///   - `renderOffline` succeeds at once with an empty result.
/// `calls` logs every mutating call in order, so tests can assert e.g. that a param change
/// didn't apply a graph (MODEL-021).
public final class FakeEngine: EngineProtocol {
    public enum Call: Hashable, Sendable {
        case applyGraph(version: UInt64)
        case allocateParams(count: UInt32, first: ParamID)
        case freeParams(first: ParamID, count: UInt32)
        case setParam(ParamID, Float)
        case play, stop
        case locate(Tick)
        case setLoop(enabled: Bool, start: Tick, end: Tick)
        case setRecording(Bool)
        case loadAsset(ModelID, path: String)
        case renderOffline(from: Tick, to: Tick, path: String)
        case armInput(track: NodeIDValue, pair: UInt32, armed: Bool)
        case instantiatePlugin(slot: NodeIDValue)
        case setPluginState(slot: NodeIDValue)
        case setDevice(DriverConfig)
    }

    private struct State {
        var calls: [Call] = []
        var graphs: [EngineGraph] = []
        var status = GraphStatus()
        var rejectNextGraph: DAWError?
        var params: [ParamID: Float] = [:]
        var nextParam: ParamID = 0
        var transport = TransportState()
        var jobs: [JobID: EngineJobStatus] = [:]
        var nextJob: JobID = 1
        var events: [EngineEvent] = []
        var failingAssetPaths: Set<String> = []
        var pluginStates: [NodeIDValue: Data] = [:]
        var telemetry = EngineTelemetry()
    }

    private let state = Mutex(State())
    public let mode: EngineMode

    public init(mode: EngineMode = .offline()) {
        self.mode = mode
        let rate: Double = switch mode {
        case .offline(let sampleRate): sampleRate
        case .realtime(let config): config.sampleRate
        }
        state.withLock { $0.telemetry.sampleRate = rate }
    }

    // MARK: Test hooks

    public var calls: [Call] { state.withLock { $0.calls } }
    /// Every graph passed to `applyGraph`, in order.
    public var appliedGraphs: [EngineGraph] { state.withLock { $0.graphs } }
    public func clearCalls() { state.withLock { $0.calls.removeAll() } }
    /// The next `applyGraph` is rejected with `error` (e.g. `.routingCycle`), as a build failure.
    public func rejectNextGraph(with error: DAWError) { state.withLock { $0.rejectNextGraph = error } }
    public func failLoads(of path: String) { _ = state.withLock { $0.failingAssetPaths.insert(path) } }
    public func post(_ event: EngineEvent) { state.withLock { $0.events.append(event) } }

    // MARK: Graph & params

    @discardableResult
    public func applyGraph(_ graph: EngineGraph) -> UInt64 {
        state.withLock { s in
            let version = s.status.submittedVersion + 1
            s.calls.append(.applyGraph(version: version))
            s.graphs.append(graph)
            s.status.submittedVersion = version
            s.status.completedVersion = version
            if let error = s.rejectNextGraph {
                s.rejectNextGraph = nil
                s.status.lastError = error
                s.events.append(EngineEvent(kind: .graphRejected, subject: version, error: error))
            } else {
                s.status.lastError = nil
                s.status.publishedVersion = version
                s.telemetry.graphVersion = version
            }
            return version
        }
    }

    public func graphStatus() -> GraphStatus { state.withLock { $0.status } }
    @discardableResult
    public func waitForGraph(_ version: UInt64, timeout: Duration) -> GraphStatus { graphStatus() }

    public func allocateParams(_ count: UInt32) throws(DAWError) -> ParamID {
        guard count > 0 else { throw .invalidArgument("engine: param count 0") }
        return state.withLock { s in
            let first = s.nextParam
            s.nextParam += count
            for id in first..<(first + count) { s.params[id] = 0 }
            s.telemetry.paramsAllocated += count
            s.calls.append(.allocateParams(count: count, first: first))
            return first
        }
    }

    public func freeParams(_ first: ParamID, count: UInt32) {
        state.withLock { s in
            s.calls.append(.freeParams(first: first, count: count))
            for id in first..<(first &+ count) where s.params.removeValue(forKey: id) != nil {
                s.telemetry.paramsAllocated -= 1
            }
        }
    }

    public func setParam(_ id: ParamID, _ value: Float) {
        state.withLock { s in
            s.calls.append(.setParam(id, value))
            s.params[id] = value
        }
    }

    public func getParam(_ id: ParamID) -> Float { state.withLock { $0.params[id] ?? 0 } }

    // MARK: Transport

    public func play() { state.withLock { $0.calls.append(.play); $0.transport.playing = true } }
    public func stop() { state.withLock { $0.calls.append(.stop); $0.transport.playing = false } }

    public func locate(_ tick: Tick) {
        state.withLock { s in
            s.calls.append(.locate(tick))
            s.transport.tick = tick
        }
    }

    public func setLoop(enabled: Bool, start: Tick, end: Tick) {
        state.withLock { s in
            s.calls.append(.setLoop(enabled: enabled, start: start, end: end))
            if enabled && start >= end { return }  // the engine rejects it too (TIME-004)
            s.transport.loopEnabled = enabled
            s.transport.loopStart = start
            s.transport.loopEnd = end
        }
    }

    public func setRecording(_ recording: Bool) {
        state.withLock { s in
            s.calls.append(.setRecording(recording))
            s.transport.recording = recording
        }
    }

    public func transport() -> TransportState { state.withLock { $0.transport } }

    // MARK: Assets & jobs

    /// What a successful load reports: a stereo second at the session rate.
    public func assetInfo(for assetID: ModelID) -> LoadedAssetInfo {
        let rate = state.withLock { $0.telemetry.sampleRate }
        return LoadedAssetInfo(assetID: assetID, channels: 2, frames: Int64(rate), sampleRate: rate,
                               fileSampleRate: rate, fileFrames: Int64(rate), resampled: false)
    }

    public func loadAsset(_ assetID: ModelID, path: String) -> JobID {
        guard !path.isEmpty else { return 0 }
        let info = assetInfo(for: assetID)
        return state.withLock { s in
            s.calls.append(.loadAsset(assetID, path: path))
            let job = s.nextJob
            s.nextJob += 1
            if s.failingAssetPaths.contains(path) {
                let error = DAWError.engine(code: .io, detail: "cannot open \(path)")
                s.jobs[job] = EngineJobStatus(job: job, kind: .loadAsset, state: .failed, error: error)
                s.events.append(EngineEvent(kind: .jobFinished, subject: 1, job: job, error: error))
                s.events.append(EngineEvent(kind: .assetLoadFailed, subject: assetID, job: job, error: error))
            } else {
                s.jobs[job] = EngineJobStatus(job: job, kind: .loadAsset, state: .succeeded, progress: 1, asset: info)
                s.telemetry.assetsLoaded += 1
                s.events.append(EngineEvent(kind: .jobFinished, subject: 1, job: job))
                s.events.append(EngineEvent(kind: .assetLoaded, subject: assetID, job: job))
            }
            return job
        }
    }

    public func pollJob(_ job: JobID) -> EngineJobStatus {
        state.withLock { $0.jobs[job] ?? EngineJobStatus(job: job) }
    }

    // MARK: Recording and plugins

    public func armInput(track: NodeIDValue, inputChannelPair: UInt32, armed: Bool) {
        state.withLock { $0.calls.append(.armInput(track: track, pair: inputChannelPair, armed: armed)) }
    }

    public func instantiatePlugin(slot: NodeIDValue, _ plugin: PluginDescriptor) -> JobID {
        state.withLock { s in
            s.calls.append(.instantiatePlugin(slot: slot))
            let job = s.nextJob
            s.nextJob += 1
            s.jobs[job] = EngineJobStatus(job: job, kind: .instantiatePlugin, state: .succeeded, progress: 1)
            s.events.append(EngineEvent(kind: .jobFinished, subject: 3, job: job))
            return job
        }
    }

    public func pluginState(slot: NodeIDValue) -> Data { state.withLock { $0.pluginStates[slot] ?? Data() } }

    public func setPluginState(slot: NodeIDValue, _ data: Data) {
        state.withLock { s in
            s.calls.append(.setPluginState(slot: slot))
            s.pluginStates[slot] = data
        }
    }

    // MARK: Offline

    public func renderOffline(from: Tick, to: Tick, spec: ExportSpec) -> JobID {
        state.withLock { s in
            s.calls.append(.renderOffline(from: from, to: to, path: spec.path))
            let job = s.nextJob
            s.nextJob += 1
            var render = OfflineRenderResult()
            render.sampleRate = s.telemetry.sampleRate
            s.jobs[job] = EngineJobStatus(job: job, kind: .renderOffline, state: .succeeded, progress: 1, render: render)
            s.events.append(EngineEvent(kind: .jobFinished, subject: 2, job: job))
            return job
        }
    }

    // MARK: Device

    public func devices() -> [AudioDeviceInfo] { [] }

    public func setDevice(_ config: DriverConfig) throws(DAWError) {
        state.withLock { $0.calls.append(.setDevice(config)) }
        throw .notImplemented("FakeEngine has no device")
    }

    // MARK: Observability

    public func telemetry() -> EngineTelemetry { state.withLock { $0.telemetry } }
    public func nodeLatencies() -> [NodeLatency] { [] }
    public func meter(_ node: NodeIDValue) -> MeterReading? { nil }

    public func pollEvents(max: Int) -> [EngineEvent] {
        state.withLock { s in
            let n = Swift.min(Swift.max(max, 0), s.events.count)
            let out = Array(s.events.prefix(n))
            s.events.removeFirst(n)
            return out
        }
    }

    public func paramInfoJSON(_ kind: NodeKind) -> String { "[]" }
}
