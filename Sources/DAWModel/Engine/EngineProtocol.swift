import Foundation

// 08-bridge-facade BRIDGE-007: what DAWModel, DAWControl and the app know about the engine.
// `EngineClient` implements it over the C++ facade; `FakeEngine` implements it for model tests.
// Every type here is plain Swift, so nothing outside EngineClient.swift imports DAWEngine.

/// Index of a param slot (ENG-020), `daw::ParamID`.
public typealias ParamID = UInt32
/// A long-running engine operation (BRIDGE-002), `daw::JobID`. 0 means the request was
/// rejected before a job was created.
public typealias JobID = UInt64

/// IO-003/004 (`daw::DriverConfigPOD`). The engine turns input on while a track is armed
/// (DW-067). In offline mode only `sampleRate` matters: it is the session rate.
public struct DriverConfig: Hashable, Sendable, Codable {
    /// AudioObjectID (`AudioDeviceInfo.id`); 0: the system default output.
    public var outputDevice: UInt32
    /// 0: the system default input (IO-004 may use the output device instead).
    public var inputDevice: UInt32
    /// 0 in realtime mode: the device's nominal rate.
    public var sampleRate: Double
    /// 32…2048.
    public var bufferFrames: UInt32
    public var outputChannels: UInt32
    public var inputChannels: UInt32

    public init(outputDevice: UInt32 = 0, inputDevice: UInt32 = 0, sampleRate: Double = 0,
                bufferFrames: UInt32 = 256, outputChannels: UInt32 = 2, inputChannels: UInt32 = 2) {
        self.outputDevice = outputDevice
        self.inputDevice = inputDevice
        self.sampleRate = sampleRate
        self.bufferFrames = bufferFrames
        self.outputChannels = outputChannels
        self.inputChannels = inputChannels
    }
}

/// BRIDGE-008: chosen when the engine is created.
public enum EngineMode: Hashable, Sendable {
    /// A device driver renders.
    case realtime(DriverConfig)
    /// No device: renders only through `renderOffline` (`dawctl`, `dawmcp`, tests).
    case offline(sampleRate: Double = 48_000)
}

// MARK: Graph (BRIDGE-003, 08 delta 4)

/// The routing description the engine compiles (`daw::GraphDescription`, 05 Interfaces), as a
/// Swift value. GraphDescriptionBuilder (MODEL-020) produces it from a Project. The engine
/// stamps the version, so there is none here.
public struct EngineGraph: Hashable, Sendable {
    public struct Node: Hashable, Sendable {
        public var id: NodeIDValue
        public var kind: NodeKind
        /// Bump to make the engine create and prepare a new instance (DW-036, DW-051).
        public var configVersion: UInt32
        public var firstParam: ParamID
        public var numParams: UInt32
        public var configJSON: String

        public init(id: NodeIDValue, kind: NodeKind, configVersion: UInt32 = 0, firstParam: ParamID = 0,
                    numParams: UInt32 = 0, configJSON: String = "") {
            self.id = id
            self.kind = kind
            self.configVersion = configVersion
            self.firstParam = firstParam
            self.numParams = numParams
            self.configJSON = configJSON
        }
    }

    public enum EdgeKind: String, Hashable, Sendable, Codable {
        case audio, midi, sidechain
    }

    public struct Edge: Hashable, Sendable {
        public var id: ModelID
        public var from: NodeIDValue
        public var to: NodeIDValue
        public var kind: EdgeKind
        /// MIX-004: 0 in v1.
        public var toPort: UInt8

        public init(id: ModelID, from: NodeIDValue, to: NodeIDValue, kind: EdgeKind = .audio, toPort: UInt8 = 0) {
            self.id = id
            self.from = from
            self.to = to
            self.kind = kind
            self.toPort = toPort
        }
    }

    public struct Clip: Hashable, Sendable {
        public var player: NodeIDValue
        public var clipID: ModelID
        public var start: Tick
        public var length: Tick
        public var assetID: ModelID
        public var sourceOffsetSamples: Int64
        public var gain: Float
        public var fadeIn: Tick
        public var fadeOut: Tick

        public init(player: NodeIDValue, clipID: ModelID, start: Tick, length: Tick, assetID: ModelID,
                    sourceOffsetSamples: Int64 = 0, gain: Float = 1, fadeIn: Tick = 0, fadeOut: Tick = 0) {
            self.player = player
            self.clipID = clipID
            self.start = start
            self.length = length
            self.assetID = assetID
            self.sourceOffsetSamples = sourceOffsetSamples
            self.gain = gain
            self.fadeIn = fadeIn
            self.fadeOut = fadeOut
        }
    }

    public struct Note: Hashable, Sendable {
        public var player: NodeIDValue
        public var start: Tick
        public var length: Tick
        public var pitch: UInt8
        public var velocity: UInt8
        public var channel: UInt8

