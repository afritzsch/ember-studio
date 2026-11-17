import CoreGraphics
import DAWModel
import Foundation
import Observation

/// UI-015 (T-075): one automation lane row of the arrange view, under its track.
struct LaneRow: Equatable {
    var trackIndex: Int
    var trackID: NodeIDValue
    /// The display row (TimelineGeometry).
    var row: Int
    var lane: AutomationLane
    var name: String
}

/// A target a track can be automated by (the "+ Lane" menu), automatable ones only (DW-236).
struct LaneTargetChoice: Equatable {
    var target: ParamTarget
    /// `gain`, `pan`, `mute`, `send.<id>`, `device.<slot>.<index>` (control ids).
    var key: String
    var name: String
}

/// UI-015 / AUTO-006 / AUTO-007 (T-075): the arrange view's automation lanes and the window's
/// automation recorder.
///   - Lanes show under their track while the track is expanded (`track.<id>.automation`); each
///     lane is a row of the canvas (`TimelineGeometry.trackRows`), with a header holding its mode
///     (off/read/touch/latch/write), "add point" and "remove lane".
///   - On a lane row a click adds a point (snapped, value from the height) and dragging moves it;
///     pressing a point drags it (time and value, kept between its neighbours); a double-click or
///     ⌥-click deletes it. Each press is one undo entry (MODEL-003).
///   - `recorder` (DAWModel `AutomationRecorder`) is fed every transport poll; the mixer routes its
///     gestures through `beginControl`/`moveControl`/`endControl`, and shows `displayed` values.
@Observable
@MainActor
final class AutomationLanesModel {
    /// Lane rows are as tall as track rows (TimelineGeometry keeps one row height).
    static let valuePadding = 6.0
    static let pointRadius = 4.0

    @ObservationIgnored weak var window: ProjectWindowModel?

    /// Tracks whose lanes show.
    var expanded: Set<NodeIDValue> = []
    /// The label of the lane gesture in progress (`ui.state`).
    private(set) var activeGesture: String?

    @ObservationIgnored private var cachedRecorder: AutomationRecorder?
    @ObservationIgnored private var drag: PointDrag?

    private struct PointDrag {
        var target: ParamTarget
        var down: CGPoint
        /// The point's tick now (MoveAutomationPoints addresses points by tick).
        var tick: Tick
        var startTick: Tick
        var startValue: Float
        var started: Bool
        var label: String
        var gestureOpen: Bool
    }

    init() {}

    private var store: ProjectStore? { window?.store }
    private var project: Project { window?.project ?? Project() }

    // MARK: Recorder (AUTO-006/007)

    /// The window's recorder, made for its current store (a replaced document gets a new one).
    var recorder: AutomationRecorder? {
        guard let store else { return nil }
        if let cachedRecorder, cachedRecorder.store === store { return cachedRecorder }
        cachedRecorder?.cancelAll()
        let recorder = AutomationRecorder(store: store)
        cachedRecorder = recorder
        return recorder
    }

    /// Every transport poll (the window's).
    func transportPolled(_ transport: TransportState) {
        recorder?.transportChanged(transport)
    }

    /// The document or engine went away: running passes end without a commit.
    func documentReplaced() {
        finishDrag()
        cachedRecorder?.cancelAll()
        cachedRecorder = nil
        expanded = []
    }

    /// AUTO-007: what a control on `target` shows (native units): the lane's value at the
    /// playhead while it drives the control, else `staticValue`. Reads the transport (and so
    /// observes it) only for an automated target.
    func displayed(_ target: ParamTarget, _ staticValue: Float) -> Float {
        guard let recorder, recorder.isAutomated(target) || recorder.isRecording(target), let window else { return staticValue }
        return recorder.displayedValue(target, staticValue: staticValue, playhead: window.transport.tick)
    }

