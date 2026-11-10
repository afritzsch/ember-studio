/// MODEL-005 (T-074): moves the points at `ticks` of the lane for `target` by the same amount in
/// time and value (a drag). Nothing is clamped: a point leaving the timeline or 0…1, or landing
/// on a tick another point keeps, rejects the move. The inverse sets the lane back
/// (`SetAutomationLane`).
public struct MoveAutomationPoints: Command {
    public static let type = "MoveAutomationPoints"

    public var target: ParamTarget
    public var ticks: [Tick]
    public var deltaTicks: Int64
    public var deltaValue: Float

    public init(target: ParamTarget, ticks: [Tick], deltaTicks: Int64 = 0, deltaValue: Float = 0) {
        self.target = target
        self.ticks = ticks
        self.deltaTicks = deltaTicks
        self.deltaValue = deltaValue
    }

    public var label: String { ticks.count == 1 ? "Move Automation Point" : "Move Automation Points" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard !ticks.isEmpty else { throw .invalidArgument("no automation points given") }
        let moving = Set(ticks)
        guard moving.count == ticks.count else { throw .invalidArgument("an automation point tick is given twice") }
        guard deltaValue.isFinite, abs(deltaTicks) <= Tick.timelineEnd.raw else {
            throw .invalidArgument("the move is out of range")
        }
        let before = project.automationRestore(for: target, defaultChannel: 0)
        try project.updateAutomationLane(for: target) { (lane: inout AutomationLane) throws(DAWError) in
            let have = Set(lane.points.map(\.tick))
            if let missing = ticks.first(where: { !have.contains($0) }) {
                throw .invalidArgument("lane \(lane.id) has no point at tick \(missing.raw)")
            }
            var points: [AutomationPoint] = []
            for var point in lane.points {
                if moving.contains(point.tick) {
                    point.tick = Tick(point.tick.raw + deltaTicks)
                    point.value += deltaValue
                    try point.validate()
                }
                points.append(point)
            }
            guard Set(points.map(\.tick)).count == points.count else {
                throw .invalidArgument("moved automation points would share a tick with another point")
            }
            lane.points = points.sorted { $0.tick < $1.tick }
        }
        return before
    }
}