        public init(player: NodeIDValue, start: Tick, length: Tick, pitch: UInt8, velocity: UInt8, channel: UInt8 = 0) {
            self.player = player
            self.start = start
            self.length = length
            self.pitch = pitch
            self.velocity = velocity
            self.channel = channel
        }
    }

    public var nodes: [Node]
    public var edges: [Edge]
    public var audioClips: [Clip]
    public var notes: [Note]
    /// TIME model: each list starts at tick 0.
    public var tempoEvents: [TempoEvent]
    public var timeSignatures: [TimeSignatureEvent]
    public var master: NodeIDValue

    /// 120 bpm, 4/4, no nodes.
    public init(nodes: [Node] = [], edges: [Edge] = [], audioClips: [Clip] = [], notes: [Note] = [],
                tempoEvents: [TempoEvent] = [TempoEvent(tick: 0, bpm: 120)],
                timeSignatures: [TimeSignatureEvent] = [TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)],
                master: NodeIDValue = 0) {
        self.nodes = nodes
        self.edges = edges
        self.audioClips = audioClips
        self.notes = notes
        self.tempoEvents = tempoEvents
        self.timeSignatures = timeSignatures
        self.master = master
    }
}

/// What became of the descriptions passed to `applyGraph` (DW-047, 08 delta 3).
public struct GraphStatus: Hashable, Sendable, Codable {
    /// The latest `applyGraph`.
    public var submittedVersion: UInt64
    /// The latest version built, rejected or dropped as superseded.
    public var completedVersion: UInt64
    /// The version rendering now (0: none yet).
    public var publishedVersion: UInt64
    /// From the latest build; nil after a success. A rejected cycle is `.routingCycle` (DW-050).
    public var lastError: DAWError?

    public init(submittedVersion: UInt64 = 0, completedVersion: UInt64 = 0, publishedVersion: UInt64 = 0,
                lastError: DAWError? = nil) {
        self.submittedVersion = submittedVersion
        self.completedVersion = completedVersion
        self.publishedVersion = publishedVersion
        self.lastError = lastError
    }

    /// Whether `version` is the one rendering (or a later one is).
    public func isPublished(_ version: UInt64) -> Bool { publishedVersion >= version }
}

// MARK: Transport, telemetry, events

/// TIME-009: the playhead, i.e. the position being heard.
public struct TransportState: Hashable, Sendable, Codable {
    public var sample: SamplePos
    public var tick: Tick
    public var playing: Bool
    public var recording: Bool
    public var loopEnabled: Bool
    public var loopStart: Tick
    public var loopEnd: Tick

    public init(sample: SamplePos = 0, tick: Tick = 0, playing: Bool = false, recording: Bool = false,
                loopEnabled: Bool = false, loopStart: Tick = 0, loopEnd: Tick = 0) {
        self.sample = sample
        self.tick = tick
        self.playing = playing
        self.recording = recording
        self.loopEnabled = loopEnabled
        self.loopStart = loopStart
        self.loopEnd = loopEnd
    }
}

/// BRIDGE-005: `daw::TelemetryPOD`.
public struct EngineTelemetry: Hashable, Sendable, Codable {
    public var dspLoadPercent: Float = 0
    public var lastBlockLoadPercent: Float = 0
    public var xruns: UInt64 = 0
    /// ENG-032: violations in the engine's own render scope. Must be 0 (CONV §5.3).
    public var rtViolations: UInt64 = 0
    public var graphEpoch: UInt64 = 0
    public var oversizeBlocks: UInt64 = 0
    public var retireQueueFullBlocks: UInt64 = 0
    public var deviceOutputLatency: UInt32 = 0
    public var graphLatency: UInt32 = 0
    public var outputLatency: UInt32 = 0
    public var numNodeLatencies: UInt32 = 0
    /// DW-047: the version of the graph rendering now.
    public var graphVersion: UInt64 = 0
    public var blocksRendered: UInt64 = 0
    public var paramsAllocated: UInt32 = 0
    /// DW-029: freed but not yet reusable.
    public var paramsPendingFree: UInt32 = 0
    public var assetsLoaded: UInt32 = 0
    public var eventsDropped: UInt64 = 0
    public var sampleRate: Double = 0
    public var deviceRunning: Bool = false

    public init() {}
}

public struct NodeLatency: Hashable, Sendable, Codable {
    public var node: NodeIDValue
    public var samples: UInt32

    public init(node: NodeIDValue, samples: UInt32) {
        self.node = node
        self.samples = samples
    }
}

/// Linear amplitude.
public struct MeterReading: Hashable, Sendable, Codable {
    public var peak: Float
    public var rms: Float

    public init(peak: Float, rms: Float) {
        self.peak = peak
        self.rms = rms
    }
}

