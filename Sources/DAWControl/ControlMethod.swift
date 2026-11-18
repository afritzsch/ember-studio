/// CTL-002: the v1 methods. `dawmcp` exposes each as a tool (CTL-021) whose input is the
/// method's params type in `ControlParams.swift`.
public enum ControlMethod: String, CaseIterable, Hashable, Sendable {
    case projectNew = "project.new"
    case projectOpen = "project.open"
    case projectSave = "project.save"
    case projectGet = "project.get"
    case commandApply = "command.apply"
    case commandBatch = "command.batch"
    case commandSchema = "command.schema"
    case undo
    case redo
    case transportPlay = "transport.play"
    case transportStop = "transport.stop"
    case transportLocate = "transport.locate"
    case transportSetLoop = "transport.setLoop"
    case transportRecord = "transport.record"
    case transportSetPunch = "transport.setPunch"
    case transportSetRecordOptions = "transport.setRecordOptions"  // T-080 (REC-034)
    case transportWait = "transport.wait"
    case transportSetMetronome = "transport.setMetronome"
    case assetImport = "asset.import"
    case renderOffline = "render.offline"
    case renderCancel = "render.cancel"  // T-096 (DW-220)
    case audioAnalyze = "audio.analyze"
    case audioCompare = "audio.compare"
    case engineTelemetry = "engine.telemetry"
    case engineEvents = "engine.events"
    case engineParamInfo = "engine.paramInfo"
    case enginePluginInfo = "engine.pluginInfo"
    case engineMeters = "engine.meters"  // T-096 (DW-174)
    case enginePreviewNote = "engine.previewNote"  // T-096 (DW-189)
    case deviceList = "device.list"
    case deviceSet = "device.set"
    case deviceSimulate = "device.simulate"
    case midiInputs = "midi.inputs"
    case midiInject = "midi.inject"
    case uiState = "ui.state"
    case uiSnapshot = "ui.snapshot"
    case uiPerform = "ui.perform"
    case testFixture = "test.fixture"
    case pluginsScan = "plugins.scan"  // T-098 (DW-016)
    case pluginsList = "plugins.list"
    case pluginsBlocked = "plugins.blocked"
    case pluginsRetry = "plugins.retry"
    case pluginsUnblock = "plugins.unblock"
    case engineParamDisplay = "engine.paramDisplay"  // T-098 (DW-289)

    /// CTL-005: these need the running app (attach mode).
    public var isAttachOnly: Bool {
        switch self {
        case .uiState, .uiSnapshot, .uiPerform: true
        default: false
        }
    }

    /// The params type, for tool schemas (CTL-021). `NoParams` for methods without any.
    public var paramsType: any Decodable.Type {
        switch self {
        case .projectNew: ProjectNewParams.self
        case .projectOpen: ProjectOpenParams.self
        case .projectSave: ProjectSaveParams.self
        case .projectGet: ProjectGetParams.self
        case .commandApply: CommandApplyParams.self
        case .commandBatch: CommandBatchParams.self
        case .commandSchema: CommandSchemaParams.self
        case .undo, .redo, .transportPlay, .transportStop, .engineTelemetry, .uiState, .deviceList, .midiInputs: NoParams.self
        case .transportLocate: TransportLocateParams.self
        case .transportSetLoop: TransportSetLoopParams.self
        case .transportRecord: TransportRecordParams.self
        case .transportSetPunch: TransportSetPunchParams.self
        case .transportSetRecordOptions: TransportSetRecordOptionsParams.self
        case .transportWait: TransportWaitParams.self
        case .transportSetMetronome: TransportSetMetronomeParams.self
        case .assetImport: AssetImportParams.self
        case .renderOffline: RenderOfflineParams.self
        case .renderCancel: RenderCancelParams.self
        case .audioAnalyze: AudioAnalyzeParams.self
        case .audioCompare: AudioCompareParams.self
        case .engineEvents: EngineEventsParams.self
        case .engineParamInfo: EngineParamInfoParams.self
        case .enginePluginInfo: EnginePluginInfoParams.self
        case .engineMeters: EngineMetersParams.self
        case .enginePreviewNote: EnginePreviewNoteParams.self
        case .deviceSet: DeviceSetParams.self
        case .deviceSimulate: DeviceSimulateParams.self
        case .midiInject: MidiInjectParams.self
        case .uiSnapshot: UISnapshotParams.self
        case .uiPerform: UIPerformParams.self
        case .testFixture: TestFixtureParams.self
        case .pluginsScan: PluginsScanParams.self  // T-098
        case .pluginsList, .pluginsBlocked: NoParams.self
        case .pluginsRetry: PluginsRetryParams.self
        case .pluginsUnblock: PluginsUnblockParams.self
        case .engineParamDisplay: EngineParamDisplayParams.self
        }
    }

