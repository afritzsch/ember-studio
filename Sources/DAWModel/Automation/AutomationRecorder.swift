import Foundation

/// AUTO-006/007 (T-075, docs/autobuild/DECISIONS.md "T-075 gesture commit", "T-075 stopped edit"):
/// records control gestures into automation lanes and decides what a control shows and does
/// around a lane. One per `ProjectStore` (the app's window model owns it), on the main actor.
///
/// Recording (AUTO-006) happens only while the transport plays and the target's lane is in
/// `touch`, `latch` or `write`. A *pass* captures `(tick, value)` points on the main thread, the
/// tick being the playhead (TIME-009, `EngineProtocol.transport()`), and is committed as **one**
/// `RecordAutomation` command, thinned with Ramer–Douglas–Peucker (ε = 0.5 % of the range):
///   - `touch`: a pass runs while the control is held; at release it is committed over
///     [grab, release] and the lane plays its existing curve again.
///   - `latch`: from the first grab the pass keeps writing, holding the last value after release,
///     until the transport stops; committed over [grab, stop].
///   - `write`: from play to stop the pass overwrites everything with the control's value (its
///     value at play if it is never touched); committed over [play, stop].
/// While a pass runs its lane is suspended in the engine (`setAutomationSuspended`), and the
/// control's values go straight to the target's param slots (`setParam`), not through `SetParam`:
/// the document's static value doesn't change and the pass is the gesture's only undo entry.
/// A loop wrap (the playhead jumping back) ends the pass at the last tick before it and starts
/// another at the new position: one command per pass of the loop.
///
/// Stopped (AUTO-007): a control on an enabled lane with points shows the lane's value at the
/// playhead (`displayedValue`). Moving it edits the point exactly at the playhead if there is one
/// (`stoppedEdit` performs `SetAutomationLane`, undoable; inside the caller's store gesture one
/// drag is one entry); otherwise the caller performs a plain `SetParam`, whose value the engine
/// holds until play or a locate (DW-237), and the control shows that value until the playhead
/// changes.
@MainActor
public final class AutomationRecorder {
    /// One running pass.
    public struct Pass: Equatable, Sendable {
        public var target: ParamTarget
        public var laneID: ModelID
        public var mode: AutomationLane.Mode
        public var from: Tick
        /// Unthinned, strictly increasing ticks.
        public var points: [AutomationPoint]
        /// The control's last value, normalized.
        public var lastValue: Float
        /// The newest tick the pass has seen (gesture or transport).
        public var lastTick: Tick
        /// The control is held (between `beginGesture` and `endGesture`).
        public var held: Bool
    }

    /// What `stoppedEdit` did.
    public enum StoppedEdit: Equatable, Sendable {
        /// No enabled lane with points, or the transport plays: the caller edits as usual.
        case none
        /// The lane's point at the playhead took the value (`SetAutomationLane`).
        case editedPoint(Tick)
        /// No point at the playhead: the caller performs its `SetParam`, which holds until the
        /// playhead changes (DW-237).
        case heldUntilPlayheadMoves
    }

    public let store: ProjectStore
    /// AUTO-006: RDP tolerance in normalized units.
    public var epsilon: Float = AutomationThinning.defaultEpsilon
    /// Running passes by target (`ui.state`).
    public private(set) var passes: [ParamTarget: Pass] = [:]
    /// The commands committed so far (newest last), for tests and diagnostics.
    public private(set) var committed: [RecordAutomation] = []
    /// AUTO-007: targets whose stopped `SetParam` holds, with the playhead it was made at.
    public private(set) var heldOverrides: [ParamTarget: Tick] = [:]

    /// The transport as last seen (`transportChanged`).
    public private(set) var lastTransport: TransportState?

    public init(store: ProjectStore) {
        self.store = store
        attachToEngine()
    }

    /// DW-277 (T-095): plugin-side edits reach this recorder through the store's engine sync.
    /// Called at init and at each transport poll, so a newly attached engine (handover) finds it.
    private func attachToEngine() {
        if let sync = store.engineSync, sync.automationRecorder !== self { sync.automationRecorder = self }
    }

    private var engine: (any EngineProtocol)? { store.engineSync?.engine }
    private var project: Project { store.project }

    /// The lane for `target` if it records (touch/latch/write).
    private func recordingLane(_ target: ParamTarget) -> AutomationLane? {
        guard let lane = project.automationLane(for: target)?.lane else { return nil }
        switch lane.mode {
        case .touch, .latch, .write: return lane
        case .read, .off: return nil
        }
    }

