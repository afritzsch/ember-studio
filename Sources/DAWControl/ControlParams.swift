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
    /// PLUG-021 (T-064): open with every AU/VST3 slot host-bypassed for this session (slots,
    /// params and state kept; the document isn't changed). Default false.
    public var safeMode: Bool?
}

public struct ProjectOpenResult: Codable, Hashable, Sendable {
    /// DW-107: DAWModel's report (offline assets, migration, recovery, repairs).
    public var loadReport: ProjectLoadReport
    /// PLUG-021 (T-064): whether the project runs in safe mode.
    public var safeMode: Bool? = nil
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

/// REC-005 (T-052): the punch range. `enabled: true` needs `start < end`; `enabled: false` keeps
/// the range (or sets it, when given) for later. Not part of the project (transport state).
public struct TransportSetPunchParams: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var start: Tick?
    public var end: Tick?
}

/// REC-034 (T-080): record options, engine state like the punch range (not in the project, not
/// undoable). A field left out keeps its value. `midiLoopTakes`: a MIDI loop recording becomes a
/// take folder with one take per pass instead of one merged clip (default false).
public struct TransportSetRecordOptionsParams: Codable, Hashable, Sendable {
    public var midiLoopTakes: Bool?
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
    /// T-082 (UI-042): scale the export so its sample peak is −0.1 dBFS, before dither and
    /// quantization. Default false.
    public var normalize: Bool?
    /// T-096 (DW-219, IO-035): TPDF dither for int16/int24. Default true for those formats;
    /// ignored for float32 (never dithered).
    public var dither: Bool?
}

/// T-096 (DW-220): `render.cancel {id?}` stops the running `render.offline` (the one with JSON-RPC
/// request id `id`, if given). That request then fails with `cancelled`, and its partial file is
/// deleted.
public struct RenderCancelParams: Codable, Hashable, Sendable {
    /// The `render.offline` request's JSON-RPC id (as in its `progress` notifications). Default:
    /// whichever render is running.
    public var id: RPCID?
}

public struct RenderCancelResult: Codable, Hashable, Sendable {
    /// False: no render was running (or none with that id); nothing changed.
    public var cancelled: Bool
    /// The cancelled `render.offline`'s request id (absent for in-process calls, which have none).
    public var id: RPCID?
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
    /// T-082: with `normalize`, the gain applied (linear; 1 for silence). Absent otherwise.
    public var normalizeGain: Double?
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

/// PLUG-010/015 (T-061): `engine.pluginInfo`. `slot` is the device slot's ID; the result is the
/// engine's `pluginInfoJSON` (param index i of the slot is `params[i]`).
public struct EnginePluginInfoParams: Codable, Hashable, Sendable {
    public var slot: NodeIDValue
}

// MARK: engine.meters, engine.previewNote (T-096)

/// T-096 (DW-174): `engine.meters {nodes?}`.
public struct EngineMetersParams: Codable, Hashable, Sendable {
    /// Model IDs of tracks, buses, the master or compressor device slots. Default: every track,
    /// bus and the master, then every built-in compressor slot.
    public var nodes: [NodeIDValue]?
}

public struct EngineMetersResult: Codable, Hashable, Sendable {
    public struct Meter: Codable, Hashable, Sendable {
        /// The model ID.
        public var node: NodeIDValue
        /// track, bus, master (post-fader strip meters, MIX-005) or compressor (DSP-031).
        public var kind: String
        /// The strip's peak and 300 ms RMS in dBFS (-240: silence). One value: the engine's strip
        /// meter reads L and R together. Empty for a compressor.
        public var peakDb: [Double]
        public var rmsDb: [Double]
        /// Compressors only: the deepest gain reduction of the last block, ≤ 0 dB (makeup not
        /// included); 0 before it has processed audio.
        public var gainReductionDb: Double?
    }

