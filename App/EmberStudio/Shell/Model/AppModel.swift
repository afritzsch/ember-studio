import DAWControl
import DAWModel
import Foundation
import Observation

/// What the AppKit layer does for the app model: windows, panels and snapshots. Tests pass a fake
/// (or nothing), so the model runs without AppKit windows (UI-003).
@MainActor
protocol WindowPresenting: AnyObject {
    func show(_ window: ProjectWindowModel)
    func close(_ window: ProjectWindowModel)
    func setTitle(_ window: ProjectWindowModel)
    /// UI-051: the window as PNG data, with its pixel size.
    func snapshot(_ window: ProjectWindowModel) throws -> (png: Data, width: Int, height: Int)
}

/// UI-001 / UI-003: the app's state. One window per project (no NSDocumentController), the File
/// commands, the control dispatcher the socket serves (attach mode, 13) and the event pump.
@Observable
@MainActor
final class AppModel {
    private(set) var windows: [ProjectWindowModel] = []
    /// The main window: the one the File menu and attach mode (`ui.*`, the Dispatcher) act on.
    private(set) var mainWindowID: Int?

    @ObservationIgnored let engineChoice: EngineChoice
    @ObservationIgnored let dispatcher: Dispatcher
    @ObservationIgnored let controlProvider: AppControlProvider
    @ObservationIgnored weak var presenter: (any WindowPresenting)?
    @ObservationIgnored var makeEngine: Dispatcher.EngineFactory
    @ObservationIgnored var now: @MainActor () -> Date
    @ObservationIgnored private var nextWindowID = 1
    @ObservationIgnored private var untitledCount = 0

    // MARK: One live engine (DW-156, T-090)

    /// DW-156 (docs/autobuild/DECISIONS.md "T-090 one engine"): with a realtime engine choice
    /// (`fake`, `coreAudio`) the app has **one** live engine, made by `makeEngine`, and only the
    /// main (front) window's project holds it. Every other window keeps an offline engine of its own
    /// (`makeOfflineEngine`: peaks, export, no device). With `--engine offline` every window has its
    /// own offline engine from `makeEngine`, as before.
    @ObservationIgnored let sharesLiveEngine: Bool
    @ObservationIgnored var makeOfflineEngine: Dispatcher.EngineFactory
    /// The live engine, once made (nil until the first window, or when making it failed).
    @ObservationIgnored private(set) var liveEngine: (any EngineProtocol)?
    /// The session rate the live engine runs while nobody holds it (a holder's engine sync knows it).
    @ObservationIgnored private var liveRate: Double = 0
    /// The offline engine each project keeps for the times it isn't in front, by store. Kept, so its
    /// assets stay loaded (peaks show at once) and switching back and forth decodes nothing again.
    @ObservationIgnored private var parkedEngines: [ObjectIdentifier: any EngineProtocol] = [:]

    init(engine: EngineChoice, makeEngine: Dispatcher.EngineFactory? = nil,
         makeOfflineEngine: Dispatcher.EngineFactory? = nil, workingDirectory: URL? = nil,
         now: @escaping @MainActor () -> Date = { Date() }) {
        engineChoice = engine
        let factory = makeEngine ?? engine.factory
        self.makeEngine = factory
        self.makeOfflineEngine = makeOfflineEngine ?? EngineChoice.offline.factory
        sharesLiveEngine = engine != .offline
        self.now = now
        let provider = AppControlProvider()
        controlProvider = provider
        // DW-156: project.new/open through the socket replace the main window's document, which then
        // holds the live engine; the Dispatcher asks the app for it.
        let broker = EngineBroker()
        let brokered: Dispatcher.EngineFactory = { rate throws(DAWError) in try broker.engine(rate) }
        dispatcher = Dispatcher(configuration: .init(
            mode: .attach,
            makeEngine: sharesLiveEngine ? brokered : factory,
            workingDirectory: workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            fixtureDirectories: ControlFixtures.defaultDirectories(), ui: provider))
        provider.app = self
        broker.app = self
        // CTL-002 through the socket: project.new/open replace the main window's document.
        dispatcher.storeDidChange = { [weak self] store in self?.dispatcherReplaced(store) }
        // UI-004: the bound window's engine events are drained by the Dispatcher (once), then toasted.
        dispatcher.engineEventsDidArrive = { [weak self] records in
            self?.boundWindow?.engineEventsArrived(records.map(\.event))
        }
    }

