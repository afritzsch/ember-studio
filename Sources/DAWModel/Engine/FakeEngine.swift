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
        /// UI-021 (T-043).
        case previewNote(track: ModelID, pitch: UInt8, velocity: UInt8, on: Bool)
        case locate(Tick)
        case setLoop(enabled: Bool, start: Tick, end: Tick)
        case setRecording(Bool)
        case loadAsset(ModelID, path: String)
        case renderOffline(from: Tick, to: Tick, path: String)
        case armInput(track: NodeIDValue, pair: UInt32, armed: Bool)
        case instantiatePlugin(slot: NodeIDValue)
        case setPluginState(slot: NodeIDValue)
        case setDevice(DriverConfig)
        case simulateDeviceEvent(DeviceEvent)
        case setSessionSampleRate(Double)  // T-056
        /// T-052 (REC-002, REC-005).
        case setRecordingDirectory(String)
        case setPunch(enabled: Bool, start: Tick, end: Tick)
        /// T-053 (REC-011).
        case armMidiInput(track: NodeIDValue, armed: Bool)
        case injectMidi(atSample: Int64, relativeToNow: Bool, status: UInt8, data1: UInt8, data2: UInt8)
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
        var loadedAssets: Set<ModelID> = []
        var refusedSessionRates: Set<Double> = []  // T-056
        var armed: Set<NodeIDValue> = []  // T-052
        var recordingDirectory = ""
        var armedMidi: Set<NodeIDValue> = []  // T-053
        var midiInputs: [MidiInputInfo] = []
        var exportSpecs: [ExportSpec] = []  // T-082
        var failNextRender: DAWError?  // T-082
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
    /// T-082: every spec passed to `renderOffline`, in order.
    public var exportSpecs: [ExportSpec] { state.withLock { $0.exportSpecs } }
    /// T-082: the next `renderOffline` job fails with `error`.
    public func failNextRender(_ error: DAWError) { state.withLock { $0.failNextRender = error } }
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

    /// UI-021 (T-043): recorded; no sound.
    public func previewNote(track: ModelID, pitch: UInt8, velocity: UInt8, on: Bool) {
        state.withLock { $0.calls.append(.previewNote(track: track, pitch: pitch, velocity: velocity, on: on)) }
    }

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
                s.loadedAssets.insert(assetID)
                s.events.append(EngineEvent(kind: .jobFinished, subject: 1, job: job))
                s.events.append(EngineEvent(kind: .assetLoaded, subject: assetID, job: job))
            }
            return job
        }
    }

    /// IO-034: made-up peaks for a loaded asset (`assetInfo(for:)`'s stereo second): a 4 Hz
    /// sine envelope, louder on the left, so a canvas has something deterministic to draw.
    public func peaks(_ assetID: ModelID, level: Int) -> PeakLevel? {
        guard level >= 0, level < PeakLevel.blockSizes.count,
              state.withLock({ $0.loadedAssets.contains(assetID) }) else { return nil }
        let info = assetInfo(for: assetID)
        let blockSize = PeakLevel.blockSizes[level]
        let blocks = Int((info.frames + Int64(blockSize) - 1) / Int64(blockSize))
        var minMax: [Float] = []
        minMax.reserveCapacity(Int(info.channels) * blocks * 2)
        for channel in 0..<Int(info.channels) {
            for block in 0..<blocks {
                let t = Double(block * blockSize) / info.sampleRate
                let level = Float(abs(sin(2 * .pi * 4 * t))) * (channel == 0 ? 0.9 : 0.6)
                minMax += [-level, level]
            }
        }
        return PeakLevel(assetID: assetID, channels: Int(info.channels), sampleRate: info.sampleRate, frames: info.frames,
                         blockSize: blockSize, blockCount: blocks, minMax: minMax)
    }

    public func pollJob(_ job: JobID) -> EngineJobStatus {
        state.withLock { $0.jobs[job] ?? EngineJobStatus(job: job) }
    }

    // MARK: Recording and plugins

    public func armInput(track: NodeIDValue, inputChannelPair: UInt32, armed: Bool) {
        state.withLock { s in
            s.calls.append(.armInput(track: track, pair: inputChannelPair, armed: armed))
            if armed { s.armed.insert(track) } else { s.armed.remove(track) }
            s.telemetry.armedTracks = UInt32(s.armed.count)
        }
    }

    /// T-052: recorded. Nothing is captured; tests post `recordingFinalized` events themselves.
    public func setRecordingDirectory(_ path: String) {
        state.withLock { s in
            s.calls.append(.setRecordingDirectory(path))
            s.recordingDirectory = path
        }
    }

    // MARK: MIDI input (T-053)

    public func armMidiInput(track: NodeIDValue, armed: Bool) {
        state.withLock { s in
            s.calls.append(.armMidiInput(track: track, armed: armed))
            if armed { s.armedMidi.insert(track) } else { s.armedMidi.remove(track) }
            s.telemetry.armedMidiTracks = UInt32(s.armedMidi.count)
        }
    }

    public func midiInputs() -> [MidiInputInfo] { state.withLock { $0.midiInputs } }

    /// T-053: what `midiInputs` reports, for tests.
    public func setMidiInputs(_ inputs: [MidiInputInfo]) { state.withLock { $0.midiInputs = inputs } }

    /// T-053: recorded. Nothing is rendered; tests post `recordingFinalized` events themselves.
    public func injectMidi(atSample: Int64, relativeToNow: Bool, status: UInt8, data1: UInt8, data2: UInt8) throws(DAWError) {
        state.withLock { $0.calls.append(.injectMidi(atSample: atSample, relativeToNow: relativeToNow, status: status, data1: data1, data2: data2)) }
    }

    /// T-052: the last `setRecordingDirectory`.
    public var recordingDirectory: String { state.withLock { $0.recordingDirectory } }

    /// T-052 (REC-005): like the facade, an enabled empty range is ignored.
    public func setPunch(enabled: Bool, start: Tick, end: Tick) {
        state.withLock { s in
            s.calls.append(.setPunch(enabled: enabled, start: start, end: end))
            if enabled && (start.raw < 0 || start >= end) { return }
            s.transport.punchEnabled = enabled
            if enabled || start < end {
                s.transport.punchIn = start
                s.transport.punchOut = end
            }
        }
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
            s.exportSpecs.append(spec)  // T-082
            let job = s.nextJob
            s.nextJob += 1
            var render = OfflineRenderResult()
            render.sampleRate = s.telemetry.sampleRate
            s.jobs[job] = EngineJobStatus(job: job, kind: .renderOffline, state: .succeeded, progress: 1, render: render)
            if let error = s.failNextRender {  // T-082
                s.failNextRender = nil
                s.jobs[job] = EngineJobStatus(job: job, kind: .renderOffline, state: .failed, progress: 0, error: error,
                                              render: render)
            }
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

    /// Recorded, then refused like `setDevice`. To test reactions to device changes, `post` a
    /// `deviceChanged` event with a `DeviceChange` instead.
    public func simulateDeviceEvent(_ event: DeviceEvent) throws(DAWError) {
        state.withLock { $0.calls.append(.simulateDeviceEvent(event)) }
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

    // MARK: Session sample rate (T-056: IO-033, MODEL-005, DW-130)

    /// Records the call, then does what the engine does at once: invalidArgument for a rate that
    /// isn't 44.1/48/88.2/96 kHz, `notImplemented` for one `refuseSessionRate` named (a device that
    /// can't run it), nothing for the current rate, else the change (see
    /// `simulateEngineRateChange`).
    public func setSessionSampleRate(_ rate: Double) throws(DAWError) {
        let refused: Bool = state.withLock { s in
            s.calls.append(.setSessionSampleRate(rate))
            return s.refusedSessionRates.contains(rate)
        }
        guard Project.supportedSampleRates.contains(rate) else {
            throw .invalidArgument("not a session rate (44.1/48/88.2/96 kHz)")
        }
        if refused { throw .notImplemented("the device can't run at \(rate) Hz") }
        changeRate(to: rate)
    }

    /// The next `setSessionSampleRate(rate)` calls throw, like a device that can't run `rate`.
    public func refuseSessionRate(_ rate: Double) { _ = state.withLock { $0.refusedSessionRates.insert(rate) } }

    /// The engine changes its session rate by itself (a device fallback, IO-021 (5)), as
    /// `setSessionSampleRate` does but without a call: the transport stops, telemetry shows `rate`,
    /// and `assetsReloaded` events say `started`, one `progress` per loaded asset (by ID) and
    /// `finished`.
    public func simulateEngineRateChange(to rate: Double) { changeRate(to: rate) }

    private func changeRate(to rate: Double) {
        state.withLock { s in
            let previous = s.telemetry.sampleRate
            guard rate != previous else { return }
            s.transport.playing = false
            s.telemetry.sampleRate = rate
            let assets = s.loadedAssets.sorted()
            let total = UInt32(assets.count)
            func post(_ phase: AssetsReload.Phase, done: UInt32, asset: ModelID = 0) {
                s.events.append(EngineEvent(
                    kind: .assetsReloaded, subject: asset, count: UInt64(done),
                    reload: AssetsReload(phase: phase, previousSampleRate: previous, sampleRate: rate, done: done,
                                         total: total, assetID: asset)))
            }
            post(.started, done: 0)
            for (i, asset) in assets.enumerated() { post(.progress, done: UInt32(i + 1), asset: asset) }
            post(.finished, done: total)
        }
    }
}