/// BRIDGE-004: `daw::EngineEventPOD`.
public struct EngineEvent: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case deviceChanged, overload, recordingFinalized, assetsReloaded, pluginCrashed
        /// `subject` is the assetID. Clip players referencing it need a configVersion bump (DW-051).
        case assetLoaded
        case assetLoadFailed
        /// `subject` is the rejected graph version.
        case graphRejected
        case jobFinished
    }

    public var kind: Kind
    public var subject: UInt64
    public var job: JobID
    /// `overload`: the total xrun count.
    public var count: UInt64
    public var error: DAWError?

    public init(kind: Kind, subject: UInt64 = 0, job: JobID = 0, count: UInt64 = 0, error: DAWError? = nil) {
        self.kind = kind
        self.subject = subject
        self.job = job
        self.count = count
        self.error = error
    }
}

public struct AudioDeviceInfo: Hashable, Sendable, Codable {
    /// AudioObjectID, for `DriverConfig`.
    public var id: UInt32
    public var name: String
    public var inputChannels: UInt32
    public var outputChannels: UInt32
    public var nominalSampleRate: Double
    public var isDefaultOutput: Bool

    public init(id: UInt32, name: String, inputChannels: UInt32, outputChannels: UInt32,
                nominalSampleRate: Double, isDefaultOutput: Bool) {
        self.id = id
        self.name = name
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.nominalSampleRate = nominalSampleRate
        self.isDefaultOutput = isDefaultOutput
    }
}

/// DW-017: the plugin to instantiate (`daw::PluginDescriptorPOD`).
public enum PluginDescriptor: Hashable, Sendable, Codable {
    case audioUnit(AUDescriptor)
    case vst3(VST3Descriptor)
}

// MARK: Jobs (BRIDGE-002)

public struct LoadedAssetInfo: Hashable, Sendable, Codable {
    public var assetID: ModelID
    public var channels: UInt32
    /// At `sampleRate`, the session rate.
    public var frames: Int64
    public var sampleRate: Double
    public var fileSampleRate: Double
    public var fileFrames: Int64
    public var resampled: Bool

    public init(assetID: ModelID, channels: UInt32, frames: Int64, sampleRate: Double,
                fileSampleRate: Double, fileFrames: Int64, resampled: Bool) {
        self.assetID = assetID
        self.channels = channels
        self.frames = frames
        self.sampleRate = sampleRate
        self.fileSampleRate = fileSampleRate
        self.fileFrames = fileFrames
        self.resampled = resampled
    }
}

public struct OfflineRenderResult: Hashable, Sendable, Codable {
    public var sampleRate: Double = 0
    public var rangeFrames: Int64 = 0
    public var tailFrames: Int64 = 0
    public var framesWritten: Int64 = 0
    public var blocks: UInt64 = 0
    /// IO-013: the render thread's own RT trap count.
    public var rtViolations: UInt64 = 0
    public var clippedSamples: UInt64 = 0
    public var renderSeconds: Double = 0

    public init() {}

    /// Length of the file in seconds (CTL `render.offline` → `durationSec`).
    public var durationSeconds: Double { sampleRate > 0 ? Double(framesWritten) / sampleRate : 0 }
}

public struct EngineJobStatus: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case none, loadAsset, renderOffline, instantiatePlugin
    }

    public enum State: String, Hashable, Sendable, Codable {
        /// No such job.
        case unknown
        case queued, running, succeeded, failed

        public var isFinished: Bool { self == .succeeded || self == .failed }
    }

    public var job: JobID
    public var kind: Kind
    public var state: State
    /// 0…1.
    public var progress: Double
    public var error: DAWError?
    /// `loadAsset`, once succeeded.
    public var asset: LoadedAssetInfo?
    /// `renderOffline`, once finished.
    public var render: OfflineRenderResult?

    public init(job: JobID, kind: Kind = .none, state: State = .unknown, progress: Double = 0,
                error: DAWError? = nil, asset: LoadedAssetInfo? = nil, render: OfflineRenderResult? = nil) {
        self.job = job
        self.kind = kind
        self.state = state
        self.progress = progress
        self.error = error
        self.asset = asset
        self.render = render
    }
}

/// IO-010..013, IO-035: `daw::ExportSpecPOD`. The engine uses the tempo map of the graph it
/// renders (DW-064).
public struct ExportSpec: Hashable, Sendable, Codable {
    public enum FileType: String, Hashable, Sendable, Codable { case caf, wav, aiff }
    public enum SampleFormat: String, Hashable, Sendable, Codable { case int16, int24, float32 }

