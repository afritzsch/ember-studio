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

    private static let log = Logger(subsystem: "dev.emberstudio", category: "model")

    /// Allocates every param slot `project` needs, writes their values and applies its graph at
    /// once.
    public init(engine: any EngineProtocol, project: Project, debounce: Duration = EngineSync.defaultDebounce,
                catalog: ParamCatalog? = nil) throws(DAWError) {
        self.engine = engine
        self.debounce = debounce
        self.catalog = catalog ?? ParamCatalog(engine: engine)
        self.project = project
        required = GraphDescriptionBuilder.paramRequirements(project, catalog: self.catalog)
        try allocateParams()
        writeParams()
        flush()
        pushLoop()
    }

    /// Whether a structural change is waiting for its debounce window.
    public var hasPendingApply: Bool { pendingApply != nil }

    /// Brings the engine to `project`: params now, the graph within `debounce`.
    public func update(to project: Project) {
        guard !isInvalidated else { return }
        self.project = project
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
            let job = engine.loadAsset(asset.id, path: file.path)
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
        default:
            break
        }
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
        for range in runtime.params.values { engine.freeParams(range.first, count: range.count) }
        for range in retired { engine.freeParams(range.first, count: range.count) }
        runtime = RuntimeIDs()
        retired = []
        written = [:]
    }

    // MARK: Private

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
            project, runtime: runtime, catalog: catalog, metronomeSuppressed: isMetronomeSuppressed)
        var changed: [(ParamID, Float)] = []
        for (id, value) in values where written[id] != value { changed.append((id, value)) }
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
