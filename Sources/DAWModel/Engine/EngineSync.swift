import Foundation
import os

/// MODEL-021/022: keeps an engine in step with a project. `ProjectStore` calls `update(to:)` after
/// every command, undo/redo, gesture step and gesture end (`attachEngine`).
///
/// Each update diffs the whole project against what the engine has (DW-032):
///   1. Param slots for new param-bearing nodes are allocated (MODEL-022) and kept in `runtime`.
///   2. Every slot value the project implies (`GraphDescriptionBuilder.paramValues`, including the
///      solo-resolved mutes of MIX-006) is compared with what was last written; changed values go
///      out through `setParam` at once. This is the whole cost of a param-only change.
///   3. The graph is rebuilt and compared with the last one applied. Only if it differs (a
///      structural change) is an `applyGraph` scheduled: one per `debounce` window, built from the
///      project as it is when the window ends, so a burst of edits (a clip drag) coalesces.
///
/// Slots of nodes that left the project are freed after the graph without them has been applied
/// (the engine also holds them back while an older graph may read them, DW-029).
///
/// DW-072 (DW-051): a clip player's clips are fixed per node instance, so whenever a player's clips
/// or notes differ from the graph last applied, or an asset its clips use finishes loading
/// (`assetLoaded`, see `handle(_:)`), its `configVersion` is bumped. The same holds for any node's
/// `configJSON` (a sampler's zones, DW-140) and for a sampler whose zone asset finishes loading.
@MainActor
public final class EngineSync {
    public static let defaultDebounce: Duration = .milliseconds(10)

    public let engine: any EngineProtocol
    /// Zero or less applies structural changes synchronously inside `update(to:)`.
    public let debounce: Duration
    /// MODEL-022: never persisted; a reopened project starts empty and reallocates.
    public private(set) var runtime = RuntimeIDs()
    public let catalog: ParamCatalog
    /// The last graph passed to `applyGraph`.
    public private(set) var appliedGraph: EngineGraph?
    /// Set when a param allocation failed or the engine rejected a graph; cleared by the next
    /// successful apply.
    public private(set) var lastError: DAWError?

    private var project: Project
    /// `paramRequirements` of `project`.
    private var required: [NodeIDValue: UInt32] = [:]
    /// The graph for `project` and `runtime`, once built; dropped when either changes.
    private var candidate: EngineGraph?
    /// The value last written to each slot.
    private var written: [ParamID: Float] = [:]
    /// Ranges replaced by a larger or smaller one; freed after the next apply.
    private var retired: [RuntimeIDs.ParamRange] = []
    private var pendingApply: Task<Void, Never>?
    private var isInvalidated = false
    /// DW-123: the loop last given to the transport.
    private var pushedLoop: LoopRange?

    /// T-056 (IO-033, DW-130): the session rate the engine runs at, as far as this sync knows: the
    /// project's at attach, then whatever `setSessionSampleRate` set or an `assetsReloaded` event
    /// reported.
    public private(set) var engineSampleRate: Double
    /// DW-130: called when the engine changed its session rate by itself (a device fallback,
    /// `device.set`) to one the project doesn't have. `ProjectStore` performs `SetSessionSampleRate`
    /// with it, so the document follows the engine.
    public var onEngineSampleRateChange: (@MainActor (Double) -> Void)?

    /// T-026 (docs/autobuild/DECISIONS.md Q1): an offline export leaves the click out unless it
    /// asks for it. The exporter sets this for the duration of the render: the metronome's `on`
    /// slot is written 0 at once and stays 0 through any edit, then follows
    /// `project.metronome.enabled` again when it is cleared. A slot write, never a rebuild.
    public var isMetronomeSuppressed = false {
        didSet {
            guard isMetronomeSuppressed != oldValue, !isInvalidated else { return }
            writeParams()
        }
    }

    /// PLUG-021 (T-064, docs/autobuild/DECISIONS.md "T-064 crash marker"): safe mode, a
    /// session-only override that host-bypasses every AU and VST3 slot (PLUG-018) whatever the
    /// document says. The slots, their params and their state stay as they are and nothing is
    /// written to the project; clearing it gives each slot its own bypass again. Slot writes only,
    /// never a rebuild.
    public var arePluginsBypassed = false {
        didSet {
            guard arePluginsBypassed != oldValue, !isInvalidated else { return }
            writeParams()
        }
    }