    /// A control on `target` was grabbed or moved to `value` (native). True if automation took
    /// it: a recording gesture (playing, lane in touch/latch/write: the caller must not perform
    /// its own command) or, stopped, the edit of the lane point under the playhead (AUTO-007).
    /// False: the caller performs its usual command (a stopped `SetParam` then holds until the
    /// playhead moves, DW-237).
    func controlMoved(_ target: ParamTarget, value: Float) -> Bool {
        guard let recorder, let window else { return false }
        if recorder.passes[target]?.held == true {
            recorder.move(target, value: value)
            return true
        }
        if recorder.beginGesture(target, value: value) { return true }
        guard !window.isPlaying, recorder.isAutomated(target) else { return false }
        if case .editedPoint = (try? recorder.stoppedEdit(target, value: value)) ?? .none { return true }
        return false
    }

    /// The control on `target` was released.
    func controlReleased(_ target: ParamTarget) {
        recorder?.endGesture(target)
    }

    // MARK: Layout (UI-015)

    /// The rows of the arrange view: each track's row, then its lanes if expanded. `trackRows` is
    /// empty while no lane row shows (track index = row).
    var layout: (trackRows: [Int], rowTotal: Int?, lanes: [LaneRow]) {
        let tracks = project.tracks
        guard tracks.contains(where: { expanded.contains($0.id) && !$0.automation.isEmpty }) else { return ([], nil, []) }
        var rows: [Int] = []
        var lanes: [LaneRow] = []
        var r = 0
        for (i, track) in tracks.enumerated() {
            rows.append(r)
            r += 1
            guard expanded.contains(track.id) else { continue }
            for lane in track.automation {
                lanes.append(LaneRow(trackIndex: i, trackID: track.id, row: r, lane: lane, name: name(of: lane.target)))
                r += 1
            }
        }
        return (rows, r, lanes)
    }

    /// The lane rows of track `id` (expanded or not: empty when collapsed).
    func lanes(of trackID: NodeIDValue) -> [LaneRow] { layout.lanes.filter { $0.trackID == trackID } }

    func lane(atRow row: Int) -> LaneRow? { layout.lanes.first { $0.row == row } }

    // MARK: Names and choices

    func name(of target: ParamTarget) -> String {
        switch target {
        case .strip(_, .gain): return "Volume"
        case .strip(_, .pan): return "Pan"
        case .strip(_, .mute): return "Mute"
        case .strip(_, let param): return param.rawValue.capitalized
        case .sendLevel(let send):
            let bus = project.sendLocation(send).flatMap { location in
                project.sends(of: location.channel)?.first { $0.id == send }
            }.flatMap { s in project.buses.first { $0.id == s.target }?.name }
            return "Send → \(bus ?? "\(send)")"
        case .device(let slotID, let index):
            var slotName = "Device \(slotID)"
            var paramName = "Param \(index)"
            project.forEachDeviceSlot { slot, _ in
                guard slot.id == slotID else { return }
                switch slot.kind {
                case .builtin(let kind):
                    slotName = kind.rawValue.capitalized
                    if let info = catalog.info(kind, index) { paramName = info.name }
                case .au(let au): slotName = au.name
                case .vst3(let vst): slotName = vst.name
                }
            }
            return "\(slotName) \(paramName)"
        }
    }

    /// The engine's ParamInfo (DW-236), else the built-in catalog (test engines publish none).
    private var catalog: ParamCatalog {
        if let catalog = store?.engineSync?.catalog, !catalog.infos.isEmpty { return catalog }
        return .builtin
    }