    public var meters: [Meter]
}

/// T-096 (DW-189): `engine.previewNote {track, pitch, velocity?, durationMs?}` auditions a note on
/// a MIDI track's instrument (UI-021's piano-roll keys), realtime engines only.
public struct EnginePreviewNoteParams: Codable, Hashable, Sendable {
    /// A MIDI track's ID.
    public var track: ModelID
    /// 0…127.
    public var pitch: Int
    /// 1…127. Default 100.
    public var velocity: Int?
    /// How long the note is held, 1…60000 ms. Default 500.
    public var durationMs: Int?
}

public struct EnginePreviewNoteResult: Codable, Hashable, Sendable {
    public var track: ModelID
    public var pitch: Int
    public var velocity: Int
    public var durationMs: Int
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

// MARK: midi.* (T-053, REC-010..012)

public struct MidiInputsResult: Codable, Hashable, Sendable {
    public var inputs: [MidiInputInfo]
}

/// REC-010..012 (T-053): `midi.inject`, the test seam that feeds timestamped MIDI as if from a
/// connected source, so MIDI recording can be scripted without hardware.
public struct MidiInjectParams: Codable, Hashable, Sendable {
    public struct Event: Codable, Hashable, Sendable {
        /// Transport sample it is struck at (the note lands at this minus the output latency). Left
        /// out, or the transport stopped: at once, plus `framesFromNow`.
        public var sample: Int64?
        public var framesFromNow: Int64?
        /// A channel message: 0x80…0xEF.
        public var status: UInt8
        public var data1: UInt8?
        public var data2: UInt8?
        /// T-093 (additive): the CoreMIDI unique ID it arrives from, as `midi.inputs` reports it,
        /// so a track's MIDI input filter can be tested. Left out: the plain seam, which only
        /// tracks hearing all sources hear. At most 4 distinct IDs per engine.
        public var source: Int32? = nil
    }
    public var events: [Event]
}

public struct MidiInjectResult: Codable, Hashable, Sendable {
    public var accepted: Int
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
    /// PLUG-017 (T-063, additive): snapshot this device slot's open plugin editor panel instead of
    /// the main window.
    public var pluginEditor: NodeIDValue? = nil
}

public struct UIPerformParams: Codable, Hashable, Sendable {
    public var accessibilityId: String
    public var action: String
    /// UI-016 (T-081, additive): action `swipe` on a take row (`takeFolder.<folder>.take.<take>.swipe`):
    /// the range `[start, end)` in ticks that the take plays in the comp (one undo entry).
    public var start: Int64? = nil
    public var end: Int64? = nil
    /// DW-297 (T-100, additive): action `setText` on a text-field control (the toolbar's
    /// `transport.tempo`, `transport.signature`): the text to commit, as if typed and Return pressed.
    public var text: String? = nil
    /// UI-063/UI-067 (T-124, additive): action `drop` on a browser item (`browser.item.<id>`):
    /// the track to drop it on (absent: the empty area under the tracks, a new track) and the
    /// tick (snapped to the arrange grid, as a drop is).
    public var track: UInt64? = nil
    public var tick: Int64? = nil
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

// MARK: plugins.* (T-098, DW-016)

/// T-098 (DW-016): one plugin of the scan cache (PLUG-004), as `plugins.list`/`plugins.blocked`
/// report it: the scanner's `PluginDescriptorPOD` fields plus its status.
public struct ControlPlugin: Codable, Hashable, Sendable {
    /// `au` or `vst3`.
    public var format: String
    /// AU: `type:subtype:manufacturer`; VST3: `path#classUID`. A blocked VST3 bundle the scanner
    /// couldn't report on: the bundle path. `plugins.retry`/`plugins.unblock` take this as `id`.
    public var identifier: String
    public var name: String
    public var vendor: String
    public var version: String
    public var isInstrument: Bool
    public var hasSidechain: Bool
    public var numParams: UInt32
    /// `ok` or `blocked` (PLUG-001).
    public var status: String
    /// Why it is blocked; absent for a usable plugin.
    public var reason: String?
    /// Blocked because its scan ran out of time (T-094, DW-275); a retry gets a longer limit.
    public var timedOut: Bool?

    public init(format: String, identifier: String, name: String, vendor: String, version: String,
                isInstrument: Bool, hasSidechain: Bool, numParams: UInt32, reason: String? = nil, timedOut: Bool = false) {
        self.format = format
        self.identifier = identifier
        self.name = name
        self.vendor = vendor
        self.version = version
        self.isInstrument = isInstrument
        self.hasSidechain = hasSidechain
        self.numParams = numParams
        status = reason == nil ? "ok" : "blocked"
        self.reason = reason
        self.timedOut = reason != nil && timedOut ? true : nil
    }