    /// T-052: asset loads of imported takes not yet waited for (`settleLoads`).
    private var pendingLoads: [JobID] = []
    /// REC-001 (T-052): the audio tracks armed in the engine, with their input pair.
    private var pushedArms: [NodeIDValue: UInt32] = [:]
    /// REC-011 (T-053): the MIDI tracks armed in the engine.
    private var pushedMidiArms: Set<NodeIDValue> = []
    /// REC-002 (T-052): the recordings directory last given to the engine.
    private var pushedRecordingDirectory: String?
    /// T-052: the project folder, if it has one (`ProjectStore` points it at `folderURL`).
    /// Recordings go to `<folder>/Audio/Recordings/` (REC-002), otherwise to a temporary folder
    /// (`EngineSync.temporaryRecordingsDirectory`), which a save copies into `Audio/` (DW-124).
    public var projectFolder: @MainActor () -> URL? = { nil }
    /// REC-004 (T-052): called for each `recordingFinalized` event with a take. `ProjectStore`
    /// turns it into one undoable `ImportAsset` + `AddClip` (`ProjectStore.importRecording`).
    public var onRecordingFinalized: (@MainActor (RecordedTake, DAWError?) -> Void)?

    private static let log = Logger(subsystem: "dev.emberstudio", category: "model")

    /// Allocates every param slot `project` needs, writes their values and applies its graph at
    /// once.
    /// `pluginsBypassed` starts in safe mode (PLUG-021), so no plugin renders even for a block.
    public init(engine: any EngineProtocol, project: Project, debounce: Duration = EngineSync.defaultDebounce,
                catalog: ParamCatalog? = nil, pluginsBypassed: Bool = false) throws(DAWError) {
        self.engine = engine
        arePluginsBypassed = pluginsBypassed
        self.debounce = debounce
        self.catalog = catalog ?? ParamCatalog(engine: engine)
        self.project = project
        engineSampleRate = project.sessionSampleRate
        required = GraphDescriptionBuilder.paramRequirements(project, catalog: self.catalog)
        try allocateParams()
        writeParams()
        flush()
        pushLoop()
        pushArms()
        pushMidiArms()
    }

    /// Whether a structural change is waiting for its debounce window.
    public var hasPendingApply: Bool { pendingApply != nil }

    /// Brings the engine to `project`: params now, the graph within `debounce`.
    public func update(to project: Project) {
        guard !isInvalidated else { return }
        self.project = project
        pushSessionSampleRate()
        required = GraphDescriptionBuilder.paramRequirements(project, catalog: catalog)
        candidate = nil
        do {
            try allocateParams()
        } catch {
            // The nodes without slots get none; the engine rejects a strip without them, and
            // the next update tries again.
            Self.log.fault("param allocation failed: \(error)")
            lastError = error
        }
        writeParams()
        pushLoop()
        pushArms()
        pushMidiArms()
        let graph = GraphDescriptionBuilder.build(project, runtime: runtime)
        candidate = graph
        if graph != appliedGraph || hasUnusedParams() { scheduleApply() }
    }

    /// DW-097: starts loading `assets` into the engine, resolving relative paths against
    /// `folder` (MODEL-040). An asset whose file can't be found gets no job: it is offline
    /// (MODEL-046) and its clips render silence. Clip players pick a loaded asset up through its
    /// `assetLoaded` event (`handle(_:)`).
    public func loadAssets(_ assets: [AssetRef], folder: URL?) -> [(asset: ModelID, job: JobID?)] {
        assets.map { asset in
            guard let file = ProjectFolder.resolve(asset, in: folder),
                FileManager.default.isReadableFile(atPath: file.path)
            else { return (asset.id, nil) }
            // DW-077 (T-056): IO-034's peak cache lives in the project's disposable Cache/ (MODEL-040).
            let job = if let folder {
                engine.loadAsset(asset.id, path: file.path,
                                 peakCacheDirectory: folder.appendingPathComponent("Cache", isDirectory: true).path)
            } else {
                engine.loadAsset(asset.id, path: file.path)
            }
            return (asset.id, job == 0 ? nil : job)
        }
    }

