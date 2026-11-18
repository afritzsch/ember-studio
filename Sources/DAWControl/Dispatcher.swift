import DAWModel
import Foundation

/// CTL-001: runs control requests against a `ProjectStore` and the engine attached to it. One
/// dispatcher serves every transport: `dawctl` and `dawmcp` own one in headless mode (offline
/// engine, in-process), the app owns one in attach mode behind its socket (T-032).
///
/// Requests run one at a time, in arrival order, on the main actor (CTL-031). Engine events are
/// drained through `EngineSync.pollEvents()` before each request and after each wait (DW-095),
/// so asset loads reach the clip players (DW-072) and `engine.events` sees them.
@MainActor
public final class Dispatcher {
    public enum Mode: Hashable, Sendable {
        /// In-process, no UI; `ui.*` aren't available (CTL-005).
        case headless
        /// Inside the running app.
        case attach
    }

    /// Creates the engine for a new or opened project at its session rate.
    public typealias EngineFactory = @MainActor (_ sampleRate: Double) throws(DAWError) -> any EngineProtocol
    /// Creates a realtime engine (`project.new`/`project.open` with `engine.mode` realtime, DW-115).
    public typealias RealtimeEngineFactory = @MainActor (_ config: DriverConfig) throws(DAWError) -> any EngineProtocol

    public struct Configuration {
        public var mode: Mode
        public var makeEngine: EngineFactory
        public var makeRealtimeEngine: RealtimeEngineFactory
        /// CTL-004, DW-033: the n-th `project.new` gets the UUID 00000000-0000-0000-0000-<n in hex>
        /// instead of a random one, so the same requests give the same project JSON.
        public var deterministicProjectIDs: Bool
        /// Relative paths in params resolve against this.
        public var workingDirectory: URL
        /// Where `test.fixture` looks for `<name>.jsonl`, in order.
        public var fixtureDirectories: [URL]
        /// The longest wait for an asset load or a render.
        public var jobTimeout: Duration
        /// The longest wait for a graph build before rendering.
        public var graphTimeout: Duration
        /// `EngineSync` debounce. Zero (headless) applies every structural change synchronously, so
        /// the engine sees the same sequence of graphs on every run (CTL-004).
        public var engineDebounce: Duration
        /// Implements `ui.*` in attach mode.
        public var ui: (any ControlUIProvider)?
        /// T-098 (DW-016): what `plugins.*` run against. Default: `ui` when it implements them too
        /// (the app's plugin manager), else `CatalogPluginControl` with `.headless()` settings,
        /// made on first use.
        public var plugins: (any ControlPluginProvider)? = nil

        @MainActor public init(
            mode: Mode = .headless,
            makeEngine: @escaping EngineFactory = { rate throws(DAWError) in try EngineClient(.offline(sampleRate: rate)) },
            makeRealtimeEngine: @escaping RealtimeEngineFactory = { config throws(DAWError) in try EngineClient(.realtime(config)) },
            deterministicProjectIDs: Bool? = nil,
            workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            fixtureDirectories: [URL] = [],
            jobTimeout: Duration = .seconds(600),
            graphTimeout: Duration = .seconds(30),
            engineDebounce: Duration? = nil,
            ui: (any ControlUIProvider)? = nil
        ) {
            self.mode = mode
            self.makeEngine = makeEngine
            self.makeRealtimeEngine = makeRealtimeEngine
            self.deterministicProjectIDs = deterministicProjectIDs ?? (mode == .headless)
            self.workingDirectory = workingDirectory
            self.fixtureDirectories = fixtureDirectories
            self.jobTimeout = jobTimeout
            self.graphTimeout = graphTimeout
            self.engineDebounce = engineDebounce ?? (mode == .headless ? .zero : EngineSync.defaultDebounce)
            self.ui = ui
        }
    }

    public let configuration: Configuration
    public private(set) var store: ProjectStore?
    public private(set) var engine: (any EngineProtocol)?
    /// Called after `project.new`/`project.open` replaced the store (the app swaps its document).
    public var storeDidChange: (@MainActor (ProjectStore) -> Void)?
    /// Called with the engine events of each drain, after they are logged for `engine.events`. The
    /// app's toasts (UI-004) read them here, so each engine has one drain.
    public var engineEventsDidArrive: (@MainActor ([EngineEventRecord]) -> Void)?

    /// The `ImportAsset` command `asset.import` performs: `{"type": "ImportAsset", "asset": AssetRef}`
    /// (MODEL-005, not in DAWModel yet).
    nonisolated public static let importAssetCommandType = "ImportAsset"
    /// Script methods `test.fixture` leaves out: they don't build the project.
    nonisolated public static let fixtureSkippedMethods: Set<String> = [
        ControlMethod.renderOffline.rawValue, ControlMethod.audioAnalyze.rawValue,
        ControlMethod.audioCompare.rawValue, ControlMethod.testFixture.rawValue,
    ]
    /// `engine.events` keeps this many.
    nonisolated public static let eventLogCapacity = 4096

    private var projectsCreated: UInt64 = 0
    private var eventLog: [EngineEventRecord] = []
    private var nextEventSeq: UInt64 = 1
    /// IO-013: RT violations counted by offline renders' own scopes.
    private var renderRtViolations: UInt64 = 0
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// CTL-031: where the running request reports progress (requests run one at a time).
    private var progressHandler: ControlProgressHandler?
    /// DW-146: the folder of the `test.fixture` script running now; its input paths resolve there.
    private var fixtureDirectory: URL?
    /// The JSON-RPC id of the request running now (nil for in-process calls and notifications).
    private var currentRequestID: RPCID?
    /// DW-220 (T-096): the `render.offline` waiting for its job now, for `render.cancel`.
    private var runningRender: RunningRender?

    private struct RunningRender {
        let job: JobID
        let engine: any EngineProtocol
        let requestID: RPCID?
        var cancelRequested = false
    }

    /// With `store`, controls that project and the engine attached to it (attach mode).
    public init(configuration: Configuration = Configuration(), store: ProjectStore? = nil) {
        self.configuration = configuration
        self.store = store
        self.engine = store?.engineSync?.engine
    }

    // MARK: Entry points