    public var isBlocked: Bool { status == "blocked" }
}

/// T-098: what a scan or retry did (`PluginCatalog.RefreshSummary`).
public struct ControlPluginScanSummary: Codable, Hashable, Sendable {
    /// New or changed candidates scanned now.
    public var scanned: Int
    /// Those candidates: AU identifiers or VST3 bundle paths, in scan order (headless only; the
    /// app's plugin manager keeps counts).
    public var scannedCandidates: [String]?
    public var unchanged: Int
    public var removed: Int
    /// Usable and blocked plugins in the cache afterwards.
    public var plugins: Int
    public var blocked: Int
    /// The time limit each scan had, in seconds.
    public var timeoutSeconds: Double?
    /// Why a param was not used (attach mode scans with the app's own limit).
    public var note: String?

    public init(scanned: Int, scannedCandidates: [String]? = nil, unchanged: Int, removed: Int, plugins: Int = 0,
                blocked: Int = 0, timeoutSeconds: Double? = nil, note: String? = nil) {
        self.scanned = scanned
        self.scannedCandidates = scannedCandidates
        self.unchanged = unchanged
        self.removed = removed
        self.plugins = plugins
        self.blocked = blocked
        self.timeoutSeconds = timeoutSeconds
        self.note = note
    }
}

/// T-098 (DW-016): `plugins.scan {timeoutSeconds?}`.
public struct PluginsScanParams: Codable, Hashable, Sendable {
    /// The time limit of each plugin's scan, in seconds (default 30, PLUG-001). Headless only; the
    /// app scans with its own limit.
    public var timeoutSeconds: Double?
}

/// T-098: `plugins.list` → `{plugins, cachePath}` (usable plugins) and `plugins.blocked` →
/// `{blocked, cachePath}`.
public struct PluginsListResult: Codable, Hashable, Sendable {
    public var plugins: [ControlPlugin]?
    public var blocked: [ControlPlugin]?
    /// The `plugins.json` scan cache these come from (PLUG-004).
    public var cachePath: String
}

/// T-098 (DW-016): `plugins.retry {id?, timeoutSeconds?}`.
public struct PluginsRetryParams: Codable, Hashable, Sendable {
    /// A blocked plugin's `identifier` (`plugins.blocked`). Default: every blocked plugin.
    public var id: String?
    /// The retried scans' time limit in seconds. Default: 120 s when a retried plugin timed out
    /// (the plugin manager's "Retry (120 s)", DW-275), else the scanner's 30 s.
    public var timeoutSeconds: Double?
}

/// T-098 (DW-016): `plugins.unblock {id?}`.
public struct PluginsUnblockParams: Codable, Hashable, Sendable {
    /// A blocked plugin's `identifier`. Default: every blocked plugin.
    public var id: String?
}

public struct PluginsRetryResult: Codable, Hashable, Sendable {
    /// The identifiers that were blocked and were scanned again.
    public var retried: [String]
    public var scan: ControlPluginScanSummary
    /// Still blocked afterwards, among the retried ones.
    public var stillBlocked: [ControlPlugin]
}

public struct PluginsUnblockResult: Codable, Hashable, Sendable {
    /// Forgotten from the cache; the next `plugins.scan` scans them again.
    public var unblocked: [String]
}

// MARK: engine.paramDisplay (T-098, DW-289)

/// T-098 (DW-289): `engine.paramDisplay {node, param, value?}`.
public struct EngineParamDisplayParams: Codable, Hashable, Sendable {
    /// The device slot hosting the plugin (as `engine.pluginInfo`'s `slot`).
    public var node: NodeIDValue
    /// The param's `index` in `engine.pluginInfo`'s `params`.
    public var param: Int
    /// VST3: normalized 0…1; AU: in the param's range. Default: the param's current value.
    public var value: Float?
}

public struct EngineParamDisplayResult: Codable, Hashable, Sendable {
    public var node: NodeIDValue
    public var param: Int
    public var value: Float
    /// The plugin's own string, without the unit; "" when it has none (the host formats the number).
    public var display: String
}
