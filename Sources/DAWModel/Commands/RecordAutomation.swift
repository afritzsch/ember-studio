/// MODEL-005 / AUTO-006 (T-075, 07/11 "Contract delta (T-075)", docs/autobuild/DECISIONS.md
/// "T-075 gesture commit"): one recorded automation pass, committed as one command at gesture end
/// (touch), or at stop (latch, write).
///
/// The lane for `target` keeps its points before `from` and after `to`; those in `[from, to]` are
/// replaced by `points` (already thinned, AUTO-006). So that the curve outside the pass plays as
/// before, an existing lane gets anchor points one tick outside the pass, holding its old value
/// there: at `from − 1` (unless a kept point is there or `from` is 0) and at `to + 1` (unless a
/// kept point is there or `to` ends the timeline). The `to + 1` anchor is how `touch` returns to
/// the existing curve after release and how `latch`/`write` hand back to it after stop. An anchor
/// copies the curve of the old point governing it when that is linear or hold (exact), and is
/// linear inside an exponential segment (close: a sub-segment of an exponential is not the same
/// exponential). A lane created by the command (none for `target` yet) gets mode `mode` and no
/// anchors. The lane's mode is otherwise left as it is.
///
/// Checked like any input (MODEL-031): `mode` is touch, latch or write; `from ≤ to` on the
/// timeline; `points` non-empty, strictly increasing, inside `[from, to]`, values 0…1; the target
/// is automatable and a new lane may be created on it (DW-236). The inverse sets the lane back
/// exactly (`SetAutomationLane`), removing a lane the command created.
///
/// JSON: `{"type": "RecordAutomation", "target": {…}, "from": 0, "to": 1920, "mode": "touch",
/// "points": [{"tick": 0, "value": 0.5}, {"tick": 1920, "value": 0.8}]}`.
public struct RecordAutomation: Command {
    public static let type = "RecordAutomation"

    public var target: ParamTarget
    public var from: Tick
    public var to: Tick
    public var points: [AutomationPoint]
    public var mode: AutomationLane.Mode

    public init(target: ParamTarget, from: Tick, to: Tick, points: [AutomationPoint], mode: AutomationLane.Mode) {
        self.target = target
        self.from = from
        self.to = to
        self.points = points
        self.mode = mode
    }

    public var label: String { "Record Automation" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard mode == .touch || mode == .latch || mode == .write else {
            throw .invalidArgument("RecordAutomation mode must be touch, latch or write, not \(mode.rawValue)")
        }
        guard from.raw >= 0, from <= to, to <= Tick.timelineEnd else {
            throw .invalidArgument("the recorded range \(from.raw)…\(to.raw) is not on the timeline")
        }
        guard !points.isEmpty else { throw .invalidArgument("no automation points given") }
        for (i, point) in points.enumerated() {
            try point.validate()
            guard point.tick >= from, point.tick <= to else {
                throw .invalidArgument("recorded point at tick \(point.tick.raw) is outside \(from.raw)…\(to.raw)")
            }
            if i > 0, points[i - 1].tick >= point.tick {
                throw .invalidArgument("recorded points are not in strictly increasing tick order")
            }
        }
        let before = project.automationRestore(for: target, defaultChannel: project.automationOwner(of: target) ?? 0)
        let existed = project.automationLane(for: target) != nil
        _ = try project.automationLaneCreatingIfNeeded(for: target)
        let (from, to, recorded) = (self.from, self.to, self.points)
        try project.updateAutomationLane(for: target) { (lane: inout AutomationLane) throws(DAWError) in
            if !existed { lane.mode = mode }
            lane.points = Self.merge(old: lane, from: from, to: to, recorded: recorded)
        }
        return before
    }

    /// The lane's new points: `old` outside `[from, to]`, its anchors, and `recorded`.
    static func merge(old: AutomationLane, from: Tick, to: Tick, recorded: [AutomationPoint]) -> [AutomationPoint] {
        let kept = old.points.filter { $0.tick < from || $0.tick > to }
        var out = kept
        if !old.points.isEmpty {
            let keptTicks = Set(kept.map(\.tick))
            func anchor(_ tick: Tick) -> AutomationPoint? {
                guard let value = old.value(at: tick) else { return nil }
                var curve: AutomationPoint.Curve = .linear
                if let i = old.pointIndex(atOrBefore: tick), case .hold = old.points[i].curve { curve = .hold }
                return AutomationPoint(tick: tick, value: value, curve: curve)
            }
            if from.raw > 0, !keptTicks.contains(Tick(from.raw - 1)), let a = anchor(Tick(from.raw - 1)) { out.append(a) }
            if to < Tick.timelineEnd, !keptTicks.contains(Tick(to.raw + 1)), let a = anchor(Tick(to.raw + 1)) { out.append(a) }
        }
        out += recorded
        return out.sorted { $0.tick < $1.tick }
    }
}