    /// The playhead and play state now: the engine's (TIME-009), else the last transport seen.
    private func now() -> (tick: Tick, playing: Bool) {
        if let t = engine?.transport() { return (t.tick, t.playing) }
        return (lastTransport?.tick ?? Tick(0), lastTransport?.playing ?? false)
    }

    // MARK: Gestures

    /// The control for `target` was grabbed with `value` (native units, as `SetParam` takes them).
    /// True if the gesture records: the caller then sends its movements to `move` instead of
    /// performing `SetParam`, and calls `endGesture` at release. `at` overrides the playhead (tests).
    @discardableResult
    public func beginGesture(_ target: ParamTarget, value: Float, at tick: Tick? = nil, playing: Bool? = nil) -> Bool {
        let n = now()
        let tick = tick ?? n.tick
        guard playing ?? n.playing, let lane = recordingLane(target) else { return false }
        let v = normalized(target, value)
        if var pass = passes[target] {
            // latch after release, write: the value held since the last point holds up to the grab.
            if !pass.held, tick.raw - 1 > pass.points.last!.tick.raw { capture(target, pass.lastValue, at: Tick(tick.raw - 1)) }
            pass = passes[target] ?? pass
            pass.held = true
            passes[target] = pass
            capture(target, v, at: tick)
        } else {
            start(target, lane: lane, value: v, at: tick, held: true)
        }
        writeSlots(target, native: value)
        return true
    }

    /// A movement of a recording gesture to `value` (native).
    public func move(_ target: ParamTarget, value: Float, at tick: Tick? = nil) {
        guard passes[target]?.held == true else { return }
        capture(target, normalized(target, value), at: tick ?? now().tick)
        writeSlots(target, native: value)
    }

    /// Release. `touch` commits its pass now; `latch` and `write` keep it (holding the last value)
    /// until stop.
    public func endGesture(_ target: ParamTarget, at tick: Tick? = nil) {
        guard var pass = passes[target], pass.held else { return }
        let tick = tick ?? now().tick
        pass.held = false
        passes[target] = pass
        if pass.mode == .touch {
            capture(target, pass.lastValue, at: tick)
            finish(target)
        }
    }

    /// Whether a pass on `target` runs now.
    public func isRecording(_ target: ParamTarget) -> Bool { passes[target] != nil }

    // MARK: Transport

    /// Feed every transport poll (the app's display-rate poll; tests call it directly). Starts
    /// `write` passes at play, commits every pass at stop, splits passes at a loop wrap, and ends
    /// AUTO-007's held stopped values when the playhead changes.
    public func transportChanged(_ transport: TransportState) {
        attachToEngine()  // DW-277
        let previous = lastTransport
        lastTransport = transport
        // AUTO-007: a held stopped value lasts until the playhead changes or play starts.
        if previous?.tick != transport.tick || previous?.playing != transport.playing { heldOverrides = [:] }
        let wasPlaying = previous?.playing ?? false
        if transport.playing {
            if !wasPlaying { startWritePasses(at: transport.tick) }
            for target in passes.keys.sorted(by: Self.order) {
                guard let pass = passes[target] else { continue }
                if transport.tick < pass.lastTick {
                    // A loop wrap or a locate while playing: the pass ends where it was.
                    let value = pass.lastValue, held = pass.held, mode = pass.mode
                    finish(target, at: pass.lastTick)
                    if held || mode != .touch, let lane = recordingLane(target) {
                        start(target, lane: lane, value: value, at: transport.tick, held: held)
                    }
                } else {
                    passes[target]?.lastTick = transport.tick
                }
            }
        } else if wasPlaying {
            let stopTick = previous.map { Swift.max($0.tick, transport.tick) } ?? transport.tick
            for target in passes.keys.sorted(by: Self.order) {
                finish(target, at: Swift.max(passes[target]?.lastTick ?? stopTick, stopTick))
            }
        }
    }

    /// Ends every pass without committing and resumes their lanes (a document replaced).
    public func cancelAll() {
        for (_, pass) in passes { engine?.setAutomationSuspended(laneID: pass.laneID, false) }
        passes = [:]
        heldOverrides = [:]
    }

    // MARK: Stopped (AUTO-007)

