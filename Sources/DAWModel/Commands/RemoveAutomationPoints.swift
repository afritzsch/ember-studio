/// MODEL-005 (T-074): removes the points at `ticks` from the lane for `target`. Every tick must be
/// a point of the lane, once. The lane stays (with its mode) even when it is left empty. The
/// inverse sets the lane back (`SetAutomationLane`).
public struct RemoveAutomationPoints: Command {
    public static let type = "RemoveAutomationPoints"

    public var target: ParamTarget
    public var ticks: [Tick]

    public init(target: ParamTarget, ticks: [Tick]) {
        self.target = target
        self.ticks = ticks
    }

    public var label: String { ticks.count == 1 ? "Delete Automation Point" : "Delete Automation Points" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard !ticks.isEmpty else { throw .invalidArgument("no automation points given") }
        let gone = Set(ticks)
        guard gone.count == ticks.count else { throw .invalidArgument("an automation point tick is given twice") }
        let before = project.automationRestore(for: target, defaultChannel: 0)
        try project.updateAutomationLane(for: target) { (lane: inout AutomationLane) throws(DAWError) in
            let have = Set(lane.points.map(\.tick))
            if let missing = ticks.first(where: { !have.contains($0) }) {
                throw .invalidArgument("lane \(lane.id) has no point at tick \(missing.raw)")
            }
            lane.points.removeAll { gone.contains($0.tick) }
        }
        return before
    }
}