    /// One line of newline-delimited JSON in, one line out (nil for a notification). A JSON array
    /// is a JSON-RPC batch. CTL-031: requests with an `id` report progress to `notify` as
    /// `progress` notifications (`ControlProgress.notification(for:)`), before their response.
    public func handle(line: String, notify: (@MainActor (RPCRequest) -> Void)? = nil) async -> String? {
        let json: JSONValue
        do {
            json = try JSONValue(parsing: Data(line.utf8))
        } catch {
            return RPCResponse(id: nil, error: ControlError.parseError("not JSON").rpcError).line()
        }
        guard case .array(let items) = json else { return await handle(json: json, notify: notify)?.line() }
        guard !items.isEmpty else {
            return RPCResponse(id: nil, error: ControlError.invalidRequest("empty batch").rpcError).line()
        }
        var lines: [String] = []
        for item in items {
            if let response = await handle(json: item, notify: notify) { lines.append(response.line()) }
        }
        return lines.isEmpty ? nil : "[" + lines.joined(separator: ",") + "]"
    }

    /// Runs `request`; nil if it is a notification (no `id`). `progress` hears how a long job is
    /// going (CTL-031).
    public func handle(_ request: RPCRequest, progress: ControlProgressHandler? = nil) async -> RPCResponse? {
        // DW-220 (T-096): render.cancel doesn't queue behind the render it cancels.
        if request.method == ControlMethod.renderCancel.rawValue {
            let response: RPCResponse
            do {
                response = RPCResponse(id: request.id, result: try renderCancel(decode(request.params)))
            } catch {
                response = RPCResponse(id: request.id, error: ControlError(error).rpcError)
            }
            return request.id == nil ? nil : response
        }
        await acquire()
        defer { release() }
        progressHandler = progress
        currentRequestID = request.id
        defer { currentRequestID = nil }
        let response: RPCResponse
        do {
            response = RPCResponse(id: request.id, result: try await perform(request.method, request.params))
        } catch {
            response = RPCResponse(id: request.id, error: ControlError(error).rpcError)
        }
        return request.id == nil ? nil : response
    }

    /// In-process call (dawmcp headless, tests): the result, or the error the wire would carry.
    public func call(
        _ method: String, _ params: JSONValue? = nil, progress: ControlProgressHandler? = nil
    ) async throws(ControlError) -> JSONValue {
        // DW-220 (T-096): render.cancel doesn't queue behind the render it cancels.
        if method == ControlMethod.renderCancel.rawValue {
            do {
                return try renderCancel(decode(params))
            } catch {
                throw ControlError(error)
            }
        }
        await acquire()
        defer { release() }
        progressHandler = progress
        do {
            return try await perform(method, params)
        } catch {
            throw ControlError(error)
        }
    }

    public func call(
        _ method: ControlMethod, _ params: JSONValue? = nil, progress: ControlProgressHandler? = nil
    ) async throws(ControlError) -> JSONValue {
        try await call(method.rawValue, params, progress: progress)
    }

    /// Attach mode: controls `store` and the engine attached to it from now on (the app's main
    /// window changed), without detaching the store controlled before, which another window still
    /// shows. Pending events of the old engine are drained first. nil: no project.
    public func bind(_ store: ProjectStore?) {
        drainEvents()
        self.store = store
        self.engine = store?.engineSync?.engine
    }

    /// Drains the engine's events now (the app polls this between requests).
    public func drainEngineEvents() {
        drainEvents()
    }

    private func handle(json: JSONValue, notify: (@MainActor (RPCRequest) -> Void)?) async -> RPCResponse? {
        let request: RPCRequest
        do {
            request = try RPCRequest(validating: json)
        } catch {
            let id = json["id"].flatMap { try? $0.decode(RPCID.self) }
            return RPCResponse(id: id, error: error.rpcError)
        }
        guard let notify, let id = request.id else { return await handle(request) }
        return await handle(request) { notify($0.notification(for: id)) }
    }

    /// CTL-031: one request at a time, first come first served, even across awaits.
    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        progressHandler = nil
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    // MARK: Methods

    private func perform(_ name: String, _ params: JSONValue?) async throws -> JSONValue {
        drainEvents()
        guard let method = ControlMethod(rawValue: name) else { throw ControlError.methodNotFound(name) }
        if method.isAttachOnly && configuration.ui == nil {
            throw ControlError.methodNotAvailableInHeadless(name)
        }
        switch method {
        case .projectNew: return try encode(projectNew(decode(params)))
        case .projectOpen: return try encode(await projectOpen(decode(params)))
        case .projectSave:
            let p: ProjectSaveParams = try decode(params)
            try await requireStore().save(to: p.path.map { resolve($0) })
            return try encode(EmptyResult())
        case .projectGet: return try projectGet(decode(params))
        case .commandApply:
            let p: CommandApplyParams = try decode(params)
            return try encode(perform(decodeCommand(p.command)))
        case .commandBatch: return try encode(commandBatch(decode(params)))
        case .commandSchema: return try encode(CommandCatalog.schemas(decode(params)))
        case .undo, .redo:
            let _: NoParams = try decode(params)
            let store = try requireStore()
            let label = method == .undo ? store.undoLabel : store.redoLabel
            if method == .undo { store.undo() } else { store.redo() }
            return try encode(HistoryResult(label: label))
        case .transportPlay, .transportStop, .transportLocate, .transportSetLoop, .transportRecord, .transportSetPunch:
            return try encode(transport(method, params))
        case .transportSetRecordOptions: return try encode(transport(method, params))  // T-080
        case .transportWait: return try encode(await transportWait(decode(params)))
        case .transportSetMetronome: return try encode(transportSetMetronome(decode(params)))
        case .assetImport: return try encode(await assetImport(decode(params)))
        case .renderOffline: return try encode(await renderOffline(decode(params)))
        case .renderCancel: return try renderCancel(decode(params))  // a fixture line, say
        case .audioAnalyze: return try encode(await audioAnalyze(decode(params)))
        case .audioCompare: return try encode(await audioCompare(decode(params)))
        case .engineTelemetry:
            let _: NoParams = try decode(params)
            return try engineTelemetry()
        case .engineEvents:
            let p: EngineEventsParams = try decode(params)
            let since = p.since ?? 0
            let events = eventLog.filter { $0.seq > since }
            return try encode(EngineEventsResult(events: events, next: max(since, eventLog.last?.seq ?? 0)))
        case .engineParamInfo:
            let p: EngineParamInfoParams = try decode(params)
            let json = try requireEngine().paramInfoJSON(p.kind)
            return json.isEmpty ? .array([]) : try JSONValue(parsing: Data(json.utf8))
        case .enginePluginInfo:
            let p: EnginePluginInfoParams = try decode(params)
            let json = try requireEngine().pluginInfoJSON(slot: p.slot)
            return json.isEmpty ? .object(["slot": .int(Int64(p.slot)), "loaded": .bool(false)])
                : try JSONValue(parsing: Data(json.utf8))
        case .engineMeters: return try encode(engineMeters(decode(params)))  // T-096 (DW-174)
        case .enginePreviewNote: return try encode(enginePreviewNote(decode(params)))  // T-096 (DW-189)
        case .deviceList:
            let _: NoParams = try decode(params)
            return try encode(deviceList())
        case .deviceSet: return try encode(deviceSet(decode(params)))
        case .deviceSimulate: return try encode(deviceSimulate(decode(params)))
        case .midiInputs:
            let _: NoParams = try decode(params)
            return try encode(MidiInputsResult(inputs: try requireEngine().midiInputs()))
        case .midiInject: return try encode(midiInject(decode(params)))
        case .uiState:
            let _: NoParams = try decode(params)
            return try await configuration.ui!.uiState()
        case .uiSnapshot: return try await configuration.ui!.uiSnapshot(decode(params))
        case .uiPerform: return try await configuration.ui!.uiPerform(decode(params))
        case .testFixture: return try encode(await testFixture(decode(params)))
        case .pluginsScan, .pluginsList, .pluginsBlocked, .pluginsRetry, .pluginsUnblock:
            return try await plugins(method, params)  // T-098 (DW-016)
        case .engineParamDisplay: return try encode(engineParamDisplay(decode(params)))  // T-098 (DW-289)
        }
    }