    /// What a control on `target` shows: its `staticValue` (the document's), unless an enabled
    /// lane with points drives it. Then: a running pass's value; else, stopped, a held `SetParam`
    /// at this playhead; else the lane's value at `playhead`. Native units.
    public func displayedValue(_ target: ParamTarget, staticValue: Float, playhead: Tick) -> Float {
        if let pass = passes[target] { return denormalized(target, pass.lastValue) }
        guard let lane = project.automationLane(for: target)?.lane, lane.isEnabled,
              let v = lane.value(at: playhead) else { return staticValue }
        if let held = heldOverrides[target], held == playhead, lastTransport?.playing != true { return staticValue }
        return denormalized(target, v)
    }

    /// Whether `target` has an enabled lane with points (its control follows the lane).
    public func isAutomated(_ target: ParamTarget) -> Bool {
        guard let lane = project.automationLane(for: target)?.lane else { return false }
        return lane.isEnabled && !lane.points.isEmpty
    }

    /// AUTO-007: the control for `target` moved to `value` (native) while stopped. Edits the lane's
    /// point at the playhead if there is one; otherwise tells the caller to perform its `SetParam`
    /// (and remembers it, so the control shows that value until the playhead changes).
    @discardableResult
    public func stoppedEdit(_ target: ParamTarget, value: Float, at tick: Tick? = nil) throws(DAWError) -> StoppedEdit {
        let n = now()
        guard !(n.playing && tick == nil), let (channel, lane) = project.automationLane(for: target),
              lane.isEnabled, !lane.points.isEmpty else { return .none }
        let tick = tick ?? n.tick
        guard let i = lane.points.firstIndex(where: { $0.tick == tick }) else {
            heldOverrides[target] = tick
            return .heldUntilPlayheadMoves
        }
        var edited = lane
        edited.points[i].value = normalized(target, value)
        if edited != lane { try store.perform(SetAutomationLane(channel: channel, target: target, lane: edited)) }
        return .editedPoint(tick)
    }

    // MARK: Plugin editors (DW-277)

    /// DW-277 (T-095, DECISIONS "T-095 app decisions"): an edit from a plugin's own editor (T-063,
    /// `pluginParamEdited`) of hosted param `index` of `slot`, treated like a UI control's gesture:
    /// `begin` grabs, `value` moves, `end` releases (touch/latch/write per AUTO-006), and an
    /// ungestured value (a menu, a preset) is a grab and release at once. Stopped on an automated
    /// param, a value edits the lane's point under the playhead (AUTO-007).
    ///
    /// Returns true when it took the edit; otherwise the caller (`EngineSync`) hands it to
    /// `PluginEditRecorder`, which performs `SetParam` as before (its gesture is still one undo entry,
    /// and a stopped point edit inside it joins that entry).
    @discardableResult
    public func pluginEdited(slot: NodeIDValue, edit: PluginParamEdit, at tick: Tick? = nil) -> Bool {
        guard edit.index >= 0, project.allDeviceSlots.contains(where: { $0.id == slot && $0.isPlugin }) else { return false }
        let target = ParamTarget.device(slot: slot, index: edit.index)
        let held = passes[target]?.held == true
        switch edit.phase {
        case .begin:
            if held { return true }
            guard edit.value.isFinite else { return false }
            return beginGesture(target, value: edit.value, at: tick)
        case .value:
            guard edit.value.isFinite else { return false }
            if held {
                move(target, value: edit.value, at: tick)
                return true
            }
            if beginGesture(target, value: edit.value, at: tick) {
                // No gesture of its own: grabbed and released at once.
                endGesture(target, at: tick)
                return true
            }
            guard !now().playing, isAutomated(target) else { return false }
            if case .editedPoint = (try? stoppedEdit(target, value: edit.value, at: tick)) ?? .none { return true }
            return false
        case .end:
            guard held else { return false }
            endGesture(target, at: tick)
            return true
        }
    }

    // MARK: Internals

    private static func order(_ a: ParamTarget, _ b: ParamTarget) -> Bool { "\(a)" < "\(b)" }

    private func normalized(_ target: ParamTarget, _ native: Float) -> Float {
        project.automationMapping(for: target, catalog: catalog).normalize(native)
    }

    private func denormalized(_ target: ParamTarget, _ value: Float) -> Float {
        project.automationMapping(for: target, catalog: catalog).denormalize(value)
    }

    /// The engine's ParamInfo, else the built-in catalog (test engines publish none).
    private var catalog: ParamCatalog {
        if let catalog = store.engineSync?.catalog, !catalog.infos.isEmpty { return catalog }
        return .builtin
    }

