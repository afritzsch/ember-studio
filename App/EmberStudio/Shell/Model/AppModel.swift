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

    init(engine: EngineChoice, makeEngine: Dispatcher.EngineFactory? = nil, workingDirectory: URL? = nil,
         now: @escaping @MainActor () -> Date = { Date() }) {
        engineChoice = engine
        let factory = makeEngine ?? engine.factory
        self.makeEngine = factory
        self.now = now
        let provider = AppControlProvider()
        controlProvider = provider
        dispatcher = Dispatcher(configuration: .init(
            mode: .attach, makeEngine: factory,
            workingDirectory: workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            fixtureDirectories: ControlFixtures.defaultDirectories(), ui: provider))
        provider.app = self
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

    /// The window `id` became main (focus): the Dispatcher now controls its project.
    func becameMain(_ id: Int) {
        guard let window = window(id) else { return }
        mainWindowID = id
        if dispatcher.store !== window.store { dispatcher.bind(window.store) }
    }

    /// Closes a window: a clean close of its project (MODEL-045 `close()`), engine released.
    func closeWindow(_ id: Int) async {
        guard let window = window(id) else { return }
        windows.removeAll { $0.id == id }
        presenter?.close(window)
        if dispatcher.store === window.store {
            let next = windows.last
            dispatcher.bind(next?.store)
            mainWindowID = next?.id
        } else if mainWindowID == id {
            mainWindowID = windows.last?.id
        }
        await window.store.close()
        window.store.detachEngine()
    }

    /// DW-144: a clean quit closes every project, so none offers recovery next time.
    func quit() async {
        for window in windows {
            await window.store.close()
            window.store.detachEngine()
        }
        dispatcher.bind(nil)
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
    }

    // MARK: File (UI-001)

    /// File > New: an empty project in a new window.
    @discardableResult
    func newProject() -> ProjectWindowModel {
        untitledCount += 1
        let store = ProjectStore(project: Project(name: untitledCount == 1 ? "Untitled" : "Untitled \(untitledCount)"))
        let engineError = attachEngine(store)
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
        let engineError = attachEngine(store)
        let report = await store.loadAssets()
        let window: ProjectWindowModel
        if let existing {
            let old = existing.store
            existing.replace(store: store)
            presenter?.setTitle(existing)
            if dispatcher.store === old || mainWindowID == existing.id { dispatcher.bind(store) }
            old.autosavePolicy = nil
            old.detachEngine()
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

    /// The app's engine for `store`; offline when that fails (no device), with the reason.
    private func attachEngine(_ store: ProjectStore) -> String? {
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
