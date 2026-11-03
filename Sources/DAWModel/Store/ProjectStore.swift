import Foundation
import Observation
import os

/// MODEL-007: holds the current project, its undo history and dirty flag, and reports every change
/// on `changeStream()`. All edits go through `perform` (D-11). Runs on the main actor in the app
/// and in the headless tools alike (07 Interfaces).
@Observable
@MainActor
public final class ProjectStore {
    public private(set) var project: Project
    /// True when the project differs from the last saved (or opened) state. Undoing back to that
    /// state clears it.
    public private(set) var isDirty = false

    private var history: UndoStack
    /// `history.stateMarker` at the last save.
    private var cleanMarker: UInt64 = 0
    /// T-026: counts edits that leave no undo entry (`HistoryExemptCommand`), so they make the
    /// project dirty too; `cleanUnrecorded` is its value at the last save. Undo can't take them
    /// back, so only a save makes them clean.
    private var unrecordedEdits: UInt64 = 0
    private var cleanUnrecorded: UInt64 = 0
    /// The project when the open gesture began, and everything its updates touched so far.
    private var gestureStart: Project?
    private var gestureChange: ProjectChange?

    /// MODEL-021: the engine this store keeps in step, if any (`attachEngine`).
    @ObservationIgnored public private(set) var engineSync: EngineSync?

    /// MODEL-040: the project folder, once opened or saved. Nil for a new project.
    public private(set) var folderURL: URL?
    /// What open found (MODEL-042/045/046, DW-111); `loadAssets` updates the offline assets.
    public private(set) var loadReport = ProjectLoadReport()
    /// MODEL-043: captures plugin state at save and autosave time and restores it after open.
    /// Nil keeps the states stored in the project.
    @ObservationIgnored public var pluginStateProvider: (any PluginStateProvider)?
    /// MODEL-044: when to autosave; nil turns autosaving off. It runs only while the project has
    /// a folder.
    @ObservationIgnored public var autosavePolicy: AutosavePolicy? = .standard {
        didSet { restartAutosave() }
    }

    /// Counts published changes, so autosave can tell whether anything changed since it last ran.
    @ObservationIgnored private var editSerial: UInt64 = 0
    /// The `editSerial` the autosave in the folder holds once the queued file operations are
    /// done; nil when unknown (a failed write), so the next autosave writes.
    @ObservationIgnored private var autosavedSerial: UInt64? = 0
    /// This store wrote the autosave that is in the folder once the queued file operations are
    /// done.
    @ObservationIgnored private var wroteAutosave = false
    /// DW-148: counts operations on the autosave (writes, removals, saves), so one finishing after
    /// a later one has started knows it no longer has the last word.
    @ObservationIgnored private var autosaveTicket: UInt64 = 0
    @ObservationIgnored private var lastWrite: Task<Void, Never>?
    @ObservationIgnored private var autosaveTimer: Task<Void, Never>?
    @ObservationIgnored private var autosaveDebounce: Task<Void, Never>?

    @ObservationIgnored private var subscribers: [Int: AsyncStream<ProjectChange>.Continuation] = [:]
    @ObservationIgnored private var nextSubscriber = 0

    private static let log = Logger(subsystem: "dev.emberstudio", category: "model")

