import Foundation

// 08-bridge-facade BRIDGE-007: what DAWModel, DAWControl and the app know about the engine.
// `EngineClient` implements it over the C++ facade; `FakeEngine` implements it for model tests.
// Every type here is plain Swift, so nothing outside EngineClient.swift imports DAWEngine.

/// Index of a param slot (ENG-020), `daw::ParamID`.
public typealias ParamID = UInt32
/// A long-running engine operation (BRIDGE-002), `daw::JobID`. 0 means the request was
/// rejected before a job was created.
public typealias JobID = UInt64

/// T-051, DW-089 (`daw::DeviceDriverKind`): the device driver a realtime engine runs, fixed when it
/// is created. `fake` plays two made-up devices in real time: 1 "Fake Device A" (44.1/48/88.2/96
/// kHz, nominal 48 kHz) and 2 "Fake Device B" (44.1 kHz only); `simulateDeviceEvent` drives them.
public enum DeviceDriverKind: String, Hashable, Sendable, Codable {
    case coreAudio, fake
}

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
    /// Realtime mode only; `setDevice` can't change it.
    public var driver: DeviceDriverKind

    public init(outputDevice: UInt32 = 0, inputDevice: UInt32 = 0, sampleRate: Double = 0,
                bufferFrames: UInt32 = 256, outputChannels: UInt32 = 2, inputChannels: UInt32 = 2,
                driver: DeviceDriverKind = .coreAudio) {
        self.outputDevice = outputDevice
        self.inputDevice = inputDevice
        self.sampleRate = sampleRate
        self.bufferFrames = bufferFrames
        self.outputChannels = outputChannels
        self.inputChannels = inputChannels
        self.driver = driver
    }

    private enum CodingKeys: String, CodingKey {
        case outputDevice, inputDevice, sampleRate, bufferFrames, outputChannels, inputChannels, driver
    }

    /// `driver` is optional in JSON written before T-051 (it means CoreAudio).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(outputDevice: try c.decode(UInt32.self, forKey: .outputDevice),
                  inputDevice: try c.decode(UInt32.self, forKey: .inputDevice),
                  sampleRate: try c.decode(Double.self, forKey: .sampleRate),
                  bufferFrames: try c.decode(UInt32.self, forKey: .bufferFrames),
                  outputChannels: try c.decode(UInt32.self, forKey: .outputChannels),
                  inputChannels: try c.decode(UInt32.self, forKey: .inputChannels),
                  driver: try c.decodeIfPresent(DeviceDriverKind.self, forKey: .driver) ?? .coreAudio)
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
        /// PLUG-018 (T-064): the node's host-side bypass slot (`NodeDesc::bypassParam`); nil for
        /// none. A device slot always has one, so bypassing it is a slot write, not a rebuild.
        public var bypassParam: ParamID?

        public init(id: NodeIDValue, kind: NodeKind, configVersion: UInt32 = 0, firstParam: ParamID = 0,
                    numParams: UInt32 = 0, configJSON: String = "", bypassParam: ParamID? = nil) {
            self.id = id
            self.kind = kind
            self.configVersion = configVersion
            self.firstParam = firstParam
            self.numParams = numParams
            self.configJSON = configJSON
            self.bypassParam = bypassParam
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
    /// REC-005 (T-052): the punch range (`setPunch`); recording writes only inside it while the
    /// loop is off.
    public var punchEnabled: Bool = false
    public var punchIn: Tick = Tick(0)
    public var punchOut: Tick = Tick(0)

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
    /// T-051: the output device running (`AudioDeviceInfo.id`; 0 while stopped).
    public var outputDeviceID: UInt32 = 0
    /// IO-023: `xruns` by source (DW-068): device overload notifications and render overruns.
    public var processorOverloads: UInt64 = 0
    public var renderOverruns: UInt64 = 0
    /// IO-033 (T-056): assets of a running session-rate re-conversion still to come; 0 when none
    /// runs. `play` is refused until then.
    public var assetsReloadPending: UInt32 = 0
    /// REC-002 (T-052): frames dropped because a recording FIFO was full (the disk didn't keep up).
    public var recordDrops: UInt64 = 0
    /// REC-003 (T-052): the running device's input latency in samples (0 without input).
    public var deviceInputLatency: UInt32 = 0
    /// REC-001 (T-052): tracks armed for recording (`armInput`).
    public var armedTracks: UInt32 = 0
    /// DSP-040 (T-070, DW-142): blocks the built-in effects' NaN guards silenced.
    public var nanBlocks: UInt64 = 0
    /// REC-010/011 (T-053): MIDI input events dropped (a full queue or a full record buffer) and
    /// the tracks armed for MIDI input.
    public var midiInputDrops: UInt64 = 0
    public var armedMidiTracks: UInt32 = 0

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

/// IO-021 (7), T-051 (`daw::DeviceChangePOD`): what a `deviceChanged` event changed, for a toast.
public struct DeviceChange: Hashable, Sendable, Codable {
    public enum Reason: String, Hashable, Sendable, Codable {
        /// The running device went away; the engine fell back to the system default (D-26).
        case deviceLost
        /// Its nominal rate moved off the session rate; it restarted.
        case sampleRateChanged
        /// Following the system default, which moved.
        case defaultOutputChanged
        /// Nothing was running and a device appeared.
        case deviceAvailable
        /// A start the engine made itself failed (at creation, after an export, arming input).
        case startFailed
    }

    public var reason: Reason
    /// Output `AudioDeviceInfo.id` before (0: none was running) and now (0: none; see the
    /// event's `error`).
    public var previousDeviceID: UInt32
    public var deviceID: UInt32
    /// The session rate before and after; they differ when the new device can't run the old one,
    /// and the engine rebuilt the graph at the new rate.
    public var previousSampleRate: Double
    public var sampleRate: Double

    public init(reason: Reason, previousDeviceID: UInt32 = 0, deviceID: UInt32 = 0,
                previousSampleRate: Double = 0, sampleRate: Double = 0) {
        self.reason = reason
        self.previousDeviceID = previousDeviceID
        self.deviceID = deviceID
        self.previousSampleRate = previousSampleRate
        self.sampleRate = sampleRate
    }
}

/// DW-089 (`daw::DeviceEventPOD`): what `simulateDeviceEvent` makes the fake device do.
public struct DeviceEvent: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case deviceLost, deviceRestored, sampleRateChanged, processorOverload
    }

    public var kind: Kind
    /// 0: the device running (stopped: the default output).
    public var deviceID: UInt32
    /// `sampleRateChanged`: a rate the device supports.
    public var sampleRate: Double

    public init(_ kind: Kind, deviceID: UInt32 = 0, sampleRate: Double = 0) {
        self.kind = kind
        self.deviceID = deviceID
        self.sampleRate = sampleRate
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
        /// PLUG-022 (T-064): `subject` is the device slot whose plugin output NaN/inf; its output
        /// was silenced (telemetry `nanBlocks`). Once per node instance.
        case pluginMisbehaved
    }

    public var kind: Kind
    public var subject: UInt64
    public var job: JobID
    /// `overload`: the total xrun count.
    public var count: UInt64
    /// `deviceChanged`: the device still isn't running when set.
    public var error: DAWError?
    /// `deviceChanged` (T-051).
    public var device: DeviceChange?
    /// `assetsReloaded` (T-056, IO-033): where the session-rate change's re-conversion is.
    public var reload: AssetsReload? = nil
    /// `recordingFinalized` (T-052, REC-004): the take; `subject` is its track.
    public var recording: RecordedTake? = nil

    public init(kind: Kind, subject: UInt64 = 0, job: JobID = 0, count: UInt64 = 0, error: DAWError? = nil,
                device: DeviceChange? = nil) {
        self.kind = kind
        self.subject = subject
        self.job = job
        self.count = count
        self.error = error
        self.device = device
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

// MARK: Peaks (IO-034, UI-011)

/// One level of a loaded asset's peak mipmap (`daw::PeakLevelPOD`, autobuild decision, see
/// DECISIONS.md): min/max pairs over blocks of `blockSize` frames, at the asset's rate in RAM.
/// The arrange canvas draws waveforms from it, choosing the level by pixels per sample.
public struct PeakLevel: Hashable, Sendable {
    /// Frames per block at each level, finest first (IO-034, `PeakMipmap::kBlockSizes`).
    public static let blockSizes: [Int] = [256, 1024, 4096, 16384]

    public var assetID: ModelID
    public var channels: Int
    public var sampleRate: Double
    public var frames: Int64
    public var blockSize: Int
    public var blockCount: Int
    /// Channel-major pairs: `[(c × blockCount + b) × 2]` is the min, the next float the max.
    public var minMax: [Float]

    public init(assetID: ModelID, channels: Int, sampleRate: Double, frames: Int64, blockSize: Int, blockCount: Int,
                minMax: [Float]) {
        self.assetID = assetID
        self.channels = channels
        self.sampleRate = sampleRate
        self.frames = frames
        self.blockSize = blockSize
        self.blockCount = blockCount
        self.minMax = minMax
    }

    /// The (min, max) of block `block` in `channel`.
    public func peak(channel: Int, block: Int) -> (min: Float, max: Float) {
        let i = (channel * blockCount + block) * 2
        return (minMax[i], minMax[i + 1])
    }
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
    /// T-082: the rendered sample peak (linear, before normalizing) and the gain `normalize`
    /// applied (1 without it).
    public var peak: Double = 0
    public var normalizeGain: Double = 1

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
    /// T-036: keep the transport's loop and wrap at its end; false (the default) plays the range
    /// straight through with the loop off (`daw::ExportSpecPOD::followLoop`).
    public var followLoop = false
    /// T-082 (UI-042): scale the export so its sample peak is −0.1 dBFS, before dither and
    /// quantization (`daw::ExportSpecPOD::normalize`). Off by default.
    public var normalize = false

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
    /// REC-005 (T-052): see the extension at the end of this file (default: ignored).
    func setPunch(enabled: Bool, start: Tick, end: Tick)
    /// UI-021 (T-043): auditions `pitch` on `track`'s instrument (a MIDI track's sampler or plugin),
    /// whether the transport plays or not. Every note-on needs its note-off; `stop` and `locate`
    /// end any still on. Non-RT; queued lock-free for the audio thread.
    func previewNote(track: ModelID, pitch: UInt8, velocity: UInt8, on: Bool)

    // Assets (IO-031)
    func loadAsset(_ assetID: ModelID, path: String) -> JobID
    /// DW-077 (T-056): see the extension at the end of this file (default: no peak cache).
    func loadAsset(_ assetID: ModelID, path: String, peakCacheDirectory: String) -> JobID
    func pollJob(_ job: JobID) -> EngineJobStatus
    /// IO-034 / UI-011: `level` (an index into `PeakLevel.blockSizes`) of the asset's peaks; nil
    /// until it has loaded. Read-only, non-RT; copies the level, so callers cache it.
    func peaks(_ assetID: ModelID, level: Int) -> PeakLevel?

    // Recording (09) and plugins (10)
    func armInput(track: NodeIDValue, inputChannelPair: UInt32, armed: Bool)
    /// REC-002 (T-052): see the extension at the end of this file (default: ignored).
    func setRecordingDirectory(_ path: String)
    /// REC-011 (T-053): arms or disarms MIDI track `track` for live input (see the extension at
    /// the end of this file; default: ignored).
    func armMidiInput(track: NodeIDValue, armed: Bool)
    /// REC-010 (T-053): the MIDI sources CoreMIDI knows (default: none).
    func midiInputs() -> [MidiInputInfo]
    /// T-053 test seam (default: unsupported).
    func injectMidi(atSample: Int64, relativeToNow: Bool, status: UInt8, data1: UInt8, data2: UInt8) throws(DAWError)
    func instantiatePlugin(slot: NodeIDValue, _ plugin: PluginDescriptor) -> JobID
    func pluginState(slot: NodeIDValue) -> Data
    func setPluginState(slot: NodeIDValue, _ state: Data)
    /// PLUG-010/015 (T-061): see the extension at the end of this file (default: "").
    func pluginInfoJSON(slot: NodeIDValue) -> String

    // Offline (IO-010..013)
    func renderOffline(from: Tick, to: Tick, spec: ExportSpec) -> JobID

    // Device (04)
    func devices() -> [AudioDeviceInfo]
    /// DW-079: a `sampleRate` other than the session rate makes it the session rate (the graph is
    /// rebuilt at it); 0 keeps the session rate if the device supports it.
    func setDevice(_ config: DriverConfig) throws(DAWError)
    /// DW-089: plays `event` on the fake device; returns once the engine has reacted (IO-021;
    /// see the `deviceChanged` event). Throws unless the engine runs `DeviceDriverKind.fake`.
    func simulateDeviceEvent(_ event: DeviceEvent) throws(DAWError)
    /// T-056 (IO-033, MODEL-005): see the extension at the end of this file (default: refused).
    func setSessionSampleRate(_ rate: Double) throws(DAWError)

    // Observability (BRIDGE-004/005)
    func telemetry() -> EngineTelemetry
    func nodeLatencies() -> [NodeLatency]
    /// nil: the node has no meter.
    func meter(_ node: NodeIDValue) -> MeterReading?
    /// Drains up to `max` queued events, oldest first.
    func pollEvents(max: Int) -> [EngineEvent]
    func paramInfoJSON(_ kind: NodeKind) -> String
}

// MARK: T-043 (UI-021)

extension EngineProtocol {
    /// Engines that can't audition (test doubles) ignore preview notes.
    public func previewNote(track: ModelID, pitch: UInt8, velocity: UInt8, on: Bool) {}
}

extension EngineProtocol {
    /// Engines without peaks (test doubles) report none; the canvas then draws clips without waveforms.
    public func peaks(_ assetID: ModelID, level: Int) -> PeakLevel? { nil }

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

// MARK: Session sample rate (T-056: IO-033, MODEL-005 SetSessionSampleRate, DW-044, DW-077, DW-130)

/// IO-033, DW-044 (`daw::AssetsReloadPOD`): an `assetsReloaded` event's place in a session-rate
/// change. Every change of the engine's session rate (`setSessionSampleRate`, `setDevice`, a
/// device fallback) raises `started`, one `progress` per asset re-converted from its original file,
/// and `finished` once the new assets play through a new graph (its `error` set if some failed).
/// With nothing loaded, `finished` follows `started` at once. Playback stays stopped in between.
public struct AssetsReload: Hashable, Sendable, Codable {
    public enum Phase: String, Hashable, Sendable, Codable {
        case started, progress, finished
    }

    public var phase: Phase
    /// The session rate before the change, and after it (what the assets are converted to).
    public var previousSampleRate: Double
    public var sampleRate: Double
    /// Assets converted (or failed) so far, of `total`.
    public var done: UInt32
    public var total: UInt32
    /// Assets that didn't load again; they are dropped and their clips are silent.
    public var failed: UInt32
    /// `progress`: the asset just done.
    public var assetID: ModelID

    public init(phase: Phase, previousSampleRate: Double, sampleRate: Double, done: UInt32 = 0, total: UInt32 = 0,
                failed: UInt32 = 0, assetID: ModelID = 0) {
        self.phase = phase
        self.previousSampleRate = previousSampleRate
        self.sampleRate = sampleRate
        self.done = done
        self.total = total
        self.failed = failed
        self.assetID = assetID
    }

    /// The fraction done, 0…1 (1 when there is nothing to convert).
    public var fraction: Double { total == 0 ? 1 : Double(done) / Double(total) }
}

extension EngineEvent {
    /// An event with `reload` (T-056).
    public init(kind: Kind, subject: UInt64 = 0, job: JobID = 0, count: UInt64 = 0, error: DAWError? = nil,
                device: DeviceChange? = nil, reload: AssetsReload?) {
        self.init(kind: kind, subject: subject, job: job, count: count, error: error, device: device)
        self.reload = reload
    }
}

/// T-056 additions to `EngineProtocol`, with defaults so test doubles compile unchanged.
extension EngineProtocol {
    /// MODEL-005 `SetSessionSampleRate`, IO-033: makes `rate` (44.1/48/88.2/96 kHz) the session
    /// rate. The transport stops, the graph is rebuilt at the rate and every loaded asset is
    /// re-converted in the background (`assetsReloaded` events). A realtime engine restarts its
    /// device at it and throws `notImplemented` (changing nothing) if the device can't run it.
    /// Engines that can't change rate throw `notImplemented`.
    public func setSessionSampleRate(_ rate: Double) throws(DAWError) {
        throw .notImplemented("this engine can't change the session sample rate")
    }

    /// DW-077: `loadAsset`, with IO-034's peaks read from (or written to) the cache file
    /// `<peakCacheDirectory>/<assetID>.peaks`. Engines without a peak cache just load.
    public func loadAsset(_ assetID: ModelID, path: String, peakCacheDirectory: String) -> JobID {
        loadAsset(assetID, path: path)
    }
}

/// T-061 additions to `EngineProtocol`, with defaults so test doubles compile unchanged.
extension EngineProtocol {
    /// PLUG-010/015: what the slot's hosted plugin is, as the engine's JSON
    /// (`EngineFacade::pluginInfoJSON`): identifier, whether it loaded (and why not), buses,
    /// latency and its parameters in slot order (param index i of the slot drives `params[i]`).
    /// Engines without plugin hosting return "".
    public func pluginInfoJSON(slot: NodeIDValue) -> String { "" }
}

// MARK: T-052 (REC-001..005): recording

/// REC-004 (`daw::RecordingPOD`): a finished take, from a `recordingFinalized` event. `startSample`
/// is where the file's first frame belongs on the timeline, at the session rate, already
/// compensated for input + output latency (REC-003); it may be negative. With `error` set on the
/// event and `frames` > 0 the file is still usable (e.g. REC-002 drops, filled with silence); an
/// empty `file` means nothing could be written.
public struct RecordedTake: Hashable, Sendable, Codable {
    public var track: NodeIDValue
    /// Absolute path of the 32-bit float CAF.
    public var file: String
    public var startSample: SamplePos
    public var frames: Int64
    /// REC-030 (T-080): 0 until loop takes exist.
    public var takeIndex: UInt32
    public var channels: UInt32
    public var sampleRate: Double
    /// Input channels 2·inputPair and 2·inputPair + 1.
    public var inputPair: UInt32
    public var droppedFrames: UInt64
    /// REC-012 (T-053): a MIDI take (`file` empty, `frames` 0): the compensated stop and the
    /// notes in timeline samples. nil on an audio take.
    public var endSample: SamplePos?
    public var notes: [RecordedMidiNote]?

    /// A MIDI take (T-053).
    public var isMidi: Bool { notes != nil }

    public init(track: NodeIDValue, file: String, startSample: SamplePos, frames: Int64, takeIndex: UInt32 = 0,
                channels: UInt32 = 2, sampleRate: Double, inputPair: UInt32 = 0, droppedFrames: UInt64 = 0,
                endSample: SamplePos? = nil, notes: [RecordedMidiNote]? = nil) {
        self.track = track
        self.file = file
        self.startSample = startSample
        self.frames = frames
        self.takeIndex = takeIndex
        self.channels = channels
        self.sampleRate = sampleRate
        self.inputPair = inputPair
        self.droppedFrames = droppedFrames
        self.endSample = endSample
        self.notes = notes
    }
}

extension EngineEvent {
    /// A `recordingFinalized` event (T-052).
    public init(recording: RecordedTake, error: DAWError? = nil) {
        self.init(kind: .recordingFinalized, subject: recording.track, count: recording.droppedFrames, error: error)
        self.recording = recording
    }
}

/// T-052 additions to `EngineProtocol`, with defaults so test doubles compile unchanged.
extension EngineProtocol {
    /// REC-005: with `enabled` and the loop off, recording writes only [start, end) of the
    /// timeline. Engines without recording ignore it.
    public func setPunch(enabled: Bool, start: Tick, end: Tick) {}
    /// REC-002: where recordings are written (created when needed); "" is the engine's own
    /// per-process temporary folder. Engines without recording ignore it.
    public func setRecordingDirectory(_ path: String) {}
}

// MARK: T-053 (REC-010..012): MIDI input

/// REC-012: one note of a MIDI take, in timeline samples (latency-compensated).
public struct RecordedMidiNote: Hashable, Sendable, Codable {
    public var start: SamplePos
    public var end: SamplePos
    public var pitch: UInt8
    public var velocity: UInt8
    public var channel: UInt8

    public init(start: SamplePos, end: SamplePos, pitch: UInt8, velocity: UInt8 = 100, channel: UInt8 = 0) {
        self.start = start
        self.end = end
        self.pitch = pitch
        self.velocity = velocity
        self.channel = channel
    }
}

/// REC-010: a MIDI input source.
public struct MidiInputInfo: Hashable, Sendable, Codable {
    public var uniqueID: Int32
    public var name: String
    public var connected: Bool

    public init(uniqueID: Int32, name: String, connected: Bool = true) {
        self.uniqueID = uniqueID
        self.name = name
        self.connected = connected
    }
}

/// T-053 additions to `EngineProtocol`, with defaults so test doubles compile unchanged.
extension EngineProtocol {
    public func armMidiInput(track: NodeIDValue, armed: Bool) {}
    public func midiInputs() -> [MidiInputInfo] { [] }
    public func injectMidi(atSample: Int64, relativeToNow: Bool, status: UInt8, data1: UInt8, data2: UInt8) throws(DAWError) {
        throw .notImplemented("this engine has no MIDI input")
    }
}
