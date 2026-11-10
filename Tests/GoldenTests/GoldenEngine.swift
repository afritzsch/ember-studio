import CxxStdlib
import DAWEngine
import DAWGoldenSupport
@testable import DAWModel
import Foundation

/// TEST-004: the engine golden fixtures render with. A real offline `EngineFacade` whose registry
/// also has the fixture's test-only nodes (`makeTestFacade`, GoldenEngineSupport.h), behind
/// `EngineProtocol` so DAWControl's `Dispatcher` drives it exactly like `EngineClient`.
///
/// It mirrors `EngineClient` method for method. `EngineClient` builds its own facade and can't
/// take this one, so the conversions `EngineClient` keeps private are repeated here; the graph
/// description and error mapping are `EngineClient`'s own (internal, via `@testable`).
final class GoldenEngine: EngineProtocol {
    private let facade: daw.EngineFacade
    let mode: EngineMode

    init(sampleRate: Double, testNodes: [GoldenFixture.TestNode]) throws(DAWError) {
        var specs = daw.testing.TestNodeSpecs()
        for node in testNodes { specs.push_back(node.spec) }
        guard let facade = daw.testing.makeTestFacade(sampleRate, specs) else {
            throw .invalidArgument("golden engine: unsupported session rate \(sampleRate) or a test node kind given twice")
        }
        self.facade = facade
        self.mode = .offline(sampleRate: sampleRate)
    }

    // MARK: Graph & params

    @discardableResult
    func applyGraph(_ graph: EngineGraph) -> UInt64 { facade.applyGraph(EngineClient.description(for: graph)) }

    func graphStatus() -> GraphStatus { Self.swift(facade.graphStatus()) }

    @discardableResult
    func waitForGraph(_ version: UInt64, timeout: Duration) -> GraphStatus {
        let (seconds, attoseconds) = timeout.components
        let ms = seconds < 0 ? 0 : seconds.multipliedReportingOverflow(by: 1000).overflow ? Int64(UInt32.max)
            : seconds * 1000 + attoseconds / 1_000_000_000_000_000
        return Self.swift(facade.waitForGraph(version, UInt32(clamping: ms)))
    }

    func allocateParams(_ count: UInt32) throws(DAWError) -> ParamID {
        let first = facade.allocateParams(count)
        guard first != daw.kInvalidParamID else { throw .invalidArgument("engine: no free run of \(count) param slots") }
        return first
    }

    func freeParams(_ first: ParamID, count: UInt32) { facade.freeParams(first, count) }
    func setParam(_ id: ParamID, _ value: Float) { facade.setParam(id, value) }
    func getParam(_ id: ParamID) -> Float { facade.getParam(id) }

    // MARK: Transport

    func play() { facade.play() }
    func stop() { facade.stop() }
    func locate(_ tick: Tick) { facade.locate(tick.raw) }
    func setLoop(enabled: Bool, start: Tick, end: Tick) { facade.setLoop(enabled, start.raw, end.raw) }
    func setRecording(_ recording: Bool) { facade.setRecording(recording) }

    func transport() -> TransportState {
        let t = facade.transport()
        return TransportState(sample: t.sample, tick: Tick(t.tick), playing: t.playing, recording: t.recording,
                              loopEnabled: t.loopEnabled, loopStart: Tick(t.loopStart), loopEnd: Tick(t.loopEnd))
    }

    // MARK: Assets & jobs

    func loadAsset(_ assetID: ModelID, path: String) -> JobID { facade.loadAsset(assetID, std.string(path)) }

    func pollJob(_ job: JobID) -> EngineJobStatus {
        let s = facade.pollJob(job)
        var status = EngineJobStatus(job: job, progress: s.progress, error: EngineClient.error(s.error))
        switch s.kind {
        case .loadAsset: status.kind = .loadAsset
        case .renderOffline: status.kind = .renderOffline
        case .instantiatePlugin: status.kind = .instantiatePlugin
        default: status.kind = .none
        }
        switch s.state {
        case .queued: status.state = .queued
        case .running: status.state = .running
        case .succeeded: status.state = .succeeded
        case .failed: status.state = .failed
        default: status.state = .unknown
        }
        if status.kind == .loadAsset && status.state == .succeeded {
            let a = s.asset
            status.asset = LoadedAssetInfo(assetID: a.assetID, channels: a.channels, frames: a.frames,
                                           sampleRate: a.sampleRate, fileSampleRate: a.fileSampleRate,
                                           fileFrames: a.fileFrames, resampled: a.resampled)
        }
        if status.kind == .renderOffline && status.state.isFinished {
            let r = s.render
            var render = OfflineRenderResult()
            render.sampleRate = r.sampleRate
            render.rangeFrames = r.rangeFrames
            render.tailFrames = r.tailFrames
            render.framesWritten = r.framesWritten
            render.blocks = r.blocks
            render.rtViolations = r.rtViolations
            render.clippedSamples = r.clippedSamples
            render.renderSeconds = r.renderSeconds
            status.render = render
        }
        return status
    }