    /// Applies a waiting structural change now (the CLI does this before rendering).
    public func flush() {
        pendingApply?.cancel()
        pendingApply = nil
        guard !isInvalidated else { return }
        var graph = candidate ?? GraphDescriptionBuilder.build(project, runtime: runtime)
        bumpChangedPlayers(&graph)
        if graph != appliedGraph {
            engine.applyGraph(graph)
            appliedGraph = graph
            lastError = nil
        }
        candidate = graph
        freeUnusedParams()
    }

    /// Waits until a scheduled apply has happened.
    public func settle() async {
        await pendingApply?.value
    }

    /// DW-072, DW-051: an asset finished loading, so every clip player using it needs a new
    /// instance that can see it. A rejected graph is kept in `lastError`.
    public func handle(_ event: EngineEvent) {
        guard !isInvalidated else { return }
        switch event.kind {
        case .assetLoaded:
            var bumped = false
            for track in project.tracks where track.kind == .audio {
                let usesAsset = track.clips.contains { if case .audio(let c) = $0 { c.assetID == event.subject } else { false } }
                guard usesAsset else { continue }
                runtime.configVersions[GraphNodeID.source(of: track.id), default: 0] &+= 1
                bumped = true
            }
            // DW-140: a sampler resolves its zones' assets when it is created, too.
            for slot in project.allDeviceSlots where slot.zones.contains(where: { $0.assetID == event.subject }) {
                runtime.configVersions[slot.id, default: 0] &+= 1
                bumped = true
            }
            if bumped {
                candidate = nil
                scheduleApply()
            }
        case .graphRejected:
            lastError = event.error
        case .recordingFinalized:
            // REC-004 (T-052): the store turns the take into ImportAsset + AddClip.
            if let take = event.recording { onRecordingFinalized?(take, event.error) }
        case .assetsReloaded where event.reload != nil:
            // DW-130 (T-056): the engine's session rate changed. Events can be older than the
            // engine's state (two changes before a poll), so its rate now is what counts.
            let rate = engine.telemetry().sampleRate
            guard rate > 0 else { return }
            engineSampleRate = rate
            if rate != project.sessionSampleRate { onEngineSampleRateChange?(rate) }
        default:
            break
        }
    }

    /// MODEL-005 `SetSessionSampleRate` (T-056): changes the engine's session rate to `rate` (the
    /// engine stops, rebuilds and re-converts the assets, IO-033). Throws, changing nothing, if
    /// the engine refuses (a device that can't run it). `ProjectStore.perform` calls it before it
    /// changes the document.
    public func setSessionSampleRate(_ rate: Double) throws(DAWError) {
        guard !isInvalidated, rate != engineSampleRate else { return }
        try engine.setSessionSampleRate(rate)
        engineSampleRate = rate
    }

    // MARK: Recording (T-052, REC-001..005)

    /// REC-001: starts or stops the transport's recording, with the recordings directory pushed
    /// first, so a take lands in the project's `Audio/Recordings/` (or the temporary folder of a
    /// project without one). Use it instead of `engine.setRecording`.
    public func setRecording(_ recording: Bool) {
        guard !isInvalidated else { return }
        if recording { pushRecordingDirectory() }
        engine.setRecording(recording)
    }