    /// DW-236: the targets of `track` a lane may drive, without one yet: strip volume, pan, mute,
    /// each send's level, and each built-in device's automatable params (hosted plugins' params
    /// aren't listed here; a lane on one can come from `dawctl`).
    func choices(for track: Track) -> [LaneTargetChoice] {
        var out: [LaneTargetChoice] = [
            .init(target: .strip(channel: track.id, param: .gain), key: "gain", name: "Volume"),
            .init(target: .strip(channel: track.id, param: .pan), key: "pan", name: "Pan"),
            .init(target: .strip(channel: track.id, param: .mute), key: "mute", name: "Mute"),
        ]
        for send in track.sends {
            out.append(.init(target: .sendLevel(send: send.id), key: "send.\(send.id)", name: name(of: .sendLevel(send: send.id))))
        }
        for slot in [track.instrument].compactMap({ $0 }) + track.inserts {
            guard case .builtin(let kind) = slot.kind, let rows = catalog.infos[kind] else { continue }
            for index in rows.keys.sorted() where catalog.isAutomatable(kind, index) {
                let target = ParamTarget.device(slot: slot.id, index: index)
                out.append(.init(target: target, key: "device.\(slot.id).\(index)", name: name(of: target)))
            }
        }
        return out.filter { project.automationLane(for: $0.target) == nil }
    }

    // MARK: Actions

    func toggleExpanded(_ trackID: NodeIDValue) {
        if expanded.contains(trackID) { expanded.remove(trackID) } else { expanded.insert(trackID) }
    }

    /// A new, empty lane (mode read) on `target`; the track expands to show it.
    func addLane(_ target: ParamTarget, on trackID: NodeIDValue) {
        perform(SetAutomationMode(target: target, mode: .read), label: "Add Lane")
        expanded.insert(trackID)
    }

    func setMode(_ target: ParamTarget, _ mode: AutomationLane.Mode) {
        guard project.automationLane(for: target)?.lane.mode != mode else { return }
        perform(SetAutomationMode(target: target, mode: mode), label: "Set Automation Mode")
    }

    func removeLane(_ target: ParamTarget) {
        guard let channel = project.automationLane(for: target)?.channel else { return }
        perform(SetAutomationLane(channel: channel, target: target, lane: nil), label: "Remove Lane")
    }

    /// A point at the playhead holding the lane's value there (the control's value for an empty
    /// lane). Nothing if a point is there already.
    func addPointAtPlayhead(_ target: ParamTarget) {
        guard let window, let lane = project.automationLane(for: target)?.lane else { return }
        let tick = Tick(max(window.arrange.playheadTick().raw, 0))
        guard !lane.points.contains(where: { $0.tick == tick }) else { return }
        let value = lane.value(at: tick) ?? project.automationMapping(for: target, catalog: catalog).normalize(staticValue(target))
        perform(AddAutomationPoint(target: target, point: AutomationPoint(tick: tick, value: value)), label: "Add Automation Point")
    }

    /// The document's own value of `target` (what `SetParam` last set).
    func staticValue(_ target: ParamTarget) -> Float {
        switch target {
        case .strip(let channel, let param):
            guard let strip = project.strip(of: channel) else { return 0 }
            switch param {
            case .gain: return strip.gain
            case .pan: return strip.pan
            case .mute: return strip.mute ? 1 : 0
            case .solo: return strip.solo ? 1 : 0
            case .phase: return strip.phaseInvert ? 1 : 0
            }
        case .sendLevel(let send):
            guard let channel = project.sendLocation(send)?.channel else { return 0 }
            return project.sends(of: channel)?.first { $0.id == send }?.level ?? 0
        case .device(let slotID, let index):
            var value: Float = 0
            project.forEachDeviceSlot { slot, _ in
                if slot.id == slotID, let v = slot.params.first(where: { $0.index == index })?.value { value = v }
            }
            return value
        }
    }

    private func perform(_ command: any Command, label: String) {
        guard let window else { return }
        do {
            try window.store.perform(command)
        } catch {
            window.toasts.post(.error, .error, title: "\(label) failed", message: error.description)
        }
    }

    // MARK: Canvas (UI-015)

    /// The rectangle a lane's values span in view coordinates (its row less the padding).
    func valueRect(row: Int, geometry g: TimelineGeometry) -> CGRect {
        CGRect(x: 0, y: g.rowY(row) + Self.valuePadding, width: g.size.width,
               height: max(g.trackHeight - 2 * Self.valuePadding, 1))
    }