    // MARK: plugins.* (T-098, DW-016)

    private var defaultPluginProvider: CatalogPluginControl?

    /// `Configuration.plugins`, else the UI provider when it implements `plugins.*` (the app),
    /// else the headless catalog.
    private var pluginProvider: any ControlPluginProvider {
        if let plugins = configuration.plugins { return plugins }
        if let ui = configuration.ui as? any ControlPluginProvider { return ui }
        if let defaultPluginProvider { return defaultPluginProvider }
        let made = CatalogPluginControl(settings: .headless())
        defaultPluginProvider = made
        return made
    }

    private func plugins(_ method: ControlMethod, _ params: JSONValue?) async throws -> JSONValue {
        let provider = pluginProvider
        switch method {
        case .pluginsList, .pluginsBlocked:
            let _: NoParams = try decode(params)
            let all = try await provider.pluginsList()
            return try encode(method == .pluginsList
                ? PluginsListResult(plugins: all.filter { !$0.isBlocked }, cachePath: provider.pluginCachePath)
                : PluginsListResult(blocked: all.filter(\.isBlocked), cachePath: provider.pluginCachePath))
        case .pluginsScan:
            let p: PluginsScanParams = try decode(params)
            return try encode(await provider.pluginsScan(timeout: try Self.scanTimeout(p.timeoutSeconds)))
        case .pluginsRetry:
            let p: PluginsRetryParams = try decode(params)
            let timeout = try Self.scanTimeout(p.timeoutSeconds)
            let retried = try await blockedPlugins(p.id, provider)
            let ids = Set(retried.map(\.identifier))
            // DW-275: a plugin that timed out gets the plugin manager's longer "Retry (120 s)" limit.
            let limit = timeout ?? (retried.contains { $0.timedOut == true } ? CatalogPluginControl.retryTimeout : nil)
            let scan = try await provider.pluginsRetry(identifiers: p.id == nil ? nil : ids, timeout: limit)
            let after = try await provider.pluginsList()
            return try encode(PluginsRetryResult(
                retried: retried.map(\.identifier), scan: scan,
                stillBlocked: after.filter { $0.isBlocked && ids.contains($0.identifier) }))
        case .pluginsUnblock:
            let p: PluginsUnblockParams = try decode(params)
            let blocked = try await blockedPlugins(p.id, provider)
            try await provider.pluginsUnblock(identifiers: p.id == nil ? nil : Set(blocked.map(\.identifier)))
            return try encode(PluginsUnblockResult(unblocked: blocked.map(\.identifier)))
        default:
            throw ControlError.methodNotFound(method.rawValue)
        }
    }

    /// The blocked plugins `id` names (all of them for nil); an `id` that isn't blocked is an error.
    private func blockedPlugins(_ id: String?, _ provider: any ControlPluginProvider) async throws -> [ControlPlugin] {
        let blocked = try await provider.pluginsList().filter(\.isBlocked)
        guard let id else { return blocked }
        let matches = blocked.filter { $0.identifier == id }
        if matches.isEmpty {
            throw DAWError.invalidArgument("no blocked plugin \"\(id)\" (plugins.blocked lists them)")
        }
        return matches
    }

    private static func scanTimeout(_ seconds: Double?) throws -> TimeInterval? {
        guard let seconds else { return nil }
        guard seconds.isFinite, seconds > 0, seconds <= 3600 else {
            throw ControlError.invalidParams("timeoutSeconds must be in (0, 3600]")
        }
        return seconds
    }

    // MARK: engine.paramDisplay (T-098, DW-289)

    /// The facade's `paramDisplay` (08 "Contract delta (T-094)") for a hosted plugin's param; the
    /// value defaults to the param's current one from `pluginInfoJSON`.
    private func engineParamDisplay(_ p: EngineParamDisplayParams) throws -> EngineParamDisplayResult {
        let engine = try requireEngine()
        guard p.param >= 0 else { throw ControlError.invalidParams("param must be ≥ 0") }
        var value = p.value
        if let given = value, !given.isFinite { throw ControlError.invalidParams("value must be a finite number") }
        if value == nil {
            let json = engine.pluginInfoJSON(slot: p.node)
            let info = json.isEmpty ? nil : try? JSONValue(parsing: Data(json.utf8))
            guard info?["loaded"]?.boolValue == true else {
                throw DAWError.invalidArgument("slot \(p.node) has no loaded plugin (engine.pluginInfo)")
            }
            let row = info?["params"]?.arrayValue?.first { $0["index"]?.int64Value == Int64(p.param) }
            guard let current = row?["value"]?.doubleValue else {
                throw DAWError.invalidArgument("slot \(p.node)'s plugin has no param \(p.param)")
            }
            value = Float(current)
        }
        let resolved = value ?? 0
        return EngineParamDisplayResult(
            node: p.node, param: p.param, value: resolved,
            display: engine.paramDisplay(slot: p.node, index: p.param, value: resolved))
    }