    // MARK: Recording and plugins

    func armInput(track: NodeIDValue, inputChannelPair: UInt32, armed: Bool) {
        facade.armInput(track, inputChannelPair, armed)
    }

    func instantiatePlugin(slot: NodeIDValue, _ plugin: PluginDescriptor) -> JobID {
        var out = daw.PluginDescriptorPOD()
        let fields: (String, String, String, String)
        switch plugin {
        case .audioUnit(let au):
            out.format = .audioUnit
            fields = (au.identifier, au.name, au.vendor, au.version)
        case .vst3(let vst3):
            out.format = .vst3
            fields = (vst3.identifier, vst3.name, vst3.vendor, vst3.version)
        }
        out.identifier = std.string(fields.0)
        out.name = std.string(fields.1)
        out.vendor = std.string(fields.2)
        out.version = std.string(fields.3)
        return facade.instantiatePlugin(slot, out)
    }

    func pluginState(slot: NodeIDValue) -> Data { Data(facade.getPluginState(slot)) }
    func setPluginState(slot: NodeIDValue, _ state: Data) {
        var bytes = daw.ByteVector()
        for byte in state { bytes.push_back(byte) }
        facade.setPluginState(slot, bytes)
    }

    // MARK: Offline

    func renderOffline(from: Tick, to: Tick, spec: ExportSpec) -> JobID {
        var out = daw.ExportSpecPOD()
        out.path = std.string(spec.path)
        out.fileType = switch spec.fileType {
        case .caf: .caf
        case .wav: .wav
        case .aiff: .aiff
        }
        out.sampleFormat = switch spec.sampleFormat {
        case .int16: .int16
        case .int24: .int24
        case .float32: .float32
        }
        out.dither = spec.dither
        out.ditherSeed = spec.ditherSeed
        out.numChannels = spec.numChannels
        out.blockSize = spec.blockSize
        out.tailEnabled = spec.tailEnabled
        out.tailThresholdDb = spec.tailThresholdDb
        out.tailQuietSeconds = spec.tailQuietSeconds
        out.tailMaxSeconds = spec.tailMaxSeconds
        out.followLoop = spec.followLoop  // T-036: render.offline {loop: true}
        return facade.renderOffline(from.raw, to.raw, out)
    }

    // MARK: Device (offline: none, and setDevice fails like EngineClient's offline engine)

    func devices() -> [AudioDeviceInfo] { [] }
    func setDevice(_ config: DriverConfig) throws(DAWError) {
        var out = daw.DriverConfigPOD()
        out.outputDevice = config.outputDevice
        out.inputDevice = config.inputDevice
        out.sampleRate = config.sampleRate
        out.bufferFrames = config.bufferFrames
        out.outputChannels = config.outputChannels
        out.inputChannels = config.inputChannels
        out.driver = config.driver == .fake ? .fake : .coreAudio
        if let error = EngineClient.error(facade.setDevice(out)) { throw error }
    }

    func simulateDeviceEvent(_ event: DeviceEvent) throws(DAWError) {
        var pod = daw.DeviceEventPOD()
        pod.kind = switch event.kind {
        case .deviceLost: .deviceLost
        case .deviceRestored: .deviceRestored
        case .sampleRateChanged: .sampleRateChanged
        case .processorOverload: .processorOverload
        }
        pod.deviceID = event.deviceID
        pod.sampleRate = event.sampleRate
        if let error = EngineClient.error(facade.simulateDeviceEvent(pod)) { throw error }
    }

    // MARK: Observability