    var mainWindow: ProjectWindowModel? { windows.first { $0.id == mainWindowID } }
    /// The window whose store the Dispatcher controls (the main window, once it has been bound).
    private var boundWindow: ProjectWindowModel? { windows.first { $0.store === dispatcher.store } }

    func window(_ id: Int) -> ProjectWindowModel? { windows.first { $0.id == id } }

    // MARK: Windows

    /// A window for `store`, shown and made main.
    @discardableResult
    func addWindow(_ store: ProjectStore) -> ProjectWindowModel {
        let window = ProjectWindowModel(id: nextWindowID, store: store, toasts: ToastCenter(now: now))
        nextWindowID += 1
        windows.append(window)
        presenter?.show(window)
        becameMain(window.id)
        return window
    }

    /// The window `id` became main (focus): the Dispatcher now controls its project, and it gets
    /// the live engine (DW-156; the transport stops).
    func becameMain(_ id: Int) {
        guard let window = window(id) else { return }
        mainWindowID = id
        if let error = handOverLiveEngine() {
            window.toasts.post(.error, .error, title: "No audio engine", message: error)
        }
        if dispatcher.store !== window.store { dispatcher.bind(window.store) }
    }

    /// Closes a window: a clean close of its project (MODEL-045 `close()`), engine released. The
    /// live engine, if it had it, goes to the next window (DW-156).
    func closeWindow(_ id: Int) async {
        guard let window = window(id) else { return }
        windows.removeAll { $0.id == id }
        presenter?.close(window)
        if dispatcher.store === window.store {
            if let next = windows.last {
                becameMain(next.id)
            } else {
                dispatcher.bind(nil)
                mainWindowID = nil
            }
        } else if mainWindowID == id {
            mainWindowID = windows.last?.id
        }
        if holdsLiveEngine(window.store) { releaseLiveEngine(from: window.store, park: false) }
        await window.store.close()
        window.store.detachEngine()
        pruneParkedEngines()
    }

    /// DW-144: a clean quit closes every project, so none offers recovery next time.
    func quit() async {
        for window in windows {
            if holdsLiveEngine(window.store) { releaseLiveEngine(from: window.store, park: false) }
            await window.store.close()
            window.store.detachEngine()
        }
        dispatcher.bind(nil)
        parkedEngines = [:]
        liveEngine = nil
    }

    private func dispatcherReplaced(_ store: ProjectStore) {
        if let window = mainWindow {
            let old = window.store
            // The Dispatcher already took the old store's engine; it shouldn't autosave a project
            // nobody shows anymore.
            if old !== store { old.autosavePolicy = nil }
            window.replace(store: store)
            presenter?.setTitle(window)
        } else {
            addWindow(store)
        }
        pruneParkedEngines()
    }

    // MARK: File (UI-001)

    /// File > New: an empty project in a new window.
    @discardableResult
    func newProject() -> ProjectWindowModel {
        untitledCount += 1
        let store = ProjectStore(project: Project(name: untitledCount == 1 ? "Untitled" : "Untitled \(untitledCount)"))
        let engineError = attachEngine(store, front: true)
        let window = addWindow(store)
        if let engineError { window.toasts.post(.error, .error, title: "No audio engine", message: engineError) }
        return window
    }

    /// File > Open: the project folder at `url` in its own window (the existing one if it is open
    /// already: one window per project). DW-144: offers recovery, reports offline audio and repairs.
    @discardableResult
    func open(_ url: URL, recover: Bool = false, into existing: ProjectWindowModel? = nil) async throws(DAWError) -> ProjectWindowModel {
        if existing == nil, let open = windows.first(where: { $0.store.folderURL?.standardizedFileURL == url.standardizedFileURL }) {
            presenter?.show(open)
            becameMain(open.id)
            return open
        }
        let store = try await ProjectStore.open(url, recover: recover)
        // DW-156: a new window comes to the front; a recovered project replaces its window's.
        let engineError = attachEngine(store, front: existing.map { $0.id == mainWindowID } ?? true, replacing: existing?.store)
        let report = await store.loadAssets()
        let window: ProjectWindowModel
        if let existing {
            let old = existing.store
            existing.replace(store: store)
            presenter?.setTitle(existing)
            if dispatcher.store === old || mainWindowID == existing.id { dispatcher.bind(store) }
            old.autosavePolicy = nil
            old.detachEngine()
            pruneParkedEngines()
            window = existing
        } else {
            window = addWindow(store)
        }
        if let engineError { window.toasts.post(.error, .error, title: "No audio engine", message: engineError) }
        window.toasts.post(loadReport: report, project: store.project.name)
        if report.recoveryAvailable {
            window.toasts.postRecoveryAvailable(project: store.project.name) { [weak self, weak window] in
                guard let self, let window else { return }
                Task { @MainActor in
                    do {
                        try await self.open(url, recover: true, into: window)
                    } catch {
                        window.toasts.post(.error, .error, title: "Recovery failed", message: "\(error)")
                    }
                }
            }
        }
        return window
    }