    /// REC-002: where takes of a project without a folder go: per project and per process under
    /// `$TMPDIR` (CONV §9), so parallel test runs never share it. A save copies them into
    /// `Audio/` (DW-124).
    public static func temporaryRecordingsDirectory(for project: Project) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("EmberStudio-Recordings", isDirectory: true)
            .appendingPathComponent("\(project.id.uuidString)-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    /// T-052: remembers an asset load (an imported take's) for `settleLoads`.
    public func trackLoad(_ job: JobID) {
        if job != 0 { pendingLoads.append(job) }
    }

    /// T-052: waits for the loads `trackLoad` remembered, so a render that follows hears the
    /// imported takes (DAWControl's render.offline does this before it settles the graph; their
    /// `assetLoaded` events then bump the clip players, DW-072).
    public func settleLoads(timeout: Duration = .seconds(60)) async {
        let jobs = pendingLoads
        pendingLoads = []
        for job in jobs { _ = await engine.waitForJob(job, timeout: timeout) }
    }

    /// REC-002: `<folder>/Audio/Recordings/`, or the temporary folder.
    public func recordingsDirectory() -> URL {
        if let folder = projectFolder() {
            return folder.appendingPathComponent("Audio", isDirectory: true)
                .appendingPathComponent("Recordings", isDirectory: true)
        }
        return Self.temporaryRecordingsDirectory(for: project)
    }

    private func pushRecordingDirectory() {
        let path = recordingsDirectory().path
        guard path != pushedRecordingDirectory else { return }
        engine.setRecordingDirectory(path)
        pushedRecordingDirectory = path
    }

    /// REC-001, REC-022: arming is structural; each change of an audio track's arm state or
    /// input pair is an `armInput` call (the engine rebuilds its recording session). A removed
    /// armed track is disarmed. MIDI tracks' arming is MIDI input (T-053), not device audio.
    private func pushArms() {
        var wanted: [NodeIDValue: UInt32] = [:]
        for track in project.tracks where track.kind == .audio && track.armed { wanted[track.id] = track.inputPair }
        guard wanted != pushedArms else { return }
        if !wanted.isEmpty { pushRecordingDirectory() }
        for (track, pair) in pushedArms.sorted(by: { $0.key < $1.key }) where wanted[track] == nil {
            engine.armInput(track: track, inputChannelPair: pair, armed: false)
        }
        for (track, pair) in wanted.sorted(by: { $0.key < $1.key }) where pushedArms[track] != pair {
            engine.armInput(track: track, inputChannelPair: pair, armed: true)
        }
        pushedArms = wanted
    }

    /// REC-011 (T-053): each armed MIDI track gets the MIDI input (`armMidiInput`), whatever its
    /// monitoring mode, and a track that loses the arm or goes away is disarmed.
    private func pushMidiArms() {
        let wanted = Set(project.tracks.lazy.filter { $0.kind == .midi && $0.armed }.map(\.id))
        guard wanted != pushedMidiArms else { return }
        for track in pushedMidiArms.subtracting(wanted).sorted() { engine.armMidiInput(track: track, armed: false) }
        for track in wanted.subtracting(pushedMidiArms).sorted() { engine.armMidiInput(track: track, armed: true) }
        pushedMidiArms = wanted
    }

    /// Drains the engine's events, handles them and returns them for the caller to act on too
    /// (BRIDGE-004: the app polls at 60 Hz, the CLI per tick).
    public func pollEvents() -> [EngineEvent] {
        let events = engine.pollEvents()
        for event in events { handle(event) }
        return events
    }

    /// Stops syncing and frees every slot. The graph the engine has keeps rendering until another
    /// one replaces it (its slots aren't reused while it does, DW-029).
    public func invalidate() {
        guard !isInvalidated else { return }
        pendingApply?.cancel()
        pendingApply = nil
        isInvalidated = true
        // T-052: an engine that outlives the sync doesn't keep recording for it.
        for (track, pair) in pushedArms.sorted(by: { $0.key < $1.key }) {
            engine.armInput(track: track, inputChannelPair: pair, armed: false)
        }
        pushedArms = [:]
        for track in pushedMidiArms.sorted() { engine.armMidiInput(track: track, armed: false) }  // T-053
        pushedMidiArms = []
        for range in runtime.params.values { engine.freeParams(range.first, count: range.count) }
        for range in retired { engine.freeParams(range.first, count: range.count) }
        runtime = RuntimeIDs()
        retired = []
        written = [:]
    }

    // MARK: Private

    /// T-056: a project whose rate the engine doesn't run yet (normally the store has already
    /// changed it, see `setSessionSampleRate`). A refusal is kept in `lastError`.
    private func pushSessionSampleRate() {
        guard project.sessionSampleRate != engineSampleRate else { return }
        do {
            try setSessionSampleRate(project.sessionSampleRate)
        } catch {
            Self.log.error("session rate \(self.project.sessionSampleRate) refused: \(error)")
            lastError = error
        }
    }

    /// DW-123: the transport follows `project.loop` on attach (a project just opened), after
    /// commands and after undo/redo. Only a change is pushed, so a loop set on the transport
    /// alone stays until the project's loop changes. Cleared means disabled at the old range.
    private func pushLoop() {
        guard project.loop != pushedLoop else { return }
        if let loop = project.loop {
            engine.setLoop(enabled: loop.isEnabled, start: loop.start, end: loop.end)
        } else if let old = pushedLoop {
            engine.setLoop(enabled: false, start: old.start, end: old.end)
        }
        pushedLoop = project.loop
    }

    private func scheduleApply() {
        if debounce <= .zero {
            flush()
            return
        }
        guard pendingApply == nil else { return }
        let delay = debounce
        pendingApply = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// MODEL-022: a range for every node that needs one and has none (or one of another size).
    private func allocateParams() throws(DAWError) {
        for (node, count) in required.sorted(by: { $0.key < $1.key }) where runtime.params[node]?.count != count {
            let first = try engine.allocateParams(count)
            if let old = runtime.params[node] { retired.append(old) }
            runtime.params[node] = .init(first: first, count: count)
            candidate = nil
        }
    }

    private func hasUnusedParams() -> Bool {
        if !retired.isEmpty { return true }
        return runtime.params.keys.contains { required[$0] == nil }
    }

    private func freeUnusedParams() {
        for (node, range) in runtime.params.sorted(by: { $0.key < $1.key }) where required[node] == nil {
            runtime.params[node] = nil
            retired.append(range)
        }
        for range in retired {
            engine.freeParams(range.first, count: range.count)
            for id in range.first..<(range.first &+ range.count) { written[id] = nil }
        }
        retired = []
    }

    /// Writes the slots whose value differs from the last write, in ParamID order.
    private func writeParams() {
        let values = GraphDescriptionBuilder.paramValues(
            project, runtime: runtime, catalog: catalog, metronomeSuppressed: isMetronomeSuppressed,
            pluginsBypassed: arePluginsBypassed)
        var changed: [(ParamID, Float)] = []
        // Bit patterns, so a NaN ("not set", PLUG-015) that was written isn't written again.
        for (id, value) in values where written[id]?.bitPattern != value.bitPattern { changed.append((id, value)) }
        changed.sort { $0.0 < $1.0 }
        for (id, value) in changed {
            engine.setParam(id, value)
            written[id] = value
        }
    }

    /// DW-072: a player whose clips or notes differ from the applied graph's, or any node whose
    /// `configJSON` does (DW-140), gets the next version, unless an asset load already bumped it.
    private func bumpChangedPlayers(_ graph: inout EngineGraph) {
        guard let applied = appliedGraph else { return }
        let oldNodes = Dictionary(applied.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let oldClips = Dictionary(grouping: applied.audioClips, by: \.player)
        let newClips = Dictionary(grouping: graph.audioClips, by: \.player)
        let oldNotes = Dictionary(grouping: applied.notes, by: \.player)
        let newNotes = Dictionary(grouping: graph.notes, by: \.player)
        var live = Set<NodeIDValue>()
        for i in graph.nodes.indices {
            let node = graph.nodes[i]
            live.insert(node.id)
            let isPlayer = node.kind == .audioClipPlayer || node.kind == .midiClipPlayer
            guard let old = oldNodes[node.id], old.kind == node.kind, old.configVersion == node.configVersion,
                old.configJSON != node.configJSON
                    || isPlayer && (oldClips[node.id] != newClips[node.id] || oldNotes[node.id] != newNotes[node.id])
            else { continue }
            graph.nodes[i].configVersion = node.configVersion &+ 1
            runtime.configVersions[node.id] = graph.nodes[i].configVersion
        }
        // A node that left the graph starts over as a new instance if it comes back.
        for id in runtime.configVersions.keys where !live.contains(id) { runtime.configVersions[id] = nil }
    }
}

extension EngineProtocol {
    /// 08 Interfaces (delta 4): the `applyGraph(project, runtime)` form, on top of `applyGraph(EngineGraph)`.
    @discardableResult
    public func applyGraph(_ project: Project, runtime: RuntimeIDs) -> UInt64 {
        applyGraph(GraphDescriptionBuilder.build(project, runtime: runtime))
    }
}