    func y(of value: Float, row: Int, geometry g: TimelineGeometry) -> Double {
        let r = valueRect(row: row, geometry: g)
        return r.maxY - Double(value) * r.height
    }

    func value(atY y: Double, row: Int, geometry g: TimelineGeometry) -> Float {
        let r = valueRect(row: row, geometry: g)
        return Float(min(max((r.maxY - y) / r.height, 0), 1))
    }

    /// The lane under `point`, if it is on a lane row.
    func laneHit(_ point: CGPoint, geometry g: TimelineGeometry) -> LaneRow? {
        guard let row = g.row(atY: point.y) else { return nil }
        return lane(atRow: row)
    }

    /// The point of `lane` under `p` (within the point radius plus a little slack).
    func pointHit(_ p: CGPoint, lane: LaneRow, geometry g: TimelineGeometry) -> AutomationPoint? {
        lane.lane.points.last { point in
            abs(g.x(point.tick) - p.x) <= Self.pointRadius + 2 && abs(y(of: point.value, row: lane.row, geometry: g) - p.y) <= Self.pointRadius + 2
        }
    }

    /// Whether a lane gesture is armed or running (the arrange model routes drags here).
    var isDragging: Bool { drag != nil }

    /// A press on a lane row: drags the point under it, or adds one there and drags it. ⌥ deletes
    /// the point under it. True if the press was on a lane row.
    func mouseDown(at p: CGPoint, modifiers: CanvasModifiers, geometry g: TimelineGeometry, snap: (Tick) -> Tick) -> Bool {
        guard let row = laneHit(p, geometry: g), let store else { return false }
        finishDrag()
        let target = row.lane.target
        if let point = pointHit(p, lane: row, geometry: g) {
            if modifiers.contains(.option) {
                perform(RemoveAutomationPoints(target: target, ticks: [point.tick]), label: "Delete Automation Point")
                return true
            }
            drag = PointDrag(target: target, down: p, tick: point.tick, startTick: point.tick, startValue: point.value,
                             started: false, label: "Move Automation Point", gestureOpen: false)
            return true
        }
        var tick = Tick(max(g.tick(atX: p.x).raw, 0))
        if !modifiers.contains(.command) { tick = snap(tick) }
        guard !row.lane.points.contains(where: { $0.tick == tick }) else { return true }
        let value = self.value(atY: p.y, row: row.row, geometry: g)
        store.beginGesture("Add Automation Point")
        activeGesture = "Add Automation Point"
        do {
            try store.perform(AddAutomationPoint(target: target, point: AutomationPoint(tick: tick, value: value)))
        } catch {
            store.endGesture()
            activeGesture = nil
            window?.toasts.post(.error, .error, title: "Add Automation Point failed", message: error.description)
            return true
        }
        drag = PointDrag(target: target, down: p, tick: tick, startTick: tick, startValue: value, started: true,
                         label: "Add Automation Point", gestureOpen: true)
        return true
    }