    /// File > Save (`url` nil: where it was opened or last saved) and Save As.
    func save(_ window: ProjectWindowModel, to url: URL?) async throws(DAWError) {
        try await window.store.save(to: url)
        presenter?.setTitle(window)
    }

    /// The whole project (to the end of its last clip, at least one bar) as a 32-bit float WAV with
    /// its tail, without the click (DW-177). File > Export… opens the export dialog instead
    /// (UI-042, `ExportModel`), which renders through the same `ExportModel.render`.
    func export(_ window: ProjectWindowModel, to url: URL) async throws(DAWError) -> OfflineRenderResult {
        guard let engine = window.engine else { throw .invalidArgument("the project has no engine") }
        let span = window.exportDialog.span(.project) ?? (Tick(0), Tick(3840))
        return try await ExportModel.render(window: window, engine: engine, from: span.from, to: span.to,
                                            spec: ExportSpec(path: url.path), includeMetronome: false)
    }

    /// The app's engine for `store`; offline when that fails (no device), with the reason. DW-156:
    /// with a shared live engine, a project that comes to the `front` gets it (`replacing` the
    /// project of a window that goes away with it); any other gets an offline engine.
    private func attachEngine(_ store: ProjectStore, front: Bool, replacing old: ProjectStore? = nil) -> String? {
        if sharesLiveEngine {
            if front { return moveLiveEngine(to: store, discarding: old, loadAssets: false) }
            parkEngine(store, loadAssets: false)
            return nil
        }
        defer {
            // MODEL-043, DW-143 (T-061): saves capture hosted plugins' live state from the engine,
            // as the Dispatcher does for dawctl/dawmcp. Opening needs nothing more: a slot's stored
            // state reaches its AU through the node's configJSON.
            if let engine = store.engineSync?.engine { store.pluginStateProvider = EnginePluginStates(engine: engine) }
        }
        do {
            try store.attachEngine(try makeEngine(store.project.sessionSampleRate))
            return nil
        } catch {
            _ = try? store.attachEngine(EngineClient(.offline(sampleRate: store.project.sessionSampleRate)))
            return "\(error.description). Playing offline only."
        }
    }

    // MARK: Event pump

    /// Called at display rate: the bound window's events go through the Dispatcher's single drain
    /// (so `engine.events` sees them too), every other window drains its own engine sync. Then
    /// toasts expire and transports are polled.
    func pump() {
        // DW-156: a handover put off while an export ran, or a front project left without an engine
        // (a socket project.new that failed after taking the live engine).
        if sharesLiveEngine, let main = mainWindow, liveEngine != nil || main.engine == nil, !holdsLiveEngine(main.store),
           !isHandoverBlocked(to: main.store), let error = handOverLiveEngine() {
            main.toasts.post(.error, .error, title: "No audio engine", message: error)
        }
        for window in windows {
            if window.store === dispatcher.store {
                dispatcher.drainEngineEvents()
            } else if let events = window.store.engineSync?.pollEvents(), !events.isEmpty {
                window.engineEventsArrived(events)
            }
            window.toasts.expire()
            window.pollTransport()
        }
    }
}

// MARK: - One live engine (DW-156, T-090)

extension AppModel {
    /// Whether `store` holds the live engine.
    func holdsLiveEngine(_ store: ProjectStore) -> Bool {
        guard let liveEngine, let engine = store.engineSync?.engine else { return false }
        return engine === liveEngine
    }

    /// The window whose project holds the live engine, nil when none does.
    var liveWindow: ProjectWindowModel? { windows.first { holdsLiveEngine($0.store) } }

    /// The project holding the live engine: a window's, or the Dispatcher's.
    private var liveHolder: ProjectStore? {
        if let window = liveWindow { return window.store }
        if let store = dispatcher.store, holdsLiveEngine(store) { return store }
        return nil
    }

    private func windowShowing(_ store: ProjectStore) -> ProjectWindowModel? { windows.first { $0.store === store } }

    /// A running export renders on the engine it started on, so neither that engine nor the
    /// project's engine sync may change under it: the handover waits (the pump retries).
    private func isHandoverBlocked(to store: ProjectStore) -> Bool {
        let involved = [store, liveHolder].compactMap { $0 }
        return involved.contains { windowShowing($0)?.exportDialog.isRunning == true }
    }

