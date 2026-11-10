/// MODEL-005 `AddAutomationPoint(s)` (T-074, AUTO-004): adds points to the lane for `target`,
/// creating the lane (mode `read`) if the target has none. Points may come in any order; a tick
/// given twice or already on the lane is rejected (nothing is replaced or clamped). Values are
/// normalized 0…1. The inverse sets the lane back as it was (`SetAutomationLane`), removing a
/// lane this command created.
///
/// JSON: `{"type": "AddAutomationPoints", "target": {…}, "points": [{"tick": 0, "value": 0.5}, …]}`.
public struct AddAutomationPoints: Command {
    public static let type = "AddAutomationPoints"

    public var target: ParamTarget
    public var points: [AutomationPoint]

    public init(target: ParamTarget, points: [AutomationPoint]) {
        self.target = target
        self.points = points
    }

    public var label: String { points.count == 1 ? "Add Automation Point" : "Add Automation Points" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        try addAutomationPoints(points, to: target, in: &project)
    }
}

/// The single-point form of `AddAutomationPoints` (MODEL-005 names both).
///
/// JSON: `{"type": "AddAutomationPoint", "target": {…}, "point": {"tick": 0, "value": 0.5}}`.
public struct AddAutomationPoint: Command {
    public static let type = "AddAutomationPoint"

    public var target: ParamTarget
    public var point: AutomationPoint

    public init(target: ParamTarget, point: AutomationPoint) {
        self.target = target
        self.point = point
    }

    public var label: String { "Add Automation Point" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        try addAutomationPoints([point], to: target, in: &project)
    }
}

private func addAutomationPoints(
    _ points: [AutomationPoint], to target: ParamTarget, in project: inout Project
) throws(DAWError) -> any Command {
    guard !points.isEmpty else { throw .invalidArgument("no automation points given") }
    for point in points { try point.validate() }
    guard Set(points.map(\.tick)).count == points.count else {
        throw .invalidArgument("an automation point tick is given twice")
    }
    let before = project.automationRestore(for: target, defaultChannel: project.automationOwner(of: target) ?? 0)
    _ = try project.automationLaneCreatingIfNeeded(for: target)
    try project.updateAutomationLane(for: target) { (lane: inout AutomationLane) throws(DAWError) in
        let taken = Set(lane.points.map(\.tick))
        if let clash = points.first(where: { taken.contains($0.tick) }) {
            throw .invalidArgument("lane \(lane.id) already has a point at tick \(clash.tick.raw)")
        }
        lane.points = (lane.points + points).sorted { $0.tick < $1.tick }
    }
    return before
}