    func telemetry() -> EngineTelemetry {
        let t = facade.telemetry()
        var out = EngineTelemetry()
        out.dspLoadPercent = t.dspLoadPercent
        out.lastBlockLoadPercent = t.lastBlockLoadPercent
        out.xruns = t.xruns
        out.rtViolations = t.rtViolations
        out.graphEpoch = t.graphEpoch
        out.oversizeBlocks = t.oversizeBlocks
        out.retireQueueFullBlocks = t.retireQueueFullBlocks
        out.deviceOutputLatency = t.deviceOutputLatency
        out.graphLatency = t.graphLatency
        out.outputLatency = t.outputLatency
        out.numNodeLatencies = t.numNodeLatencies
        out.graphVersion = t.graphVersion
        out.blocksRendered = t.blocksRendered
        out.paramsAllocated = t.paramsAllocated
        out.paramsPendingFree = t.paramsPendingFree
        out.assetsLoaded = t.assetsLoaded
        out.eventsDropped = t.eventsDropped
        out.sampleRate = t.sampleRate
        out.deviceRunning = t.deviceRunning
        out.outputDeviceID = t.outputDeviceID
        out.processorOverloads = t.processorOverloads
        out.renderOverruns = t.renderOverruns
        return out
    }

    func nodeLatencies() -> [NodeLatency] {
        facade.nodeLatencies().map { NodeLatency(node: $0.node, samples: $0.samples) }
    }

    func meter(_ node: NodeIDValue) -> MeterReading? {
        let m = facade.meter(node)
        return m.valid ? MeterReading(peak: m.peak, rms: m.rms) : nil
    }

    func pollEvents(max: Int) -> [EngineEvent] {
        guard max > 0 else { return [] }
        var buffer = [daw.EngineEventPOD](repeating: daw.EngineEventPOD(), count: max)
        let count = buffer.withUnsafeMutableBufferPointer { facade.pollEvents($0.baseAddress!, $0.count) }
        return buffer[..<count].map { e in
            let kind: EngineEvent.Kind = switch e.type {
            case .deviceChanged: .deviceChanged
            case .overload: .overload
            case .recordingFinalized: .recordingFinalized
            case .assetsReloaded: .assetsReloaded
            case .pluginCrashed: .pluginCrashed
            case .assetLoaded: .assetLoaded
            case .assetLoadFailed: .assetLoadFailed
            case .graphRejected: .graphRejected
            case .jobFinished: .jobFinished
            case .pluginMisbehaved: .pluginMisbehaved  // T-064
            default: .deviceChanged
            }
            var device: DeviceChange?
            if kind == .deviceChanged {
                let reason: DeviceChange.Reason = switch e.device.reason {
                case .deviceLost: .deviceLost
                case .sampleRateChanged: .sampleRateChanged
                case .defaultOutputChanged: .defaultOutputChanged
                case .deviceAvailable: .deviceAvailable
                case .startFailed: .startFailed
                default: .startFailed
                }
                device = DeviceChange(reason: reason, previousDeviceID: e.device.previousDeviceID,
                                      deviceID: e.device.deviceID, previousSampleRate: e.device.previousSampleRate,
                                      sampleRate: e.device.sampleRate)
            }
            return EngineEvent(kind: kind, subject: e.subject, job: e.job, count: e.count,
                               error: EngineClient.error(e.error), device: device)
        }
    }

    func paramInfoJSON(_ kind: NodeKind) -> String { String(facade.paramInfoJSON(kind.cxx)) }

    private static func swift(_ s: daw.GraphStatusPOD) -> GraphStatus {
        GraphStatus(submittedVersion: s.submittedVersion, completedVersion: s.completedVersion,
                    publishedVersion: s.publishedVersion, lastError: EngineClient.error(s.lastError))
    }
}

extension NodeKind {
    /// `daw::NodeKind`; the cases have the same names (NodeKind.swift).
    var cxx: daw.NodeKind {
        switch self {
        case .audioClipPlayer: .audioClipPlayer
        case .midiClipPlayer: .midiClipPlayer
        case .sampler: .sampler
        case .channelStrip: .channelStrip
        case .gain: .gain
        case .eq: .eq
        case .compressor: .compressor
        case .delay: .delay
        case .reverb: .reverb
        case .metronome: .metronome
        case .auPlugin: .auPlugin
        case .vst3Plugin: .vst3Plugin
        case .master: .master
        case .bus: .bus
        }
    }
}

extension GoldenFixture.TestNode {
    /// What `makeTestFacade` registers (GoldenEngineSupport.h).
    var spec: daw.testing.TestNodeSpec {
        var spec = daw.testing.TestNodeSpec()
        spec.kind = kind.cxx
        spec.type = switch type {
        case .sine: .sine
        case .impulse: .impulse
        case .fakeLatency: .fakeLatency
        case .nan: .nan
        }
        spec.frequency = frequency ?? 0
        spec.level = level ?? 1
        spec.samples = samples ?? 0
        spec.offset = offset ?? 0
        return spec
    }
}