    /// Gives the main window's project the live engine, unless an export holds things up. Returns
    /// why it couldn't (the project keeps an offline engine).
    @discardableResult
    func handOverLiveEngine() -> String? {
        guard sharesLiveEngine, let main = mainWindow, !isHandoverBlocked(to: main.store) else { return nil }
        return moveLiveEngine(to: main.store)
    }

    /// DW-156: `store` gets the live engine (made the first time), and the project that had it gets
    /// its offline engine back (`park`), unless it is `discarding` (replaced along with its window)
    /// or no window shows it. The transport stops first; a take that was recording ends and is
    /// imported into the project that recorded it. Params, graph, loop, arms and monitoring are
    /// re-applied by engine sync (`attachEngine`), plugin states carried over, and assets the
    /// engine hasn't loaded yet are loaded (`loadAssets`). Returns why it failed: the live engine
    /// couldn't be made, so `store` plays offline.
    @discardableResult
    func moveLiveEngine(to store: ProjectStore, discarding: ProjectStore? = nil, loadAssets: Bool = true) -> String? {
        guard sharesLiveEngine else { return nil }
        if holdsLiveEngine(store) { return nil }
        let rate = store.project.sessionSampleRate
        let engine: any EngineProtocol
        if let liveEngine {
            engine = liveEngine
        } else {
            do {
                engine = try makeEngine(rate)
            } catch {
                if store.engineSync == nil { parkEngine(store, loadAssets: loadAssets) }
                return "\(error.description). Playing offline only."
            }
            liveEngine = engine
            liveRate = rate
        }
        if let holder = liveHolder {
            releaseLiveEngine(from: holder, park: holder !== discarding && windowShowing(holder) != nil)
        }
        // The live engine runs the project's rate. A device that can't run it keeps its own, and
        // the project follows (DW-130), as it would after a device fallback.
        if liveRate != rate {
            do {
                try engine.setSessionSampleRate(rate)
                liveRate = rate
            } catch {
                if store.engineSync == nil { parkEngine(store, loadAssets: false) }
                do {
                    try store.perform(SetSessionSampleRate(sampleRate: liveRate))
                    windowShowing(store)?.toasts.post(
                        .deviceChanged, .warning, title: "Session rate changed",
                        message: "The audio device can't run \(Self.khz(rate)) kHz: \(store.project.name) now runs at \(Self.khz(liveRate)) kHz.")
                } catch {
                    return "\(error.description). Playing offline only."
                }
            }
        }
        let window = windowShowing(store)
        window?.engineWillChange()
        // The project's own (offline) engine is kept for the next time it isn't in front.
        let states = capturePluginStates(store)
        if let current = store.engineSync?.engine { parkedEngines[ObjectIdentifier(store)] = current }
        store.detachEngine()
        do {
            try store.attachEngine(engine)
        } catch {
            parkEngine(store, loadAssets: false)
            window?.engineDidChange()
            return "\(error.description). Playing offline only."
        }
        connect(store, engine, states: states, loadAssets: loadAssets)
        window?.engineDidChange()
        rebindDispatcher()
        return nil
    }

    /// Takes the live engine from `holder`: the transport stops (a recording take ends), the events
    /// it still has go to `holder`'s window (and its takes into its project), its plugin states are
    /// kept, and, if `park`, the project gets its offline engine back with those states.
    func releaseLiveEngine(from holder: ProjectStore, park: Bool) {
        guard let liveEngine, let sync = holder.engineSync, sync.engine === liveEngine else { return }
        let window = windowShowing(holder)
        window?.engineWillChange()
        if liveEngine.transport().recording { sync.setRecording(false) }
        liveEngine.stop()
        drainEvents(of: holder)  // REC-004: the take is imported while the project still holds the engine
        liveRate = sync.engineSampleRate
        let states = capturePluginStates(holder)
        holder.detachEngine()
        holder.pluginStateProvider = nil
        if park {
            parkEngine(holder, states: states)
        }
        window?.engineDidChange()
        rebindDispatcher()
    }