    /// One line for `dawctl methods` and tool descriptions.
    public var summary: String {
        switch self {
        case .projectNew: "Start a new empty project {name, sampleRate?, engine?} → {projectID}"
        case .projectOpen: "Open a project folder {path, recover?, engine?, safeMode?} → {loadReport, safeMode?}"
        case .projectSave: "Save the project {path?} → {}"
        case .projectGet: "The project JSON, or the subtree at a JSON Pointer {path?}"
        case .commandApply: "Apply one Command {command: {type, …}} → {ok, createdIDs, label}"
        case .commandBatch: "Apply Commands in order {commands, atomic} → {ok, results}"
        case .commandSchema: "Command types and their JSON Schemas {type?} → {commands: [{type, schema}]}"
        case .undo: "Undo the last edit → {label}"
        case .redo: "Redo the last undone edit → {label}"
        case .transportPlay: "Start playback → transport"
        case .transportStop: "Stop playback → transport"
        case .transportLocate: "Move the playhead {tick} → transport"
        case .transportSetLoop: "Set the loop {enabled, start, end} → transport"
        case .transportRecord: "Start or stop recording {enabled} → transport (armed tracks record while it plays; stopping finalizes the takes into clips)"
        case .transportSetPunch: "Set the punch range {enabled, start?, end?} → transport (recording writes only inside it while the loop is off)"
        case .transportSetRecordOptions: "Set record options {midiLoopTakes?} → transport (midiLoopTakes: a MIDI loop recording makes one take per pass; not saved, not undoable)"
        case .transportWait: "Wait for playback to reach a tick or stop {untilTick?, timeoutMs} (live engine only)"
        case .transportSetMetronome: "Switch the project metronome or set its levels {enabled?, level?, accent?} → {enabled, level, accent} (not undoable)"
        case .assetImport: "Load an audio file into the project {path} → {assetID, …}"
        case .renderOffline: "Render ticks [from, to) to a file {from, to, path, format?, sampleFormat?, dither?, normalize?, includeMetronome?} → {path, durationSec, renderTimeSec}"
        case .renderCancel: "Cancel the running render.offline {id?} → {cancelled, id?} (that render fails with cancelled and its file is deleted)"
        case .audioAnalyze: "Levels, loudness, spectrum and first sound of a file {path, range?, fftSize?, bands?}"
        case .audioCompare: "Null-test two files {a, b, toleranceDb?} → {nullResidualDb, maxDiffSample, offsetSamples}"
        case .engineTelemetry: "Engine telemetry, per-node latency and rtViolations"
        case .engineEvents: "Engine events after a cursor {since?} → {events, next}"
        case .engineParamInfo: "Param info of a node kind {kind}"
        case .enginePluginInfo: "A device slot's hosted plugin {slot} → {identifier, loaded, error?, latencySamples, params: [{index, address, name, min, max, value}], …}"
        case .engineMeters: "Strip meters and compressor gain reduction {nodes?} → {meters: [{node, kind, peakDb, rmsDb, gainReductionDb?}]}"
        case .enginePreviewNote: "Audition a note on a MIDI track's instrument {track, pitch, velocity?, durationMs?} (realtime engines; offline → notSupported)"
        case .deviceList: "Audio devices and the running one → {devices, outputDeviceID, driver}"
        case .deviceSet: "Switch the output/input device or rate {outputDevice?, inputDevice?, sampleRate?, bufferFrames?} (realtime engine)"
        case .deviceSimulate: "Make the fake device lose, restore, change rate or overload {kind, deviceID?, sampleRate?} → {outputDeviceID, sampleRate, events}"
        case .midiInputs: "MIDI input sources (REC-010) → {inputs: [{uniqueID, name, connected}]}"
        case .midiInject: "Feed MIDI messages as if from a controller (test seam, realtime engines) {events: [{sample | framesFromNow, status, data1?, data2?, source?}]} → {accepted} (source: a CoreMIDI unique ID from midi.inputs, for a track's MIDI input filter)"
        case .uiState: "UI state dump (attach only)"
        case .uiSnapshot: "Window snapshot as PNG {path?, pluginEditor?: slot} → {pngPath} (attach only)"
        case .uiPerform: "Click or toggle a control {accessibilityId, action} (attach only)"
        case .testFixture: "Build a fixture project from its script {name}"
        case .pluginsScan: "Scan new or changed AU/VST3 plugins out of process {timeoutSeconds?} → {scanned, unchanged, removed, plugins, blocked}"
        case .pluginsList: "Usable plugins in the scan cache → {plugins: [{format, identifier, name, vendor, version, isInstrument, …}], cachePath}"
        case .pluginsBlocked: "Plugins whose scan crashed, hung or failed → {blocked: [{identifier, name, reason, timedOut?, …}], cachePath}"
        case .pluginsRetry: "Scan blocked plugins again {id?, timeoutSeconds?} → {retried, scan, stillBlocked} (timed-out ones get 120 s)"
        case .pluginsUnblock: "Forget blocked plugins so the next plugins.scan tries them again {id?} → {unblocked}"
        case .engineParamDisplay: "A hosted plugin's own display string for a param value {node, param, value?} → {node, param, value, display}"
        }
    }
}