    func mouseDragged(to p: CGPoint, modifiers: CanvasModifiers, geometry g: TimelineGeometry, snap: (Tick) -> Tick) {
        guard var drag, let store else { return }
        if !drag.started {
            guard hypot(p.x - drag.down.x, p.y - drag.down.y) >= ArrangeModel.dragThreshold else { return }
            drag.started = true
        }
        if !drag.gestureOpen {
            store.beginGesture(drag.label)
            drag.gestureOpen = true
            activeGesture = drag.label
        }
        guard let lane = project.automationLane(for: drag.target)?.lane,
              let index = lane.points.firstIndex(where: { $0.tick == drag.tick }) else { self.drag = drag; return }
        // Time: relative to the grab, snapped, kept strictly between the neighbours.
        var tick = drag.startTick.raw + g.ticks(forWidth: p.x - drag.down.x)
        if !modifiers.contains(.command) { tick = snap(Tick(tick)).raw }
        let lo = index > 0 ? lane.points[index - 1].tick.raw + 1 : 0
        let hi = index + 1 < lane.points.count ? lane.points[index + 1].tick.raw - 1 : Tick.timelineEnd.raw
        tick = min(max(tick, lo), hi)
        let row = layout.lanes.first { $0.lane.id == lane.id }?.row
        let valueSpan = row.map { valueRect(row: $0, geometry: g).height } ?? g.trackHeight
        let value = min(max(drag.startValue - Float((p.y - drag.down.y) / valueSpan), 0), 1)
        let current = lane.points[index]
        if tick != current.tick.raw || value != current.value {
            // The lane as a whole (exact values; a float delta could leave 0…1 by an ulp and be refused).
            var edited = lane
            edited.points[index] = AutomationPoint(tick: Tick(tick), value: value, curve: current.curve)
            if let channel = project.automationLane(for: drag.target)?.channel,
               (try? store.perform(SetAutomationLane(channel: channel, target: drag.target, lane: edited))) != nil {
                drag.tick = Tick(tick)
            }
        }
        self.drag = drag
    }

    func mouseUp() { finishDrag() }

    /// A double-click on a lane point deletes it. True if it did.
    func doubleClick(at p: CGPoint, geometry g: TimelineGeometry) -> Bool {
        guard let row = laneHit(p, geometry: g) else { return false }
        finishDrag()
        // The first click of the pair may have added this point: undo puts the lane back instead.
        if let point = pointHit(p, lane: row, geometry: g) {
            perform(RemoveAutomationPoints(target: row.lane.target, ticks: [point.tick]), label: "Delete Automation Point")
        }
        return true
    }

    /// Ends the lane gesture: one undo entry (none if nothing changed).
    func finishDrag() {
        if let drag, drag.gestureOpen { store?.endGesture() }
        drag = nil
        if activeGesture != nil { activeGesture = nil }
    }

    // MARK: Controls (UI-052)

    /// Per track: `track.<id>.automation` (show lanes); while shown, `track.<id>.automation.add.<key>`
    /// for each automatable target without a lane; per shown lane `automation.lane.<id>.mode.<mode>`
    /// (toggles, the lane's mode on), `.addPoint` (at the playhead) and `.remove`.
    var controls: [UIControl] {
        var controls: [UIControl] = []
        let shown = layout.lanes
        for track in project.tracks {
            let isExpanded = expanded.contains(track.id)
            controls.append(.toggle("track.\(track.id).automation", "Show Automation of \(track.name)", isOn: isExpanded) { [weak self] in
                self?.toggleExpanded(track.id)
            })
            guard isExpanded else { continue }
            for choice in choices(for: track) {
                controls.append(.button("track.\(track.id).automation.add.\(choice.key)", "Add \(choice.name) Lane") { [weak self] in
                    self?.addLane(choice.target, on: track.id)
                })
            }
        }
        for row in shown {
            controls += laneControls(row)
        }
        return controls
    }

    func laneControls(_ row: LaneRow) -> [UIControl] {
        let target = row.lane.target
        let id = row.lane.id
        var controls: [UIControl] = AutomationLane.Mode.allCases.map { mode in
            .toggle("automation.lane.\(id).mode.\(mode.rawValue)", "\(row.name) Automation \(mode.rawValue.capitalized)",
                    isOn: row.lane.mode == mode) { [weak self] in self?.setMode(target, mode) }
        }
        controls.append(.button("automation.lane.\(id).addPoint", "Add \(row.name) Point at Playhead") { [weak self] in
            self?.addPointAtPlayhead(target)
        })
        controls.append(.button("automation.lane.\(id).remove", "Remove \(row.name) Lane") { [weak self] in self?.removeLane(target) })
        return controls
    }
}