    /// Gives `store` its offline engine (the one it had, else a new one) at its session rate.
    private func parkEngine(_ store: ProjectStore, states: [NodeIDValue: Data] = [:], loadAssets: Bool = true) {
        let rate = store.project.sessionSampleRate
        var engine = parkedEngines[ObjectIdentifier(store)]
        if let parked = engine, parked.telemetry().sampleRate != rate {
            // The project's rate changed while it was in front: the parked engine follows (IO-033).
            do { try parked.setSessionSampleRate(rate) } catch { engine = nil }
        }
        if engine == nil {
            do {
                engine = try makeOfflineEngine(rate)
            } catch {
                return  // no engine at all: the window shows the project without one
            }
        }
        guard let engine else { return }
        parkedEngines[ObjectIdentifier(store)] = engine
        store.detachEngine()
        do {
            try store.attachEngine(engine)
        } catch {
            return
        }
        connect(store, engine, states: states, loadAssets: loadAssets)
    }

    /// After `store.attachEngine(engine)`: saves capture plugin state from `engine` (MODEL-043), the
    /// states carried over reach its plugins (held until a slot's plugin is made, PLUG-016), and the
    /// project's assets it hasn't loaded yet are loaded (their `assetLoaded` events re-apply the clip
    /// players, DW-072).
    private func connect(_ store: ProjectStore, _ engine: any EngineProtocol, states: [NodeIDValue: Data], loadAssets: Bool) {
        let provider = EnginePluginStates(engine: engine)
        store.pluginStateProvider = provider
        if !states.isEmpty { provider.restorePluginStates(states) }
        guard loadAssets, let sync = store.engineSync else { return }
        let coarsest = PeakLevel.blockSizes.count - 1
        let missing = store.project.assets.filter { engine.peaks($0.id, level: coarsest) == nil }
        if !missing.isEmpty { _ = sync.loadAssets(missing, folder: store.folderURL) }
    }

    /// The live plugin states of `store`'s hosted plugins (and the stored ones of slots the engine
    /// has no state for), so they survive the engine change.
    private func capturePluginStates(_ store: ProjectStore) -> [NodeIDValue: Data] {
        guard let engine = store.engineSync?.engine else { return [:] }
        let captured = EnginePluginStates(engine: engine).capturePluginStates(of: store.project)
        return store.project.pluginStates.merging(captured) { _, live in live }
    }

    /// The engine events `store` still has, to its window (through the Dispatcher's drain when it is
    /// the bound project, so `engine.events` sees them).
    private func drainEvents(of store: ProjectStore) {
        if dispatcher.store === store, dispatcher.engine === store.engineSync?.engine {
            dispatcher.drainEngineEvents()
        } else if let events = store.engineSync?.pollEvents(), !events.isEmpty {
            windowShowing(store)?.engineEventsArrived(events)
        }
    }

    /// The Dispatcher reads its project's engine at `bind`: bind again when that engine changed.
    private func rebindDispatcher() {
        if let store = dispatcher.store, dispatcher.engine !== store.engineSync?.engine { dispatcher.bind(store) }
    }

    /// Parked engines of projects no window shows any more are released.
    func pruneParkedEngines() {
        let shown = Set(windows.map { ObjectIdentifier($0.store) })
        parkedEngines = parkedEngines.filter { shown.contains($0.key) }
    }

    /// `Dispatcher.Configuration.makeEngine` with a shared live engine: `project.new`/`open` through
    /// the socket make a project that replaces the bound (main) window's, or opens the first window,
    /// so it comes to the front with the live engine. The bound project, being replaced, lets go of
    /// it unparked. A rate the device can't run gives the project an offline engine instead.
    fileprivate func engineForDispatcher(_ rate: Double) throws(DAWError) -> any EngineProtocol {
        let engine: any EngineProtocol
        if let liveEngine {
            engine = liveEngine
        } else {
            engine = try makeEngine(rate)
            liveEngine = engine
            liveRate = rate
        }
        if let holder = liveHolder {
            releaseLiveEngine(from: holder, park: holder !== dispatcher.store && windowShowing(holder) != nil)
        }
        if liveRate != rate {
            do {
                try engine.setSessionSampleRate(rate)
                liveRate = rate
            } catch {
                return try makeOfflineEngine(rate)
            }
        }
        return engine
    }

    fileprivate static func khz(_ rate: Double) -> String {
        rate.truncatingRemainder(dividingBy: 1000) == 0 ? String(Int(rate / 1000)) : String(format: "%.1f", rate / 1000)
    }
}

/// Lets the Dispatcher, made in `AppModel.init`, ask the app for an engine (DW-156).
@MainActor
private final class EngineBroker {
    weak var app: AppModel?

    func engine(_ rate: Double) throws(DAWError) -> any EngineProtocol {
        guard let app else { throw .invalidArgument("the app is gone") }
        return try app.engineForDispatcher(rate)
    }
}
