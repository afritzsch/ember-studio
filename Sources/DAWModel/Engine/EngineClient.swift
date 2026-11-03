import CxxStdlib
import DAWEngine
import Foundation

/// BRIDGE-007: the real engine behind `EngineProtocol`, a thin Swift wrapper over the C++
/// `daw::EngineFacade` (08). This is the only Swift file that imports DAWEngine; everything it
/// returns is a plain Swift type from EngineProtocol.swift.
///
/// Sendable because the facade is thread-safe (BRIDGE-002); the class holds no other state.
public final class EngineClient: EngineProtocol {
    /// BRIDGE-001: a Swift class reference to the C++ object (retainFacade/releaseFacade).
    private let facade: daw.EngineFacade
    public let mode: EngineMode

    /// BRIDGE-008. Offline mode needs a session rate in 1 kHz…768 kHz. Realtime mode starts the
    /// driver `DriverConfig.driver` names (CoreAudio, or the fake devices, DW-089); if the device
    /// can't start, the engine exists without rendering and a `deviceChanged` event
    /// (`startFailed`) says why.
    public init(_ mode: EngineMode) throws(DAWError) {
        var config = daw.DriverConfigPOD()
        let cxxMode: daw.EngineMode
        switch mode {
        case .realtime(let driver):
            config = Self.cxx(driver)
            cxxMode = .realtime
        case .offline(let sampleRate):
            config.sampleRate = sampleRate
            cxxMode = .offline
        }
        guard let facade = daw.EngineFacade.create(cxxMode, config) else {
            throw .invalidArgument("engine: unsupported session rate \(config.sampleRate)")
        }
        self.facade = facade
        self.mode = mode
    }

    /// BRIDGE-001 diagnostics: identifies this client's engine for `EngineClient.isLive`.
    public var instanceID: UInt64 { facade.instanceID() }
    /// Whether the engine with `instanceID` still exists in this process.
    public static func isLive(_ instanceID: UInt64) -> Bool { daw.EngineFacade.isLive(instanceID) }

    // MARK: Graph & params

    @discardableResult
    public func applyGraph(_ graph: EngineGraph) -> UInt64 {
        facade.applyGraph(Self.description(for: graph))
    }

    public func graphStatus() -> GraphStatus { Self.swift(facade.graphStatus()) }

    @discardableResult
    public func waitForGraph(_ version: UInt64, timeout: Duration) -> GraphStatus {
        Self.swift(facade.waitForGraph(version, Self.milliseconds(timeout)))
    }

    public func allocateParams(_ count: UInt32) throws(DAWError) -> ParamID {
        let first = facade.allocateParams(count)
        guard first != daw.kInvalidParamID else {
            throw .invalidArgument("engine: no free run of \(count) param slots")
        }
        return first
    }

    public func freeParams(_ first: ParamID, count: UInt32) { facade.freeParams(first, count) }
    public func setParam(_ id: ParamID, _ value: Float) { facade.setParam(id, value) }
    public func getParam(_ id: ParamID) -> Float { facade.getParam(id) }

    // MARK: Transport

    public func play() { facade.play() }
    public func stop() { facade.stop() }
    public func locate(_ tick: Tick) { facade.locate(tick.raw) }
    public func setLoop(enabled: Bool, start: Tick, end: Tick) { facade.setLoop(enabled, start.raw, end.raw) }
    public func setRecording(_ recording: Bool) { facade.setRecording(recording) }

    /// UI-021 (T-043): the facade takes the MIDI source node feeding the track's instrument, its
    /// clip player (MODEL-020).
    public func previewNote(track: ModelID, pitch: UInt8, velocity: UInt8, on: Bool) {
        facade.previewNote(GraphNodeID.source(of: track), pitch, velocity, on)
    }