    public init(project: Project = Project(), undoLimit: Int = UndoStack.defaultLimit) {
        self.project = project
        self.history = UndoStack(limit: undoLimit)
    }

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }
    /// For "Undo <label>" menu items and the control protocol's `undo` result (CTL-002).
    public var undoLabel: String? { history.undoLabel }
    public var redoLabel: String? { history.redoLabel }
    public var isGestureActive: Bool { history.isGestureActive }

    /// Applies `command` and pushes it onto the undo stack, or, inside a gesture, applies it
    /// without pushing (MODEL-003). Throws without changing anything if the command is invalid.
    /// A `HistoryExemptCommand` (T-026) is never pushed, not even as part of a gesture; it still
    /// publishes a `.perform` change and makes the project dirty.
    public func perform(_ command: any Command) throws(DAWError) {
        let before = project
        var working = project
        // T-056: a session-rate change goes to the engine first, so a rate it refuses (the device
        // can't run it) leaves the document as it is; if the command then fails, the engine goes back.
        let engineRateBefore = try changeEngineSampleRate(for: command)
        do {
            try history.perform(command, on: &working)
        } catch {
            if let engineRateBefore { try? engineSync?.setSessionSampleRate(engineRateBefore) }
            throw error
        }
        project = working
        if command.isHistoryExempt {
            unrecordedEdits &+= 1
            publish(ProjectChange(cause: .perform, label: command.label, from: before, to: working))
        } else if gestureStart != nil {
            let change = ProjectChange(cause: .gestureUpdate, label: command.label, from: before, to: working)
            gestureChange?.formUnion(change)
            publish(change)
        } else {
            publish(ProjectChange(cause: .perform, label: command.label, from: before, to: working))
        }
    }

    /// Undoes the newest entry; does nothing if there is none. An open gesture is ended first.
    public func undo() {
        endGestureForHistoryStep()
        step(.undo) { (history: inout UndoStack, project: inout Project) throws(DAWError) in
            try history.undo(&project)
        }
    }

    public func redo() {
        endGestureForHistoryStep()
        step(.redo) { (history: inout UndoStack, project: inout Project) throws(DAWError) in
            try history.redo(&project)
        }
    }

    // MARK: Gestures (MODEL-003)

    /// Starts a continuous edit (fader drag, clip drag). Commands performed until `endGesture`
    /// apply immediately, each publishing a `.gestureUpdate`, and become one undo entry. Engine sync
    /// (MODEL-021) can send param-only updates straight to param slots instead of rebuilding.
    /// Gestures nest; only the outermost counts.
    public func beginGesture(_ label: String) {
        if !history.isGestureActive {
            gestureStart = project
            gestureChange = ProjectChange(cause: .gestureEnd, label: label)
        }
        history.beginGesture(label)
    }

    /// Ends the gesture: pushes its single undo entry and publishes a `.gestureEnd` covering all of
    /// its updates.
    public func endGesture() {
        guard history.isGestureActive else { return }
        history.endGesture()
        guard !history.isGestureActive else { return }
        finishGesture()
    }

    // MARK: Changes

    /// A new stream of every change from now on. Each call makes an independent subscriber.
    public func changeStream() -> AsyncStream<ProjectChange> {
        let (stream, continuation) = AsyncStream<ProjectChange>.makeStream()
        let id = nextSubscriber
        nextSubscriber += 1
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[id] = nil }
        }
        return stream
    }

    // MARK: Engine sync (MODEL-021/022)

    /// Starts keeping `engine` in step with the project: allocates its param slots, applies its
    /// graph now, and from then on syncs after every change (see `EngineSync`). Replaces (and
    /// frees the slots of) a previously attached engine.
    @discardableResult
    public func attachEngine(
        _ engine: any EngineProtocol, debounce: Duration = EngineSync.defaultDebounce
    ) throws(DAWError) -> EngineSync {
        detachEngine()
        let sync = try EngineSync(engine: engine, project: project, debounce: debounce)
        // DW-130 (T-056): the document follows a session-rate change the engine made by itself.
        sync.onEngineSampleRateChange = { [weak self] rate in self?.followEngineSampleRate(rate) }
        engineSync = sync
        return sync
    }

    public func detachEngine() {
        engineSync?.invalidate()
        engineSync = nil
    }

    // MARK: Session sample rate (T-056)

    /// For `SetSessionSampleRate` and its inverse: changes the attached engine's rate and returns
    /// the one it had (nil when nothing changed).
    private func changeEngineSampleRate(for command: any Command) throws(DAWError) -> Double? {
        let rate = (command as? SetSessionSampleRate)?.sampleRate ?? (command as? RestoreSessionSampleRate)?.sampleRate
        guard let rate, let engineSync, rate != engineSync.engineSampleRate else { return nil }
        try SetSessionSampleRate.check(rate)
        let previous = engineSync.engineSampleRate
        try engineSync.setSessionSampleRate(rate)
        return previous
    }

    /// DW-130: the engine runs at `rate` now (a device fallback, `device.set`); the document
    /// follows with `SetSessionSampleRate`, which marks it dirty but isn't undoable.
    private func followEngineSampleRate(_ rate: Double) {
        guard rate != project.sessionSampleRate else { return }
        do {
            try perform(SetSessionSampleRate(sampleRate: rate))
        } catch {
            Self.log.error("couldn't follow the engine's session rate \(rate): \(error)")
        }
    }

    // MARK: Persistence (MODEL-040..046)

    /// Saves the project as a folder (MODEL-040) at `url`, or where it was opened or last saved
    /// when `url` is nil. Assets outside the folder are copied into `Audio/` and their paths made
    /// relative (DW-124); plugin states come from `pluginStateProvider` (MODEL-043). `project.json`
    /// is replaced atomically (MODEL-041). The file I/O runs off the main actor; edits made while
    /// it runs leave the project dirty. The autosave is removed: the main file is newer.
    public func save(to url: URL?) async throws(DAWError) {
        guard let target = url ?? folderURL else {
            throw .invalidArgument("the project has no folder yet; save needs a path")
        }
        let snapshot = project
        let marker = history.stateMarker
        let unrecorded = unrecordedEdits
        let serial = editSerial
        let states = capturePluginStates(snapshot)
        let source = folderURL
        autosaveTicket &+= 1
        let ticket = autosaveTicket
        let moved = try await serialized { () throws(DAWError) in
            try ProjectFolder(url: target).save(snapshot, pluginStates: states, sourceFolder: source)
        }
        // DW-124: the copied assets' new paths. Not an edit (no undo entry, no change event): the
        // file is the same, only where the project finds it changed.
        let oldPaths = Dictionary(snapshot.assets.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
        for i in project.assets.indices {
            let asset = project.assets[i]
            if let path = moved[asset.id], oldPaths[asset.id] == asset.path { project.assets[i].path = path }
        }
        if let source, source.standardizedFileURL != target.standardizedFileURL, wroteAutosave {
            ProjectFolder(url: source).removeAutosave()
        }
        folderURL = target
        // DW-148: an autosave started while saving was queued after the save and describes the
        // folder as it ends up; only without one does the save's removal stand.
        if ticket == autosaveTicket {
            wroteAutosave = false
            autosavedSerial = serial
        }
        cleanMarker = marker
        cleanUnrecorded = unrecorded
        updateDirty()
        restartAutosave()
        // restartAutosave cancelled the debounce of edits made while saving; they still get it.
        if editSerial != serial { scheduleDebouncedAutosave() }
    }

    /// Opens a project folder (MODEL-040). With `recover`, a newer `autosave/project.json` is
    /// opened instead and the store starts dirty (MODEL-045); without it, `loadReport` says
    /// whether one exists. Older formats are migrated (MODEL-042), the project is checked and
    /// safely repaired (DW-111), and missing audio files are reported, not fatal (MODEL-046).
    /// Attach an engine and call `loadAssets()` to load the audio.
    public static func open(_ url: URL, recover: Bool) async throws(DAWError) -> ProjectStore {
        let folder = ProjectFolder(url: url)
        let (project, report) = try await Task.detached { () -> Result<(Project, ProjectLoadReport), DAWError> in
            Result { () throws(DAWError) in try folder.load(recover: recover) }
        }.value.get()
        let store = ProjectStore(project: project)
        store.folderURL = url
        store.loadReport = report
        if report.recovered {
            // The project differs from project.json until it is saved.
            store.cleanMarker = .max
            store.updateDirty()
            store.autosavedSerial = store.editSerial
        }
        store.restartAutosave()
        return store
    }

    /// DW-097, MODEL-046: loads every asset into the attached engine, resolving relative paths
    /// against the project folder, and waits for the jobs. Assets whose file is missing or fails
    /// to load are `offlineAssets` in the returned (and stored) report; their clips render
    /// silence. Without an engine, only the files' presence is checked.
    @discardableResult
    public func loadAssets(timeout: Duration = .seconds(60)) async -> ProjectLoadReport {
        var offline = Set<ModelID>()
        if let engineSync {
            let jobs = engineSync.loadAssets(project.assets, folder: folderURL)
            for (asset, job) in jobs {
                guard let job else {
                    offline.insert(asset)
                    continue
                }
                let status = await engineSync.engine.waitForJob(job, timeout: timeout)
                if status.state != .succeeded { offline.insert(asset) }
            }
        } else {
            for asset in project.assets {
                let file = ProjectFolder.resolve(asset, in: folderURL)
                if !(file.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false) { offline.insert(asset.id) }
            }
        }
        loadReport.offlineAssets = offline.sorted()
        return loadReport
    }

    /// MODEL-043: hands every stored plugin state to `pluginStateProvider`. Call it once the
    /// plugins are instantiated (plugin hosting, 10).
    public func restorePluginStates() {
        let states = project.pluginStates
        guard !states.isEmpty else { return }
        pluginStateProvider?.restorePluginStates(states)
    }

    /// MODEL-044: writes `autosave/` now if the project has a folder and changed since the last
    /// autosave or save. Never touches `project.json`. When the project is back at its saved
    /// state, an autosave this store wrote is removed instead.
    ///
    /// DW-148: the bookkeeping (`wroteAutosave`, `autosavedSerial`) describes the folder as the
    /// queued file operations leave it, and is updated when an operation is queued, not when it
    /// finishes. File operations run in the order they are queued (`serialized`), but the
    /// continuations after them may resume on the main actor after later edits and autosaves.
    /// Recording state there let an edit made in between count as autosaved (never written), or
    /// let a removal be skipped because the write before it hadn't resumed yet.
    public func autosave() async throws(DAWError) {
        guard let folderURL, !history.isGestureActive else { return }
        let folder = ProjectFolder(url: folderURL)
        let serial = editSerial
        if !isDirty {
            autosavedSerial = serial
            guard wroteAutosave else { return }
            wroteAutosave = false
            try await autosaveIO(onFailure: { $0.wroteAutosave = true }) { () throws(DAWError) in folder.removeAutosave() }
            return
        }
        guard serial != autosavedSerial else { return }
        let snapshot = project
        let states = capturePluginStates(snapshot)
        wroteAutosave = true
        autosavedSerial = serial
        try await autosaveIO(onFailure: { $0.autosavedSerial = nil }) { () throws(DAWError) in
            try folder.autosave(snapshot, pluginStates: states)
        }
    }

    /// Queues an autosave file operation. If it fails and no later one has started, `onFailure`
    /// corrects the bookkeeping recorded for it.
    private func autosaveIO(
        onFailure: (ProjectStore) -> Void, _ body: @escaping @Sendable () throws(DAWError) -> Void
    ) async throws(DAWError) {
        autosaveTicket &+= 1
        let ticket = autosaveTicket
        do {
            try await serialized(body)
        } catch {
            if ticket == autosaveTicket { onFailure(self) }
            throw error
        }
    }

    /// MODEL-045: a clean quit. Stops autosaving, waits for writes in flight and deletes the
    /// autosave, so the next open offers no recovery. Unsaved changes are the caller's to ask
    /// about first.
    public func close() async {
        autosavePolicy = nil
        await lastWrite?.value
        if let folderURL { ProjectFolder(url: folderURL).removeAutosave() }
        wroteAutosave = false
    }

    /// Records the current state as saved.
    func markClean() {
        cleanMarker = history.stateMarker
        cleanUnrecorded = unrecordedEdits
        updateDirty()
    }

    private func capturePluginStates(_ project: Project) -> [NodeIDValue: Data] {
        let captured = pluginStateProvider?.capturePluginStates(of: project) ?? [:]
        return project.pluginStates.merging(captured) { _, current in current }
    }

    /// Runs file I/O off the main actor, one write after another (a save and an autosave never
    /// interleave, and an autosave never lands after the save that made it stale).
    private func serialized<T: Sendable>(
        _ body: @escaping @Sendable () throws(DAWError) -> T
    ) async throws(DAWError) -> T {
        let previous = lastWrite
        let task = Task.detached { () async -> Result<T, DAWError> in
            await previous?.value
            return Result { () throws(DAWError) -> T in try body() }
        }
        lastWrite = Task { _ = await task.value }
        return try await task.value.get()
    }

    /// MODEL-044: the periodic autosave, while the project has a folder and a policy.
    private func restartAutosave() {
        autosaveTimer?.cancel()
        autosaveTimer = nil
        autosaveDebounce?.cancel()
        autosaveDebounce = nil
        guard let policy = autosavePolicy, folderURL != nil else { return }
        autosaveTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: policy.interval)
                guard !Task.isCancelled, let self else { return }
                await self.autosaveLogged()
            }
        }
    }

    /// MODEL-044: an autosave `debounce` after the latest edit.
    private func scheduleDebouncedAutosave() {
        guard let policy = autosavePolicy, folderURL != nil else { return }
        autosaveDebounce?.cancel()
        autosaveDebounce = Task { [weak self] in
            try? await Task.sleep(for: policy.debounce)
            guard !Task.isCancelled, let self else { return }
            await self.autosaveLogged()
        }
    }

    private func autosaveLogged() async {
        do {
            try await autosave()
        } catch {
            Self.log.error("autosave failed: \(error)")
        }
    }

    // MARK: Private

    private func step(
        _ cause: ProjectChange.Cause,
        _ body: (inout UndoStack, inout Project) throws(DAWError) -> String?
    ) {
        let before = project
        var working = project
        do {
            guard let label = try body(&history, &working) else { return }
            project = working
            publish(ProjectChange(cause: cause, label: label, from: before, to: working))
        } catch {
            // An inverse that doesn't apply means the history no longer matches the project. Keep
            // the project as it is and drop the history rather than leave undo half-working.
            Self.log.fault("\(String(describing: cause)) failed, clearing undo history: \(error)")
            history.removeAll()
            cleanMarker = .max
            updateDirty()
        }
    }

    private func endGestureForHistoryStep() {
        guard history.isGestureActive else { return }
        history.endAllGestures()
        finishGesture()
    }

    private func finishGesture() {
        let change = gestureChange
        gestureStart = nil
        gestureChange = nil
        if let change, !change.isEmpty {
            publish(change)
        }
    }

    private func publish(_ change: ProjectChange) {
        updateDirty()
        editSerial &+= 1
        // MODEL-044: every edit counts, not only structural ones (07, T-031 clarification).
        if change.cause != .gestureUpdate { scheduleDebouncedAutosave() }
        if !change.isEmpty { engineSync?.update(to: project) }
        for continuation in subscribers.values {
            continuation.yield(change)
        }
    }

    private func updateDirty() {
        let dirty = history.gestureHasChanges || history.stateMarker != cleanMarker
            || unrecordedEdits != cleanUnrecorded
        if dirty != isDirty { isDirty = dirty }
    }
}

/// MODEL-044: autosave timing.
public struct AutosavePolicy: Hashable, Sendable {
    /// A periodic autosave while the project is dirty.
    public var interval: Duration
    /// The quiet time after an edit before it is autosaved.
    public var debounce: Duration

    public init(interval: Duration, debounce: Duration) {
        self.interval = interval
        self.debounce = debounce
    }

    /// Every 60 s, and 2 s after the latest edit (MODEL-044).
    public static let standard = AutosavePolicy(interval: .seconds(60), debounce: .seconds(2))
}