    /// Empty: render without writing a file.
    public var path: String
    public var fileType: FileType
    public var sampleFormat: SampleFormat
    /// TPDF dither for int16/int24 (IO-035).
    public var dither: Bool
    public var ditherSeed: UInt64
    public var numChannels: UInt32
    /// IO-010; at most 4096 (the graph's maxBlock).
    public var blockSize: UInt32
    /// IO-012.
    public var tailEnabled: Bool
    public var tailThresholdDb: Double
    public var tailQuietSeconds: Double
    public var tailMaxSeconds: Double

    public init(path: String, fileType: FileType = .wav, sampleFormat: SampleFormat = .float32,
                dither: Bool = false, ditherSeed: UInt64 = 0x6d61_6344_4157_0035, numChannels: UInt32 = 2,
                blockSize: UInt32 = 512, tailEnabled: Bool = true, tailThresholdDb: Double = -90,
                tailQuietSeconds: Double = 1, tailMaxSeconds: Double = 10) {
        self.path = path
        self.fileType = fileType
        self.sampleFormat = sampleFormat
        self.dither = dither
        self.ditherSeed = ditherSeed
        self.numChannels = numChannels
        self.blockSize = blockSize
        self.tailEnabled = tailEnabled
        self.tailThresholdDb = tailThresholdDb
        self.tailQuietSeconds = tailQuietSeconds
        self.tailMaxSeconds = tailMaxSeconds
    }
}

// MARK: The protocol

/// 08 Interfaces (BRIDGE-007): mirrors `daw::EngineFacade` with Swift types. Every method is
/// thread-safe and returns promptly, except `waitForGraph`, which blocks up to its timeout (use
/// `graphApplied` from async code).
public protocol EngineProtocol: AnyObject, Sendable {
    var mode: EngineMode { get }

    // Graph & params
    /// Queues `graph` for compilation and returns the version stamped on it (DW-047).
    @discardableResult func applyGraph(_ graph: EngineGraph) -> UInt64
    func graphStatus() -> GraphStatus
    @discardableResult func waitForGraph(_ version: UInt64, timeout: Duration) -> GraphStatus
    /// ENG-020: `count` contiguous slots.
    func allocateParams(_ count: UInt32) throws(DAWError) -> ParamID
    /// DW-029: reused only once no graph that may read them is rendering.
    func freeParams(_ first: ParamID, count: UInt32)
    /// ENG-023: writes the slot only; no graph is rebuilt.
    func setParam(_ id: ParamID, _ value: Float)
    func getParam(_ id: ParamID) -> Float

    // Transport (TIME-004/009)
    func play()
    func stop()
    func locate(_ tick: Tick)
    func setLoop(enabled: Bool, start: Tick, end: Tick)
    func setRecording(_ recording: Bool)
    func transport() -> TransportState

    // Assets (IO-031)
    func loadAsset(_ assetID: ModelID, path: String) -> JobID
    func pollJob(_ job: JobID) -> EngineJobStatus

    // Recording (09) and plugins (10)
    func armInput(track: NodeIDValue, inputChannelPair: UInt32, armed: Bool)
    func instantiatePlugin(slot: NodeIDValue, _ plugin: PluginDescriptor) -> JobID
    func pluginState(slot: NodeIDValue) -> Data
    func setPluginState(slot: NodeIDValue, _ state: Data)

    // Offline (IO-010..013)
    func renderOffline(from: Tick, to: Tick, spec: ExportSpec) -> JobID

    // Device (04)
    func devices() -> [AudioDeviceInfo]
    func setDevice(_ config: DriverConfig) throws(DAWError)

    // Observability (BRIDGE-004/005)
    func telemetry() -> EngineTelemetry
    func nodeLatencies() -> [NodeLatency]
    /// nil: the node has no meter.
    func meter(_ node: NodeIDValue) -> MeterReading?
    /// Drains up to `max` queued events, oldest first.
    func pollEvents(max: Int) -> [EngineEvent]
    func paramInfoJSON(_ kind: NodeKind) -> String
}

extension EngineProtocol {
    /// Polls (BRIDGE-002) until `job` finishes or `timeout` passes, and returns its last status.
    public func waitForJob(_ job: JobID, timeout: Duration = .seconds(60)) async -> EngineJobStatus {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var status = pollJob(job)
        while !status.state.isFinished && status.state != .unknown && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
            status = pollJob(job)
        }
        return status
    }

    /// Like `waitForGraph`, without blocking a thread: polls until `version` is completed.
    public func graphApplied(_ version: UInt64, timeout: Duration = .seconds(10)) async -> GraphStatus {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while graphStatus().completedVersion < version && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        // Lets the engine finish what follows a build (queued transport commands) at once.
        return waitForGraph(version, timeout: .zero)
    }

    /// Drains every queued event.
    public func pollEvents() -> [EngineEvent] {
        var all: [EngineEvent] = []
        while true {
            let batch = pollEvents(max: 64)
            all += batch
            if batch.count < 64 { return all }
        }
    }
}
