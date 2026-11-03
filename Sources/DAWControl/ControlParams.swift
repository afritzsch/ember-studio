import DAWModel
import Foundation

// CTL-002: params and results of each method. Params decode from the request's `params` object
// (missing optionals take the documented default); results encode as the response's `result`.
// Paths may be relative; they resolve against the dispatcher's working directory.

public struct NoParams: Codable, Hashable, Sendable {
    public init() {}
}

public struct EmptyResult: Codable, Hashable, Sendable {
    public init() {}
}

// MARK: project.*

public struct ProjectNewParams: Codable, Hashable, Sendable {
    public var name: String
    /// Default 48000.
    public var sampleRate: Double?
    /// Default: offline (deterministic, CTL-004).
    public var engine: EngineParams?

    public init(name: String, sampleRate: Double? = nil, engine: EngineParams? = nil) {
        self.name = name
        self.sampleRate = sampleRate
        self.engine = engine
    }
}

/// DW-115: the engine a new or opened project runs on.
public struct EngineParams: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Hashable, Sendable, CaseIterable {
        /// Renders only through `render.offline`; deterministic (CTL-004).
        case offline
        /// A device driver renders in real time (`transport.wait`, `device.*`).
        case realtime
    }

    /// Default offline.
    public var mode: Mode?
    /// Realtime only. Default `fake`: the made-up devices `device.simulate` drives (T-051), so a
    /// headless tool never plays through the speakers unless asked to.
    public var driver: DeviceDriverKind?
    /// Realtime only: `AudioDeviceInfo.id`; default 0, the default output.
    public var outputDevice: UInt32?
    /// Realtime only, 32…2048. Default 256.
    public var bufferFrames: UInt32?

    public init(mode: Mode? = nil, driver: DeviceDriverKind? = nil, outputDevice: UInt32? = nil, bufferFrames: UInt32? = nil) {
        self.mode = mode
        self.driver = driver
        self.outputDevice = outputDevice
        self.bufferFrames = bufferFrames
    }
}

public struct ProjectNewResult: Codable, Hashable, Sendable {
    public var projectID: UUID
}

public struct ProjectOpenParams: Codable, Hashable, Sendable {
    /// The `Name.dawproject` folder (MODEL-040).
    public var path: String
    /// MODEL-045: open the autosave instead if it is newer. Default false.
    public var recover: Bool?
    /// Default: offline.
    public var engine: EngineParams?
}

public struct ProjectOpenResult: Codable, Hashable, Sendable {
    /// DW-107: DAWModel's report (offline assets, migration, recovery, repairs).
    public var loadReport: ProjectLoadReport
}

public struct ProjectSaveParams: Codable, Hashable, Sendable {
    /// Default: where the project was opened from or last saved.
    public var path: String?
}

public struct ProjectGetParams: Codable, Hashable, Sendable {
    /// RFC 6901 JSON Pointer into the project JSON, e.g. "/tracks/0/name". Default: everything.
    public var path: String?
}

// MARK: command.*, undo, redo

public struct CommandApplyParams: Codable, Hashable, Sendable {
    /// `{"type": …, …}` (MODEL-006).
    public var command: JSONValue
}

public struct CommandResult: Codable, Hashable, Sendable {
    public var ok: Bool
    /// IDs of the entities the command added, ascending.
    public var createdIDs: [ModelID]
    /// The undo label.
    public var label: String
}

public struct CommandBatchParams: Codable, Hashable, Sendable {
    public var commands: [JSONValue]
    /// True: all or nothing, one undo entry. False (default): one undo entry each, stopping at
    /// the first failure; the ones before it stay applied and are listed in the error's
    /// `data.results`.
    public var atomic: Bool?
}

public struct CommandBatchResult: Codable, Hashable, Sendable {
    public var ok: Bool
    public var results: [CommandResult]
}

/// CTL-024.
public struct CommandSchemaParams: Codable, Hashable, Sendable {
    /// Just this command type. Default: every registered one.
    public var type: String?

    public init(type: String? = nil) { self.type = type }
}

public struct CommandSchemaResult: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        /// The `type` string `command.apply` takes.
        public var type: String
        /// JSON Schema of the command's wire form, `type` included.
        public var schema: JSONValue
    }

    /// Sorted by `type`.
    public var commands: [Entry]
}

public struct HistoryResult: Codable, Hashable, Sendable {
    /// What was undone or redone; null if there was nothing.
    public var label: String?

    private enum CodingKeys: String, CodingKey { case label }

    public init(label: String?) { self.label = label }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
    }
}

// MARK: transport.*

public struct TransportLocateParams: Codable, Hashable, Sendable {
    public var tick: Tick
}

/// DW-123: also performs `SetLoop`, so the project's loop follows (one undo entry).
public struct TransportSetLoopParams: Codable, Hashable, Sendable {
    public var enabled: Bool
    /// Required when enabled. Leaving out both with `enabled: false` clears the loop (`loop: null`).
    public var start: Tick?
    public var end: Tick?
}

public struct TransportRecordParams: Codable, Hashable, Sendable {
    public var enabled: Bool
}

/// T-026 (TIME-010): performs `SetMetronome` (outside undo history). Fields left out keep their
/// value; at least one is needed.
public struct TransportSetMetronomeParams: Codable, Hashable, Sendable {
    public var enabled: Bool?
    /// Linear amplitude of a beat click, 0…3.98 (+12 dB). Default 0.25.
    public var level: Float?
    /// Linear gain of the downbeat over `level`, 0…3.98. Default 2.
    public var accent: Float?
}

public struct TransportWaitParams: Codable, Hashable, Sendable {
    /// Wait until the playhead is at or past this tick. Default: until playback stops.
    public var untilTick: Tick?
    public var timeoutMs: Int
}