    private func start(_ target: ParamTarget, lane: AutomationLane, value: Float, at tick: Tick, held: Bool) {
        let tick = Tick(Swift.max(tick.raw, 0))
        passes[target] = Pass(target: target, laneID: lane.id, mode: lane.mode, from: tick,
                              points: [AutomationPoint(tick: tick, value: value)], lastValue: value, lastTick: tick, held: held)
        engine?.setAutomationSuspended(laneID: lane.id, true)
    }

    /// `write` lanes record from play: each starts a pass at the control's value now (the engine
    /// slot's, which is what the control holds), or the lane's value at `tick` without an engine.
    private func startWritePasses(at tick: Tick) {
        var lanes: [AutomationLane] = []
        project.forEachAutomationLane { lane, _ in if lane.mode == .write { lanes.append(lane) } }
        for lane in lanes where passes[lane.target] == nil {
            var value = lane.value(at: tick) ?? 0
            if let engine, let sync = store.engineSync, let slot = Self.slots(for: lane.target, in: project, runtime: sync.runtime).first {
                value = normalized(lane.target, engine.getParam(slot))
            }
            start(lane.target, lane: lane, value: value, at: tick, held: false)
        }
    }

    /// Appends a point; the same tick as the last replaces its value.
    private func capture(_ target: ParamTarget, _ value: Float, at tick: Tick) {
        guard var pass = passes[target] else { return }
        if tick < pass.lastTick, transportIsPlaying {
            // The playhead went back (a wrap the poll hasn't shown yet): split the pass.
            let held = pass.held
            finish(target, at: pass.lastTick)
            if let lane = recordingLane(target) { start(target, lane: lane, value: value, at: tick, held: held) }
            return
        }
        let tick = Swift.max(tick, pass.points.last!.tick)
        if pass.points.last!.tick == tick {
            pass.points[pass.points.count - 1].value = value
        } else {
            pass.points.append(AutomationPoint(tick: tick, value: value))
        }
        pass.lastValue = value
        pass.lastTick = Swift.max(pass.lastTick, tick)
        passes[target] = pass
    }

    private var transportIsPlaying: Bool { lastTransport?.playing ?? now().playing }

    /// Commits the pass on `target` up to `end` (its last tick by default) and resumes its lane.
    private func finish(_ target: ParamTarget, at end: Tick? = nil) {
        guard var pass = passes.removeValue(forKey: target) else { return }
        let to = Swift.max(end ?? pass.lastTick, pass.points.last!.tick)
        if pass.points.last!.tick < to { pass.points.append(AutomationPoint(tick: to, value: pass.lastValue)) }
        let command = RecordAutomation(target: target, from: pass.from, to: to,
                                       points: AutomationThinning.thin(pass.points, epsilon: epsilon), mode: pass.mode)
        do {
            try store.perform(command)
            committed.append(command)
        } catch {
            // The target or lane went away mid-pass (undo, a removed send): nothing to record.
        }
        engine?.setAutomationSuspended(laneID: pass.laneID, false)
    }

    /// While a pass runs the control writes its target's slots directly (the lane is suspended).
    private func writeSlots(_ target: ParamTarget, native: Float) {
        guard let engine, let sync = store.engineSync else { return }
        for slot in Self.slots(for: target, in: project, runtime: sync.runtime) { engine.setParam(slot, native) }
    }

    /// The param slots a lane on `target` drives (GraphDescriptionBuilder.automation): one, or
    /// for a strip mute the strip's and each send's mute slot (MIX-007).
    static func slots(for target: ParamTarget, in project: Project, runtime: RuntimeIDs) -> [ParamID] {
        switch target {
        case .strip(let channel, .gain): return [runtime.stripParam(channel, ParamLayout.Strip.gain)].compactMap { $0 }
        case .strip(let channel, .pan): return [runtime.stripParam(channel, ParamLayout.Strip.pan)].compactMap { $0 }
        case .strip(let channel, .mute):
            let sends = (project.sends(of: channel) ?? []).map { runtime.sendMuteParam($0.id) }
            return ([runtime.stripParam(channel, ParamLayout.Strip.mute)] + sends).compactMap { $0 }
        case .strip: return []
        case .sendLevel(let send): return [runtime.sendLevelParam(send)].compactMap { $0 }
        case .device(let slot, let index):
            guard index >= 0 else { return [] }
            return [runtime.deviceParam(slot, UInt32(index))].compactMap { $0 }
        }
    }
}
