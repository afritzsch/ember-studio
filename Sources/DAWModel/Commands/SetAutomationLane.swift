/// T-074 (11, MODEL-005): sets the lane for `target` to exactly `lane` on `channel`, with the
/// lane's own ID, or removes it (`lane` nil). The inverse of every automation command and of
/// itself, so undo and redo restore lanes exactly ("inverses keep IDs", 07). Checked like any
/// input (MODEL-031): the channel exists, the lane drives `target`, is well formed and its ID is
/// unused (the lane it replaces doesn't count).
public struct SetAutomationLane: Command {
    public static let type = "SetAutomationLane"

    public var channel: NodeIDValue
    public var target: ParamTarget
    public var lane: AutomationLane?

    public init(channel: NodeIDValue, target: ParamTarget, lane: AutomationLane?) {
        self.channel = channel
        self.target = target
        self.lane = lane
    }

    public var label: String { "Edit Automation" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard channel == project.master.id || project.isTrackOrBus(channel) else {
            throw .notFound(kind: "channel", id: channel)
        }
        let old = try project.placeAutomationLane(lane, for: target, on: channel)
        return SetAutomationLane(channel: old?.channel ?? channel, target: target, lane: old?.lane)
    }
}

extension Project {
    /// The inverse every automation command returns: the lane for `target` as it is now.
    func automationRestore(for target: ParamTarget, defaultChannel: NodeIDValue) -> SetAutomationLane {
        let current = automationLane(for: target)
        return SetAutomationLane(channel: current?.channel ?? defaultChannel, target: target, lane: current?.lane)
    }

    /// The lane for `target`, created (mode `read`, no points, new ID) on the target's channel if
    /// there is none (T-074 decision: lanes are created by their first edit). Returns the lane and
    /// its channel.
    mutating func automationLaneCreatingIfNeeded(
        for target: ParamTarget
    ) throws(DAWError) -> (channel: NodeIDValue, lane: AutomationLane) {
        try Self.checkAutomatable(target)
        if let existing = automationLane(for: target) { return existing }
        guard let channel = automationOwner(of: target) else { throw .notFound(kind: "automation target", id: target.ownerID) }
        let lane = AutomationLane(id: ids.allocate(), target: target)
        try updateAutomation(of: channel) { lanes in lanes.append(lane) }  // the newest ID sorts last
        return (channel, lane)
    }

    /// Runs `body` on the lane for `target` in place, or throws `notFound`.
    mutating func updateAutomationLane<R>(
        for target: ParamTarget, _ body: (inout AutomationLane) throws(DAWError) -> R
    ) throws(DAWError) -> R {
        guard let (channel, lane) = automationLane(for: target) else {
            throw .notFound(kind: "automation lane", id: target.ownerID)
        }
        return try updateAutomation(of: channel) { (lanes: inout [AutomationLane]) throws(DAWError) -> R in
            let i = lanes.firstIndex { $0.id == lane.id }!
            return try body(&lanes[i])
        }
    }
}

extension ParamTarget {
    /// The entity the target names, for `notFound` errors.
    var ownerID: ModelID {
        switch self {
        case .strip(let channel, _): channel
        case .sendLevel(let send): send
        case .device(let slot, _): slot
        }
    }
}