// MARK: asset.import

public struct AssetImportParams: Codable, Hashable, Sendable {
    public var path: String
}

public struct AssetImportResult: Codable, Hashable, Sendable {
    public var assetID: ModelID
    public var channels: UInt32
    /// At the file's own rate.
    public var frames: Int64
    public var fileSampleRate: Double
    /// D-27: converted to the session rate in RAM.
    public var resampled: Bool
}

// MARK: render.offline

public struct RenderOfflineParams: Codable, Hashable, Sendable {
    public var from: Tick
    public var to: Tick
    public var path: String
    /// wav (default), caf or aiff.
    public var format: ExportSpec.FileType?
    /// float32 (default), int24 or int16 (TPDF-dithered, IO-035).
    public var sampleFormat: ExportSpec.SampleFormat?
    /// IO-012: keep rendering past `to` until the output is quiet. Default true.
    public var tail: Bool?
    /// IO-010, 1…4096. Default 512.
    public var blockSize: UInt32?
    /// T-036: follow the transport's loop (wrap at its end, as live playback does) instead of
    /// playing the range straight through. Default false.
    public var loop: Bool?
    /// T-026 (docs/autobuild/DECISIONS.md Q1): include the project metronome's click when it is
    /// on. Default false: exports leave the click out.
    public var includeMetronome: Bool?
}

public struct RenderOfflineResult: Codable, Hashable, Sendable {
    /// Absolute.
    public var path: String
    public var durationSec: Double
    public var renderTimeSec: Double
    public var sampleRate: Double
    public var frames: Int64
    /// IO-013: the render thread's own RT trap count. Must be 0.
    public var rtViolations: UInt64
    public var clippedSamples: UInt64
}

// MARK: audio.*

public struct AudioAnalyzeParams: Codable, Hashable, Sendable {
    public var path: String
    /// Frames [start, end) of the file. Default: all of it.
    public var range: FrameRange?
    /// Power of two, 64…65536. Default 4096.
    public var fftSize: Int?
    /// Number of log-spaced spectrum bands from 20 Hz to Nyquist. Default 32.
    public var bands: Int?
    /// A sample counts as sound above this level. Default -120 dBFS.
    public var silenceThresholdDb: Double?
}

public struct FrameRange: Codable, Hashable, Sendable {
    public var start: Int64
    public var end: Int64

    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }
}

public struct AudioCompareParams: Codable, Hashable, Sendable {
    public var a: String
    public var b: String
    /// `pass` is `nullResidualDb <= toleranceDb`. Default -100 (TEST-002).
    public var toleranceDb: Double?
    /// The cross-correlation searches offsets up to this many frames. Default: one second.
    public var maxOffset: Int64?
}

// MARK: engine.*

public struct EngineEventsParams: Codable, Hashable, Sendable {
    /// Only events with a larger `seq`. Default 0: every event still kept.
    public var since: UInt64?
}

public struct EngineEventRecord: Codable, Hashable, Sendable {
    /// Increases by one per event, across projects.
    public var seq: UInt64
    public var event: EngineEvent
}

public struct EngineEventsResult: Codable, Hashable, Sendable {
    public var events: [EngineEventRecord]
    /// Pass as `since` next time.
    public var next: UInt64
}

public struct EngineParamInfoParams: Codable, Hashable, Sendable {
    public var kind: NodeKind
}

// MARK: device.* (DW-115)

public struct DeviceListResult: Codable, Hashable, Sendable {
    public var devices: [AudioDeviceInfo]
    /// The running output (`AudioDeviceInfo.id`); 0 while stopped.
    public var outputDeviceID: UInt32
    /// The engine's driver; nil for an offline engine.
    public var driver: DeviceDriverKind?
}

/// `setDevice` (IO-003/004). The driver kind is the engine's; it can't change.
public struct DeviceSetParams: Codable, Hashable, Sendable {
    /// `AudioDeviceInfo.id`; default 0, the default output.
    public var outputDevice: UInt32?
    /// Default 0, the default input.
    public var inputDevice: UInt32?
    /// Default 0: keep the session rate if the device runs it. Another rate becomes the session
    /// rate (DW-079).
    public var sampleRate: Double?
    /// 32…2048. Default: the current one.
    public var bufferFrames: UInt32?
}

/// `simulateDeviceEvent` (fake driver only).
public struct DeviceSimulateParams: Codable, Hashable, Sendable {
    public var kind: DeviceEvent.Kind
    /// Default 0: the running device.
    public var deviceID: UInt32?
    /// `sampleRateChanged`: a rate the device supports.
    public var sampleRate: Double?
}

/// After `device.set` / `device.simulate`: where the engine ended up, and the events it raised.
public struct DeviceStateResult: Codable, Hashable, Sendable {
    /// 0: none running.
    public var outputDeviceID: UInt32
    public var deviceRunning: Bool
    /// The engine's session rate now (it moves when a device can't run the old one).
    public var sampleRate: Double
    /// The engine events the call raised (`deviceChanged`, …), also kept for `engine.events`.
    public var events: [EngineEventRecord]
}

// MARK: ui.* (attach only, CTL-005)

public struct UISnapshotParams: Codable, Hashable, Sendable {
    public var path: String?
}

public struct UIPerformParams: Codable, Hashable, Sendable {
    public var accessibilityId: String
    public var action: String
}

// MARK: test.fixture

public struct TestFixtureParams: Codable, Hashable, Sendable {
    /// `<name>.jsonl` in the fixture folders (letters, digits, `_` and `-`).
    public var name: String
}

public struct TestFixtureResult: Codable, Hashable, Sendable {
    public var name: String
    public var path: String
    /// Script requests that ran.
    public var requests: Int
    /// Requests left out because they don't build the project (renders, analysis).
    public var skipped: Int
}