    public func transport() -> TransportState {
        let t = facade.transport()
        return TransportState(sample: t.sample, tick: Tick(t.tick), playing: t.playing, recording: t.recording,
                              loopEnabled: t.loopEnabled, loopStart: Tick(t.loopStart), loopEnd: Tick(t.loopEnd))
    }

    // MARK: Assets & jobs

    public func loadAsset(_ assetID: ModelID, path: String) -> JobID {
        facade.loadAsset(assetID, std.string(path))
    }

    public func peaks(_ assetID: ModelID, level: Int) -> PeakLevel? {
        guard level >= 0, level < PeakLevel.blockSizes.count else { return nil }
        let pod = facade.peaks(assetID, UInt32(level))
        guard pod.found else { return nil }
        let count = Int(pod.minMax.size())
        let minMax = [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            for i in 0..<count { buffer[i] = pod.minMax[i] }
            initialized = count
        }
        return PeakLevel(assetID: assetID, channels: Int(pod.channels), sampleRate: pod.sampleRate, frames: pod.frames,
                         blockSize: Int(pod.blockSize), blockCount: Int(pod.blockCount), minMax: minMax)
    }

    public func pollJob(_ job: JobID) -> EngineJobStatus {
        let s = facade.pollJob(job)
        var status = EngineJobStatus(job: job, progress: s.progress, error: Self.error(s.error))
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

    public func armInput(track: NodeIDValue, inputChannelPair: UInt32, armed: Bool) {
        facade.armInput(track, inputChannelPair, armed)
    }

    public func instantiatePlugin(slot: NodeIDValue, _ plugin: PluginDescriptor) -> JobID {
        facade.instantiatePlugin(slot, Self.cxx(plugin))
    }

    /// BRIDGE-006: `std::vector<uint8_t>` ↔ `Data`.
    public func pluginState(slot: NodeIDValue) -> Data { Data(facade.getPluginState(slot)) }

    public func setPluginState(slot: NodeIDValue, _ state: Data) {
        var bytes = daw.ByteVector()
        bytes.reserve(state.count)
        for byte in state { bytes.push_back(byte) }
        facade.setPluginState(slot, bytes)
    }

    /// PLUG-010/015 (T-061).
    public func pluginInfoJSON(slot: NodeIDValue) -> String { String(facade.pluginInfoJSON(slot)) }

    // MARK: Offline

    public func renderOffline(from: Tick, to: Tick, spec: ExportSpec) -> JobID {
        facade.renderOffline(from.raw, to.raw, Self.cxx(spec))
    }

    // MARK: Device

    public func devices() -> [AudioDeviceInfo] {
        facade.devices().map {
            AudioDeviceInfo(id: $0.deviceID, name: String($0.name), inputChannels: $0.inputChannels,
                            outputChannels: $0.outputChannels, nominalSampleRate: $0.nominalSampleRate,
                            isDefaultOutput: $0.isDefaultOutput)
        }
    }

    public func setDevice(_ config: DriverConfig) throws(DAWError) {
        if let error = Self.error(facade.setDevice(Self.cxx(config))) { throw error }
    }

    public func simulateDeviceEvent(_ event: DeviceEvent) throws(DAWError) {
        var pod = daw.DeviceEventPOD()
        pod.kind = switch event.kind {
        case .deviceLost: .deviceLost
        case .deviceRestored: .deviceRestored
        case .sampleRateChanged: .sampleRateChanged
        case .processorOverload: .processorOverload
        }
        pod.deviceID = event.deviceID
        pod.sampleRate = event.sampleRate
        if let error = Self.error(facade.simulateDeviceEvent(pod)) { throw error }
    }

    // MARK: Session sample rate (T-056)

    /// MODEL-005 `SetSessionSampleRate`, IO-033 (`daw::EngineFacade::setSessionSampleRate`).
    public func setSessionSampleRate(_ rate: Double) throws(DAWError) {
        if let error = Self.error(facade.setSessionSampleRate(rate)) { throw error }
    }

    /// DW-077: IO-034's peaks through the cache file in `peakCacheDirectory`.
    public func loadAsset(_ assetID: ModelID, path: String, peakCacheDirectory: String) -> JobID {
        facade.loadAsset(assetID, std.string(path), std.string(peakCacheDirectory))
    }

    // MARK: Observability

    public func telemetry() -> EngineTelemetry {
        // DW-049: field by field.
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
        out.assetsReloadPending = t.assetsReloadPending  // T-056
        return out
    }

    public func nodeLatencies() -> [NodeLatency] {
        facade.nodeLatencies().map { NodeLatency(node: $0.node, samples: $0.samples) }
    }

    public func meter(_ node: NodeIDValue) -> MeterReading? {
        let m = facade.meter(node)
        return m.valid ? MeterReading(peak: m.peak, rms: m.rms) : nil
    }

    public func pollEvents(max: Int) -> [EngineEvent] {
        guard max > 0 else { return [] }
        var buffer = [daw.EngineEventPOD](repeating: daw.EngineEventPOD(), count: max)
        let count = buffer.withUnsafeMutableBufferPointer { facade.pollEvents($0.baseAddress!, $0.count) }
        return buffer[..<count].map(Self.swift)
    }

    public func paramInfoJSON(_ kind: NodeKind) -> String { String(facade.paramInfoJSON(Self.cxx(kind))) }

    // MARK: Conversions

    /// BRIDGE-003: the description crosses as a C++ value filled through GraphDescriptionBuilder.
    static func description(for graph: EngineGraph) -> daw.GraphDescription {
        var builder = daw.GraphDescriptionBuilder()
        for n in graph.nodes {
            builder.addNode(n.id, cxx(n.kind), n.configVersion, n.firstParam, n.numParams, std.string(n.configJSON))
        }
        for e in graph.edges {
            let kind: daw.EdgeKind = switch e.kind {
            case .audio: .audio
            case .midi: .midi
            case .sidechain: .sidechain
            }
            builder.addEdge(e.id, e.from, e.to, kind, e.toPort)
        }
        for c in graph.audioClips {
            builder.addClip(c.player, c.clipID, c.start.raw, c.length.raw, c.assetID, c.sourceOffsetSamples,
                            c.gain, c.fadeIn.raw, c.fadeOut.raw)
        }
        for n in graph.notes {
            builder.addNote(n.player, n.start.raw, n.length.raw, n.pitch, n.velocity, n.channel)
        }
        for t in graph.tempoEvents { builder.setTempo(t.tick.raw, t.bpm) }
        for s in graph.timeSignatures {
            builder.setTimeSignature(s.tick.raw, Int32(clamping: s.numerator), Int32(clamping: s.denominator))
        }
        builder.setMaster(graph.master)
        return builder.description()
    }

    /// BRIDGE-003 test hook: `graph` through the C++ builder and back, field by field.
    static func roundTrip(_ graph: EngineGraph) -> EngineGraph { swift(description(for: graph)) }

    private static func swift(_ d: daw.GraphDescription) -> EngineGraph {
        var g = EngineGraph(tempoEvents: [], timeSignatures: [], master: d.master)
        for n in d.nodes {
            g.nodes.append(.init(id: n.id, kind: swift(n.kind), configVersion: n.configVersion,
                                 firstParam: n.firstParam, numParams: n.numParams, configJSON: String(n.configJSON)))
        }
        for e in d.edges {
            let kind: EngineGraph.EdgeKind = switch e.kind {
            case .midi: .midi
            case .sidechain: .sidechain
            default: .audio
            }
            g.edges.append(.init(id: e.edgeID, from: e.from, to: e.to, kind: kind, toPort: e.toPort))
        }
        for c in d.audioClips {
            g.audioClips.append(.init(player: c.player, clipID: c.clipID, start: Tick(c.start), length: Tick(c.length),
                                      assetID: c.assetID, sourceOffsetSamples: c.sourceOffsetSamples, gain: c.gain,
                                      fadeIn: Tick(c.fadeIn), fadeOut: Tick(c.fadeOut)))
        }
        for n in d.notes {
            g.notes.append(.init(player: n.player, start: Tick(n.start), length: Tick(n.length), pitch: n.pitch,
                                 velocity: n.velocity, channel: n.channel))
        }
        for t in d.tempo.tempos { g.tempoEvents.append(TempoEvent(tick: Tick(t.tick), bpm: t.bpm)) }
        for s in d.tempo.timeSigs {
            g.timeSignatures.append(TimeSignatureEvent(tick: Tick(s.tick), numerator: Int(s.num), denominator: Int(s.den)))
        }
        return g
    }

    private static func swift(_ kind: daw.NodeKind) -> NodeKind {
        NodeKind.allCases.first { cxx($0) == kind } ?? .master
    }

    /// DW-050: a rejected cycle becomes `.routingCycle` with its NodeIDs.
    static func error(_ e: daw.FacadeError) -> DAWError? {
        let message = String(e.message)
        switch e.code {
        case .none: return nil
        case .cycle: return .routingCycle(path: Array(e.cycle))
        case .invalidArgument: return .invalidArgument(message)
        case .unsupported: return .notImplemented(message)
        // DW-076
        case .notFound: return .engine(code: .notFound, detail: message)
        case .outOfMemory: return .engine(code: .outOfMemory, detail: message)
        case .io: return .engine(code: .io, detail: message)
        default: return .engine(code: .internal, detail: message)
        }
    }

    private static func swift(_ s: daw.GraphStatusPOD) -> GraphStatus {
        GraphStatus(submittedVersion: s.submittedVersion, completedVersion: s.completedVersion,
                    publishedVersion: s.publishedVersion, lastError: error(s.lastError))
    }

    private static func swift(_ e: daw.EngineEventPOD) -> EngineEvent {
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
        default: .deviceChanged
        }
        // T-056 (IO-033, DW-044): the re-conversion's progress.
        var reload: AssetsReload?
        if kind == .assetsReloaded {
            let phase: AssetsReload.Phase = switch e.reload.phase {
            case .started: .started
            case .progress: .progress
            default: .finished
            }
            reload = AssetsReload(phase: phase, previousSampleRate: e.reload.previousSampleRate,
                                  sampleRate: e.reload.sampleRate, done: e.reload.done, total: e.reload.total,
                                  failed: e.reload.failed, assetID: e.reload.assetID)
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
        return EngineEvent(kind: kind, subject: e.subject, job: e.job, count: e.count, error: error(e.error),
                           device: device, reload: reload)
    }

    private static func cxx(_ kind: NodeKind) -> daw.NodeKind {
        switch kind {
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

    private static func cxx(_ config: DriverConfig) -> daw.DriverConfigPOD {
        var out = daw.DriverConfigPOD()
        out.outputDevice = config.outputDevice
        out.inputDevice = config.inputDevice
        out.sampleRate = config.sampleRate
        out.bufferFrames = config.bufferFrames
        out.outputChannels = config.outputChannels
        out.inputChannels = config.inputChannels
        out.driver = config.driver == .fake ? .fake : .coreAudio
        return out
    }

    /// DW-017
    private static func cxx(_ plugin: PluginDescriptor) -> daw.PluginDescriptorPOD {
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
        return out
    }

    private static func cxx(_ spec: ExportSpec) -> daw.ExportSpecPOD {
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
        out.followLoop = spec.followLoop  // T-036
        return out
    }

    private static func milliseconds(_ duration: Duration) -> UInt32 {
        let (seconds, attoseconds) = duration.components
        guard seconds >= 0 else { return 0 }
        let ms = seconds.multipliedReportingOverflow(by: 1000)
        if ms.overflow { return .max }
        return UInt32(clamping: ms.partialValue + attoseconds / 1_000_000_000_000_000)
    }
}