    // MARK: project.*

    private func projectNew(_ p: ProjectNewParams) throws -> ProjectNewResult {
        let id = configuration.deterministicProjectIDs ? Self.sequentialProjectID(projectsCreated + 1) : UUID()
        let project = try Project(id: id, name: p.name, sessionSampleRate: p.sampleRate ?? 48_000)
        try install(ProjectStore(project: project), engine: p.engine)
        projectsCreated += 1
        return ProjectNewResult(projectID: id)
    }

    /// DW-033: 00000000-0000-0000-0000-00000000000n.
    static func sequentialProjectID(_ n: UInt64) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-" + String(format: "%012llX", n & 0xFFFF_FFFF_FFFF))!
    }

    private func projectOpen(_ p: ProjectOpenParams) async throws -> ProjectOpenResult {
        // PLUG-021 (T-064): safe mode is set before the engine is attached, so no plugin renders.
        let safeMode = p.safeMode ?? false
        let store = try await ProjectStore.open(resolveInput(p.path), recover: p.recover ?? false, safeMode: safeMode)
        try install(store, engine: p.engine)
        // DW-097, MODEL-046: relative paths resolve against the folder; a missing or unloadable
        // file leaves its asset offline and its clips render silence.
        let report = await store.loadAssets(timeout: configuration.jobTimeout)
        drainEvents()
        return ProjectOpenResult(loadReport: report, safeMode: safeMode ? true : nil)
    }

    /// Makes `store` current with a new engine at its session rate. The previous store and
    /// engine stay as they were if this throws.
    @discardableResult
    private func install(_ store: ProjectStore, engine params: EngineParams?) throws -> any EngineProtocol {
        let rate = store.project.sessionSampleRate
        let engine: any EngineProtocol
        switch params?.mode ?? .offline {
        case .offline:
            engine = try configuration.makeEngine(rate)
        case .realtime:
            // DW-115: the fake devices unless another driver is asked for, at the session rate.
            engine = try configuration.makeRealtimeEngine(DriverConfig(
                outputDevice: params?.outputDevice ?? 0, sampleRate: rate, bufferFrames: params?.bufferFrames ?? 256,
                driver: params?.driver ?? .fake))
        }
        try store.attachEngine(engine, debounce: configuration.engineDebounce)
        // MODEL-043, DW-143 (T-061): saves capture hosted plugins' live state from the engine.
        store.pluginStateProvider = EnginePluginStates(engine: engine)
        // MODEL-044: a headless run (dawctl, dawmcp) doesn't autosave, so it leaves no autosave/
        // behind in the folders it opens or saves. In attach mode the app's store keeps its policy.
        if configuration.mode == .headless { store.autosavePolicy = nil }
        drainEvents()
        self.store?.detachEngine()
        self.store = store
        self.engine = engine
        storeDidChange?(store)
        return engine
    }

    private func projectGet(_ p: ProjectGetParams) throws -> JSONValue {
        let json = try JSONValue(encoding: requireStore().project)
        let pointer = p.path ?? ""
        guard let value = json.resolve(pointer: pointer) else {
            throw ControlError.invalidParams("no value at JSON Pointer \"\(pointer)\"")
        }
        return value
    }

    // MARK: command.*

    private func decodeCommand(_ json: JSONValue) throws -> any Command {
        try CommandRegistry.decode(json.data())
    }

    /// Performs one command as one undo entry.
    private func perform(_ command: any Command) throws -> CommandResult {
        let store = try requireStore()
        let before = Self.entityIDs(store.project)
        try store.perform(command)
        let created = Self.entityIDs(store.project).subtracting(before).sorted()
        return CommandResult(ok: true, createdIDs: created, label: command.label)
    }

    private func commandBatch(_ p: CommandBatchParams) throws -> CommandBatchResult {
        let store = try requireStore()
        var commands: [any Command] = []
        for (index, json) in p.commands.enumerated() {
            do {
                commands.append(try decodeCommand(json))
            } catch {
                throw ControlError.withData(ControlError(error), ["index": .int(Int64(index))])
            }
        }
        var results: [CommandResult] = []
        guard p.atomic ?? false else {
            for (index, command) in commands.enumerated() {
                do {
                    results.append(try perform(command))
                } catch {
                    throw ControlError.withData(
                        ControlError(error), ["index": .int(Int64(index)), "results": try JSONValue(encoding: results)])
                }
            }
            return CommandBatchResult(ok: true, results: results)
        }
        // Atomic: each step's created IDs come from a dry run on a copy (commands are pure), then
        // the whole batch is performed as one CompositeCommand (MODEL-004).
        var scratch = store.project
        for (index, command) in commands.enumerated() {
            let before = Self.entityIDs(scratch)
            do {
                _ = try command.apply(to: &scratch)
            } catch {
                throw ControlError.withData(ControlError(error), ["index": .int(Int64(index))])
            }
            results.append(CommandResult(ok: true, createdIDs: Self.entityIDs(scratch).subtracting(before).sorted(),
                                         label: command.label))
        }
        if !commands.isEmpty {
            try store.perform(CompositeCommand(commands.count == 1 ? commands[0].label : "Batch", commands))
        }
        return CommandBatchResult(ok: true, results: results)
    }

    /// Every ID-bearing entity in `project` (for `createdIDs`).
    static func entityIDs(_ project: Project) -> Set<ModelID> {
        var ids: Set<ModelID> = [project.master.id]
        func add(slots: [DeviceSlot], sends: [Send] = [], lanes: [AutomationLane]) {
            ids.formUnion(slots.map(\.id))
            ids.formUnion(sends.map(\.id))
            ids.formUnion(lanes.map(\.id))
        }
        add(slots: project.master.inserts, lanes: project.master.automation)
        for track in project.tracks {
            ids.insert(track.id)
            for clip in track.clips {
                ids.insert(clip.id)
                if case .midi(let midi) = clip { ids.formUnion(midi.notes.map(\.id)) }
            }
            ids.formUnion(track.takeFolders.map(\.id))
            add(slots: track.inserts + (track.instrument.map { [$0] } ?? []), sends: track.sends, lanes: track.automation)
        }
        for bus in project.buses {
            ids.insert(bus.id)
            add(slots: bus.inserts, sends: bus.sends, lanes: bus.automation)
        }
        ids.formUnion(project.assets.map(\.id))
        return ids
    }

    // MARK: transport.*

    private func transport(_ method: ControlMethod, _ params: JSONValue?) throws -> TransportState {
        let engine = try requireEngine()
        switch method {
        case .transportPlay:
            let _: NoParams = try decode(params)
            engine.play()
        case .transportStop:
            let _: NoParams = try decode(params)
            engine.stop()
        case .transportLocate:
            let p: TransportLocateParams = try decode(params)
            guard p.tick.raw >= 0 else { throw DAWError.invalidArgument("tick \(p.tick.raw) is negative") }
            engine.locate(p.tick)
        case .transportSetLoop:
            let p: TransportSetLoopParams = try decode(params)
            let loop: LoopRange?
            switch (p.start, p.end) {
            case (nil, nil) where !p.enabled:
                loop = nil
            case (let start?, let end?):
                guard start.raw >= 0, !p.enabled || start < end else {
                    throw DAWError.invalidArgument("loop [\(start.raw), \(end.raw)) is empty or negative")
                }
                loop = LoopRange(start: start, end: end, isEnabled: p.enabled)
            default:
                throw ControlError.invalidParams("start and end go together; leave both out only to clear the loop (enabled: false)")
            }
            // DW-123: the document's loop follows, validated by SetLoop (MODEL-005), before the engine
            // hears of it. Engine sync doesn't push the loop yet, so the engine is set directly too.
            try requireStore().perform(SetLoop(loop: loop))
            engine.setLoop(enabled: loop?.isEnabled ?? false, start: loop?.start ?? Tick(0), end: loop?.end ?? Tick(0))
        case .transportRecord:
            let p: TransportRecordParams = try decode(params)
            // T-052: through engine sync, which points the engine at the project's recordings
            // folder first. Finished takes come back as recordingFinalized events and become
            // clips (REC-004) when the events are drained.
            if let sync = store?.engineSync { sync.setRecording(p.enabled) } else { engine.setRecording(p.enabled) }
        case .transportSetPunch:
            let p: TransportSetPunchParams = try decode(params)
            let current = engine.transport()
            let start = p.start ?? current.punchIn, end = p.end ?? current.punchOut
            if p.enabled {
                guard start.raw >= 0, start < end else {
                    throw DAWError.invalidArgument("punch [\(start.raw), \(end.raw)) is empty or negative")
                }
            } else if (p.start == nil) != (p.end == nil) {
                throw ControlError.invalidParams("start and end go together")
            }
            engine.setPunch(enabled: p.enabled, start: start, end: end)
        case .transportSetRecordOptions:  // REC-034 (T-080)
            let p: TransportSetRecordOptionsParams = try decode(params)
            if let midiLoopTakes = p.midiLoopTakes { engine.setRecordOptions(midiLoopTakes: midiLoopTakes) }
        default:
            preconditionFailure("\(method) is not a transport command")
        }
        // T-052 (REC-004): a stop or record-off finalizes takes; import them before answering, so
        // the clips are in the project the caller reads next.
        if method == .transportStop || method == .transportRecord || method == .transportLocate { drainEvents() }
        return engine.transport()
    }

    /// T-026 (TIME-010): `SetMetronome` on the project (validated, persisted, dirty, not undoable);
    /// engine sync turns it into slot writes on the metronome node. Returns the settings now.
    private func transportSetMetronome(_ p: TransportSetMetronomeParams) throws -> MetronomeSettings {
        let store = try requireStore()
        try store.perform(SetMetronome(enabled: p.enabled, level: p.level, accent: p.accent))
        return store.project.metronome
    }

    private func transportWait(_ p: TransportWaitParams) async throws -> TransportState {
        let engine = try requireEngine()
        guard case .realtime = engine.mode else {
            throw DAWError.invalidArgument("transport.wait needs a live (realtime) engine; this one renders offline only")
        }
        guard p.timeoutMs >= 0 else { throw ControlError.invalidParams("timeoutMs must not be negative") }
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(p.timeoutMs)
        while true {
            let state = engine.transport()
            if p.untilTick.map({ state.tick >= $0 }) ?? !state.playing { return state }
            guard clock.now < deadline else {
                throw ControlError.withData(
                    .timeout("transport.wait: not there after \(p.timeoutMs) ms"), ["transport": try JSONValue(encoding: state)])
            }
            try? await Task.sleep(for: .milliseconds(2))
            drainEvents()
        }
    }

    // MARK: asset.import

    private func assetImport(_ p: AssetImportParams) async throws -> AssetImportResult {
        let store = try requireStore()
        let engine = try requireEngine()
        let url = resolveInput(p.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DAWError.invalidArgument("no file at \(url.path)")
        }
        guard CommandRegistry.commandType(named: Self.importAssetCommandType) != nil else {
            throw DAWError.notImplemented("asset.import needs the \(Self.importAssetCommandType) command (MODEL-005)")
        }
        // The ID the command will get: the engine loads under it first, so a file that doesn't
        // load leaves the project untouched (IDs are never reused, so peeking is safe).
        let id = store.project.ids.next
        let status = try await finish(engine.loadAsset(id, path: url.path), "asset.import")
        guard let info = status.asset else { throw DAWError.engine(code: .internal, detail: "load job reported no asset") }
        let asset = AssetRef(id: id, path: url.path, channels: Int(info.channels), originalSampleRate: info.fileSampleRate,
                             frames: info.fileFrames)
        let command: JSONValue = [
            "type": .string(Self.importAssetCommandType), "asset": try JSONValue(encoding: asset),
        ]
        _ = try perform(decodeCommand(command))
        return AssetImportResult(assetID: id, channels: info.channels, frames: info.fileFrames,
                                 fileSampleRate: info.fileSampleRate, resampled: info.resampled)
    }

    // MARK: render.offline

    private func renderOffline(_ p: RenderOfflineParams) async throws -> RenderOfflineResult {
        let engine = try requireEngine()
        guard p.from.raw >= 0, p.from < p.to else {
            throw DAWError.invalidArgument("render range [\(p.from.raw), \(p.to.raw)) is empty or negative")
        }
        let url = resolve(p.path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw DAWError.engine(code: .io, detail: "cannot create \(url.deletingLastPathComponent().path)")
        }
        try await settleGraph()
        var spec = ExportSpec(path: url.path, fileType: p.format ?? .wav, sampleFormat: p.sampleFormat ?? .float32,
                              blockSize: p.blockSize ?? 512, tailEnabled: p.tail ?? true)
        spec.followLoop = p.loop ?? false  // T-036
        spec.normalize = p.normalize ?? false  // T-082
        // DW-219 (T-096): TPDF dither for integer formats unless turned off; float is never dithered.
        spec.dither = spec.sampleFormat != .float32 && (p.dither ?? true)
        // T-026 (DECISIONS.md Q1): the click stays out of an export unless asked for. The `on`
        // slot is held at 0 for the render (a slot write, no rebuild) and follows the project again
        // afterwards, whatever happens to the job.
        let sync = store?.engineSync
        sync?.isMetronomeSuppressed = !(p.includeMetronome ?? false)
        defer { sync?.isMetronomeSuppressed = false }
        let job = engine.renderOffline(from: p.from, to: p.to, spec: spec)
        // DW-220 (T-096): render.cancel finds the job here while this waits.
        runningRender = RunningRender(job: job, engine: engine, requestID: currentRequestID)
        defer { runningRender = nil }
        let status: EngineJobStatus
        do {
            status = try await finish(job, "render.offline")
        } catch let error as ControlError {
            if case .cancelled = error, let partial = engine.pollJob(job).render { renderRtViolations += partial.rtViolations }
            throw error
        }
        let render = status.render ?? OfflineRenderResult()
        renderRtViolations += render.rtViolations
        return RenderOfflineResult(path: url.path, durationSec: render.durationSeconds, renderTimeSec: render.renderSeconds,
                                   sampleRate: render.sampleRate, frames: render.framesWritten,
                                   rtViolations: render.rtViolations, clippedSamples: render.clippedSamples,
                                   normalizeGain: spec.normalize ? render.normalizeGain : nil)
    }

    /// DW-220 (T-096): asks the engine to stop the running `render.offline` (the one with request id
    /// `p.id`, if given). It runs at once, outside the request queue; the render then fails with
    /// `cancelled` once the engine has stopped it.
    private func renderCancel(_ p: RenderCancelParams) throws -> JSONValue {
        guard var running = runningRender, p.id == nil || p.id == running.requestID else {
            return try encode(RenderCancelResult(cancelled: false))
        }
        let cancelled = running.cancelRequested || running.engine.cancelJob(running.job)
        running.cancelRequested = cancelled
        runningRender = running
        return try encode(RenderCancelResult(cancelled: cancelled, id: running.requestID))
    }

    /// DW-095: applies any pending structural change and waits until the engine has built it, so a
    /// render hears the project as it is now. A rejected build is an error (DW-050).
    private func settleGraph() async throws {
        let engine = try requireEngine()
        drainEvents()
        // T-052: takes imported from recordingFinalized load like asset.import's files; wait for
        // them, then drain again so their assetLoaded events reach the clip players.
        if let sync = store?.engineSync {
            await sync.settleLoads(timeout: configuration.graphTimeout)
            drainEvents()
        }
        store?.engineSync?.flush()
        let version = engine.graphStatus().submittedVersion
        guard version > 0 else { return }
        let status = await engine.graphApplied(version, timeout: configuration.graphTimeout)
        guard status.completedVersion >= version else {
            throw ControlError.timeout("graph \(version) wasn't built within \(configuration.graphTimeout)")
        }
        if let error = status.lastError { throw Self.modelError(error) }
    }

    /// DW-095: an engine-side cycle names graph NodeIDs; report the model entities instead.
    static func modelError(_ error: DAWError) -> DAWError {
        guard case .routingCycle(let nodes) = error else { return error }
        var path: [NodeIDValue] = []
        for owner in nodes.map(GraphNodeID.owner(of:)) where path.last != owner { path.append(owner) }
        return .routingCycle(path: path)
    }

    /// Waits for a job, drains its events, and turns failure into an error.
    private func finish(_ job: JobID, _ what: String) async throws -> EngineJobStatus {
        let engine = try requireEngine()
        guard job != 0 else { throw DAWError.engine(code: .internal, detail: "\(what): the engine refused the job") }
        let status = await waitForJob(job, on: engine, reportingAs: what)
        drainEvents()
        switch status.state {
        case .succeeded: return status
        case .failed: throw Self.modelError(status.error ?? .engine(code: .internal, detail: "\(what) failed"))
        case .cancelled: throw ControlError.cancelled("\(what) was cancelled (render.cancel); its partial file was deleted")
        case .unknown: throw DAWError.engine(code: .notFound, detail: "\(what): the engine lost job \(job)")
        case .queued, .running: throw ControlError.timeout("\(what) didn't finish within \(configuration.jobTimeout)")
        }
    }

    /// `waitForJob`, reporting the job's progress (CTL-031) in steps of at least 1 %, at most every
    /// 50 ms, and 1 when it succeeds.
    private func waitForJob(_ job: JobID, on engine: any EngineProtocol, reportingAs method: String) async -> EngineJobStatus {
        guard let report = progressHandler else { return await engine.waitForJob(job, timeout: configuration.jobTimeout) }
        let clock = ContinuousClock()
        let deadline = clock.now + configuration.jobTimeout
        var reported: Double?
        var reportedAt = clock.now
        while true {
            let status = engine.pollJob(job)
            if status.state == .succeeded {
                if reported != 1 { report(ControlProgress(method: method, progress: 1)) }
                return status
            }
            if status.state.isFinished || status.state == .unknown || clock.now >= deadline { return status }
            let progress = min(max(status.progress, 0), 1)
            if reported == nil || (progress >= reported! + 0.01 && clock.now - reportedAt >= .milliseconds(50)) {
                report(ControlProgress(method: method, progress: progress))
                reported = progress
                reportedAt = clock.now
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: audio.*

    private func audioAnalyze(_ p: AudioAnalyzeParams) async throws -> AudioAnalysis {
        let url = resolve(p.path)
        // Off the main actor: long files take a while and the app must stay responsive.
        return try await Task.detached {
            try AudioAnalysis.analyze(
                AudioData(contentsOf: url).slice(p.range), rangeStart: p.range?.start ?? 0, fftSize: p.fftSize ?? 4096,
                bands: p.bands ?? 32, silenceThresholdDb: p.silenceThresholdDb ?? -120)
        }.value
    }

    private func audioCompare(_ p: AudioCompareParams) async throws -> AudioComparison {
        let (a, b) = (resolve(p.a), resolve(p.b))
        return try await Task.detached {
            try AudioComparison.compare(AudioData(contentsOf: a), AudioData(contentsOf: b),
                                        toleranceDb: p.toleranceDb ?? -100, maxOffset: p.maxOffset)
        }.value
    }

    // MARK: engine.*

    private func engineTelemetry() throws -> JSONValue {
        let engine = try requireEngine()
        let telemetry = engine.telemetry()
        guard case .object(var result) = try JSONValue(encoding: telemetry) else {
            throw ControlError.internalError("telemetry didn't encode as an object")
        }
        // CONV §5.3: the engine's render scope plus every offline render's own scope.
        result["engineRtViolations"] = .int(Int64(clamping: telemetry.rtViolations))
        result["renderRtViolations"] = .int(Int64(clamping: renderRtViolations))
        result["rtViolations"] = .int(Int64(clamping: telemetry.rtViolations &+ renderRtViolations))
        // DW-095: NodeIDs mapped back to the model entity (and role) they belong to.
        result["nodeLatencies"] = .array(engine.nodeLatencies().map { latency in
            [
                "node": .int(Int64(bitPattern: latency.node)),
                "owner": .int(Int64(bitPattern: GraphNodeID.owner(of: latency.node))),
                "role": GraphNodeID.role(of: latency.node).map { .string(String(describing: $0)) } ?? .null,
                "samples": .int(Int64(latency.samples)),
            ]
        })
        result["graph"] = try JSONValue(encoding: engine.graphStatus())
        return .object(result)
    }

    /// DW-174 (T-096): post-fader strip meters (MIX-005) and compressor gain reduction (DSP-031),
    /// read from the engine now.
    private func engineMeters(_ p: EngineMetersParams) throws -> EngineMetersResult {
        let project = try requireStore().project
        let engine = try requireEngine()
        var kinds: [(NodeIDValue, String)] = project.tracks.map { ($0.id, "track") } + project.buses.map { ($0.id, "bus") }
        kinds.append((project.master.id, "master"))
        let slots = project.tracks.flatMap { $0.inserts + ($0.instrument.map { [$0] } ?? []) }
            + project.buses.flatMap(\.inserts) + project.master.inserts
        for slot in slots where slot.kind == .builtin(.compressor) { kinds.append((slot.id, "compressor")) }
        let kindOf = Dictionary(kinds, uniquingKeysWith: { first, _ in first })
        let nodes = p.nodes ?? kinds.map(\.0)
        var meters: [EngineMetersResult.Meter] = []
        for node in nodes {
            guard let kind = kindOf[node] else {
                if Self.entityIDs(project).contains(node) {
                    throw DAWError.invalidArgument("\(node) has no meter (tracks, buses, the master and compressor slots do)")
                }
                throw DAWError.notFound(kind: "meter", id: node)
            }
            let reading = engine.meter(node)
            if kind == "compressor" {
                // DSP-031: peak is the deepest reduction of the last block as a gain factor (1 = none);
                // 0 means the compressor hasn't processed audio yet.
                let factor = Double(reading?.peak ?? 0)
                meters.append(.init(node: node, kind: kind, peakDb: [], rmsDb: [],
                                    gainReductionDb: factor > 0 ? min(0, Self.db(factor)) : 0))
            } else {
                meters.append(.init(node: node, kind: kind, peakDb: [Self.db(Double(reading?.peak ?? 0))],
                                    rmsDb: [Self.db(Double(reading?.rms ?? 0))], gainReductionDb: nil))
            }
        }
        return EngineMetersResult(meters: meters)
    }

    /// dBFS of a linear level; silence (and anything below -240 dB) reads -240, as `audio.analyze`.
    static func db(_ level: Double) -> Double {
        level > 1e-12 && level.isFinite ? max(-240, 20 * log10(level)) : -240
    }

    /// DW-189 (T-096): UI-021's audition through the facade's `previewNote`: the note on now, its
    /// note-off `durationMs` later (the call returns at once). Realtime engines only: an offline
    /// engine renders nothing between calls, so nothing would hear it.
    private func enginePreviewNote(_ p: EnginePreviewNoteParams) throws -> EnginePreviewNoteResult {
        let project = try requireStore().project
        let engine = try requireEngine()
        guard case .realtime = engine.mode else {
            throw ControlError.notSupported(
                "engine.previewNote needs a realtime engine (project.new {engine: {mode: \"realtime\"}}); offline engines render only through render.offline")
        }
        guard let track = project.tracks.first(where: { $0.id == p.track }) else { throw DAWError.notFound(kind: "track", id: p.track) }
        guard track.kind == .midi else { throw DAWError.invalidArgument("track \(p.track) is not a MIDI track") }
        guard track.instrument != nil else { throw DAWError.invalidArgument("track \(p.track) has no instrument to play the note") }
        let velocity = p.velocity ?? 100
        let duration = p.durationMs ?? 500
        guard (0...127).contains(p.pitch) else { throw ControlError.invalidParams("pitch must be 0…127") }
        guard (1...127).contains(velocity) else { throw ControlError.invalidParams("velocity must be 1…127") }
        guard (1...60_000).contains(duration) else { throw ControlError.invalidParams("durationMs must be 1…60000") }
        let pitch = UInt8(p.pitch), trackID = p.track
        engine.previewNote(track: trackID, pitch: pitch, velocity: UInt8(velocity), on: true)
        Task { @MainActor [weak engine] in
            try? await Task.sleep(for: .milliseconds(duration))
            engine?.previewNote(track: trackID, pitch: pitch, velocity: 0, on: false)
        }
        return EnginePreviewNoteResult(track: trackID, pitch: p.pitch, velocity: velocity, durationMs: duration)
    }

    /// BRIDGE-004 / DW-095: the single drain of engine events. `EngineSync` reacts to them
    /// (asset loads bump clip players) and the log keeps them for `engine.events`.
    private func drainEvents() {
        guard let engine else { return }
        let events = store?.engineSync?.pollEvents() ?? engine.pollEvents()
        guard !events.isEmpty else { return }
        var records: [EngineEventRecord] = []
        for event in events {
            records.append(EngineEventRecord(seq: nextEventSeq, event: event))
            nextEventSeq += 1
        }
        eventLog += records
        if eventLog.count > Self.eventLogCapacity { eventLog.removeFirst(eventLog.count - Self.eventLogCapacity) }
        engineEventsDidArrive?(records)
    }

    // MARK: device.* (DW-115)

    /// REC-010..012 (T-053): the test seam. Each message arrives as if from a connected source.
    private func midiInject(_ params: MidiInjectParams) throws -> MidiInjectResult {
        let engine = try requireEngine()
        for event in params.events {
            guard (0x80...0xEF).contains(event.status), (event.data1 ?? 0) <= 127, (event.data2 ?? 0) <= 127 else {
                throw ControlError.invalidParams("midi.inject: not a channel message \(event.status)")
            }
            guard (event.sample == nil) != (event.framesFromNow == nil) else {
                throw ControlError.invalidParams("midi.inject: give exactly one of sample and framesFromNow")
            }
        }
        for event in params.events {
            let relative = event.framesFromNow != nil
            try engine.injectMidi(atSample: event.sample ?? event.framesFromNow ?? 0, relativeToNow: relative,
                                  status: event.status, data1: event.data1 ?? 0, data2: event.data2 ?? 0,
                                  source: event.source)  // T-093
        }
        return MidiInjectResult(accepted: params.events.count)
    }

    private func deviceList() throws -> DeviceListResult {
        let engine = try requireEngine()
        let driver: DeviceDriverKind? = if case .realtime(let config) = engine.mode { config.driver } else { nil }
        return DeviceListResult(devices: engine.devices(), outputDeviceID: engine.telemetry().outputDeviceID, driver: driver)
    }

    private func deviceSet(_ p: DeviceSetParams) throws -> DeviceStateResult {
        let engine = try requireEngine()
        guard case .realtime(let current) = engine.mode else {
            throw DAWError.invalidArgument("device.set needs a realtime engine (project.new {engine: {mode: \"realtime\"}})")
        }
        return try deviceChange(engine) { () throws(DAWError) in
            try engine.setDevice(DriverConfig(
                outputDevice: p.outputDevice ?? 0, inputDevice: p.inputDevice ?? 0, sampleRate: p.sampleRate ?? 0,
                bufferFrames: p.bufferFrames ?? current.bufferFrames, outputChannels: current.outputChannels,
                inputChannels: current.inputChannels, driver: current.driver))
        }
    }

    private func deviceSimulate(_ p: DeviceSimulateParams) throws -> DeviceStateResult {
        let engine = try requireEngine()
        return try deviceChange(engine) { () throws(DAWError) in
            // Returns once the engine has reacted (IO-021), so its events are queued by now.
            try engine.simulateDeviceEvent(DeviceEvent(p.kind, deviceID: p.deviceID ?? 0, sampleRate: p.sampleRate ?? 0))
        }
    }

    /// Runs a device change and reports where the engine ended up and the events it raised.
    private func deviceChange(_ engine: any EngineProtocol, _ change: () throws(DAWError) -> Void) throws -> DeviceStateResult {
        drainEvents()
        let before = eventLog.last?.seq ?? 0
        try change()
        drainEvents()
        let telemetry = engine.telemetry()
        return DeviceStateResult(outputDeviceID: telemetry.outputDeviceID, deviceRunning: telemetry.deviceRunning,
                                 sampleRate: telemetry.sampleRate, events: eventLog.filter { $0.seq > before })
    }

    // MARK: test.fixture

    private func testFixture(_ p: TestFixtureParams) async throws -> TestFixtureResult {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard !p.name.isEmpty, p.name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ControlError.invalidParams("fixture names use letters, digits, _ and -")
        }
        let candidates = configuration.fixtureDirectories.map { $0.appending(path: p.name + ".jsonl") }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            let searched = configuration.fixtureDirectories.map(\.path).joined(separator: ", ")
            throw ControlError.invalidParams("no fixture \"\(p.name)\" in [\(searched)]")
        }
        let script = try ControlScript(contentsOf: url)
        // DW-146: a fixture's relative inputs (`assets/…`) live next to it, wherever the server runs.
        fixtureDirectory = url.deletingLastPathComponent()
        defer { fixtureDirectory = nil }
        var ran = 0
        var skipped = 0
        for line in script.lines {
            if Self.fixtureSkippedMethods.contains(line.request.method) {
                skipped += 1
                continue
            }
            do {
                _ = try await perform(line.request.method, line.request.params)
            } catch {
                throw ControlError.withData(ControlError(error), ["fixture": .string(url.path), "line": .int(Int64(line.number))])
            }
            ran += 1
        }
        return TestFixtureResult(name: p.name, path: url.path, requests: ran, skipped: skipped)
    }

    // MARK: Helpers

    private func requireStore() throws(ControlError) -> ProjectStore {
        guard let store else { throw .noProject }
        return store
    }

    private func requireEngine() throws(ControlError) -> any EngineProtocol {
        guard let engine else { throw .noProject }
        return engine
    }

    /// Absolute paths stay; relative ones resolve against the working directory.
    func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded).standardizedFileURL
            : configuration.workingDirectory.appending(path: expanded).standardizedFileURL
    }

    /// An input file (`asset.import`, `project.open`): inside a `test.fixture`, relative to the
    /// fixture's folder (DW-146); otherwise as `resolve`.
    func resolveInput(_ path: String) -> URL {
        guard let fixtureDirectory else { return resolve(path) }
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? resolve(path) : fixtureDirectory.appending(path: expanded).standardizedFileURL
    }

    /// Params decode from the request's object; missing params are `{}`.
    private func decode<T: Decodable>(_ params: JSONValue?) throws -> T {
        switch params {
        case nil, .null: try JSONValue.object([:]).decode(T.self)
        case .object: try params!.decode(T.self)
        default: throw ControlError.invalidParams("params must be an object (named params)")
        }
    }

    private func encode(_ value: some Encodable) throws -> JSONValue {
        try JSONValue(encoding: value)
    }
}
