/// MODEL-005 (T-074, AUTO-005): sets the mode of the lane for `target`, creating an empty lane if
/// the target has none. `off` takes the lane out of playback; `read` plays it and overrides the
/// control while playing. The inverse sets the lane back (`SetAutomationLane`).
public struct SetAutomationMode: Command {
    public static let type = "SetAutomationMode"

    public var target: ParamTarget
    public var mode: AutomationLane.Mode

    public init(target: ParamTarget, mode: AutomationLane.Mode) {
        self.target = target
        self.mode = mode
    }

    public var label: String { "Set Automation Mode" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        let before = project.automationRestore(for: target, defaultChannel: project.automationOwner(of: target) ?? 0)
        _ = try project.automationLaneCreatingIfNeeded(for: target)
        try project.updateAutomationLane(for: target) { lane in lane.mode = mode }
        return before
    }
}
