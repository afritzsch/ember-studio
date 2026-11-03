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
    case transportWait = "transport.wait"
    case transportSetMetronome = "transport.setMetronome"
    case assetImport = "asset.import"
    case renderOffline = "render.offline"
    case audioAnalyze = "audio.analyze"
    case audioCompare = "audio.compare"
    case engineTelemetry = "engine.telemetry"
    case engineEvents = "engine.events"
    case engineParamInfo = "engine.paramInfo"
    case deviceList = "device.list"
    case deviceSet = "device.set"
    case deviceSimulate = "device.simulate"
    case uiState = "ui.state"
    case uiSnapshot = "ui.snapshot"
    case uiPerform = "ui.perform"
    case testFixture = "test.fixture"

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
        case .undo, .redo, .transportPlay, .transportStop, .engineTelemetry, .uiState, .deviceList: NoParams.self
        case .transportLocate: TransportLocateParams.self
        case .transportSetLoop: TransportSetLoopParams.self
        case .transportRecord: TransportRecordParams.self
        case .transportWait: TransportWaitParams.self
        case .transportSetMetronome: TransportSetMetronomeParams.self
        case .assetImport: AssetImportParams.self
        case .renderOffline: RenderOfflineParams.self
        case .audioAnalyze: AudioAnalyzeParams.self
        case .audioCompare: AudioCompareParams.self
        case .engineEvents: EngineEventsParams.self
        case .engineParamInfo: EngineParamInfoParams.self
        case .deviceSet: DeviceSetParams.self
        case .deviceSimulate: DeviceSimulateParams.self
        case .uiSnapshot: UISnapshotParams.self
        case .uiPerform: UIPerformParams.self
        case .testFixture: TestFixtureParams.self
        }
    }

    /// One line for `dawctl methods` and tool descriptions.
    public var summary: String {
        switch self {
        case .projectNew: "Start a new empty project {name, sampleRate?, engine?} → {projectID}"
        case .projectOpen: "Open a project folder {path, recover?, engine?} → {loadReport}"
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
        case .transportRecord: "Arm or disarm recording {enabled} → transport"
        case .transportWait: "Wait for playback to reach a tick or stop {untilTick?, timeoutMs} (live engine only)"
        case .transportSetMetronome: "Switch the project metronome or set its levels {enabled?, level?, accent?} → {enabled, level, accent} (not undoable)"
        case .assetImport: "Load an audio file into the project {path} → {assetID, …}"
        case .renderOffline: "Render ticks [from, to) to a file {from, to, path, format?, includeMetronome?} → {path, durationSec, renderTimeSec}"
        case .audioAnalyze: "Levels, loudness, spectrum and first sound of a file {path, range?, fftSize?, bands?}"
        case .audioCompare: "Null-test two files {a, b, toleranceDb?} → {nullResidualDb, maxDiffSample, offsetSamples}"
        case .engineTelemetry: "Engine telemetry, per-node latency and rtViolations"
        case .engineEvents: "Engine events after a cursor {since?} → {events, next}"
        case .engineParamInfo: "Param info of a node kind {kind}"
        case .deviceList: "Audio devices and the running one → {devices, outputDeviceID, driver}"
        case .deviceSet: "Switch the output/input device or rate {outputDevice?, inputDevice?, sampleRate?, bufferFrames?} (realtime engine)"
        case .deviceSimulate: "Make the fake device lose, restore, change rate or overload {kind, deviceID?, sampleRate?} → {outputDeviceID, sampleRate, events}"
        case .uiState: "UI state dump (attach only)"
        case .uiSnapshot: "Window snapshot as PNG {path?} → {pngPath} (attach only)"
        case .uiPerform: "Click or toggle a control {accessibilityId, action} (attach only)"
        case .testFixture: "Build a fixture project from its script {name}"
        }
    }
}
