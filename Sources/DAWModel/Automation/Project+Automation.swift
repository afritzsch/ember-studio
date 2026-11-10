/// 11 (T-074): finding, checking and placing automation lanes.
///
/// Where lanes live: on the channel that owns their target (a strip's channel, a send's or a
/// device slot's channel), in `automation`, sorted by lane ID, so a lane removed and put back
/// returns to its place and undo restores the project exactly. Lanes are never removed with their
/// target: a lane whose send or device is gone stays where it was and is left out of the graph
/// (so undoing the removal brings the automation back). One lane per target in the project.
extension Project {
    /// AUTO-008: the targets a lane may drive. Solo has no slot (MIX-006) and phase isn't
    /// automatable (ChannelStrip ParamInfo); device params are checked against the kind's
    /// `automatable` flag by the engine, which leaves other lanes out.
    public static func checkAutomatable(_ target: ParamTarget) throws(DAWError) {
        switch target {
        case .strip(_, .gain), .strip(_, .pan), .strip(_, .mute), .sendLevel:
            return
        case .strip(_, let param):
            throw .invalidArgument("strip \(param.rawValue) can't be automated")
        case .device(_, let index):
            guard (0...DeviceSlot.maxParamIndex).contains(index) else {
                throw .invalidArgument("param index \(index) is outside 0…\(DeviceSlot.maxParamIndex)")
            }
        }
    }

    /// The channel that owns `target` today (a track, bus or the master), nil if it doesn't exist.
    public func automationOwner(of target: ParamTarget) -> NodeIDValue? {
        switch target {
        case .strip(let channel, _):
            return channel == master.id || isTrackOrBus(channel) ? channel : nil
        case .sendLevel(let send):
            return sendLocation(send)?.channel
        case .device(let slot, _):
            return deviceSlotOwner(slot)
        }
    }

    /// The lane driving `target` and the channel it sits on.
    public func automationLane(for target: ParamTarget) -> (channel: NodeIDValue, lane: AutomationLane)? {
        var found: (NodeIDValue, AutomationLane)?
        forEachAutomationLane { lane, channel in
            if found == nil, lane.target == target { found = (channel, lane) }
        }
        return found
    }

    /// Every lane with the channel that holds it: the master's, then tracks', then buses'.
    public func forEachAutomationLane(_ body: (AutomationLane, _ channel: NodeIDValue) -> Void) {
        for lane in master.automation { body(lane, master.id) }
        for track in tracks { for lane in track.automation { body(lane, track.id) } }
        for bus in buses { for lane in bus.automation { body(lane, bus.id) } }
    }

    public mutating func updateAutomation<R>(
        of channel: NodeIDValue, _ body: (inout [AutomationLane]) throws(DAWError) -> R
    ) throws(DAWError) -> R {
        if channel == master.id { return try body(&master.automation) }
        if let i = trackIndex(channel) { return try body(&tracks[i].automation) }
        if let i = busIndex(channel) { return try body(&buses[i].automation) }
        throw .notFound(kind: "channel", id: channel)
    }

    /// Replaces the lane for `target` (wherever it is) with `lane` on `channel`, or removes it
    /// when `lane` is nil. Returns the lane it replaced and where it was. `lane` is checked like
    /// any input and its ID claimed (it may be the replaced lane's own).
    @discardableResult
    mutating func placeAutomationLane(
        _ lane: AutomationLane?, for target: ParamTarget, on channel: NodeIDValue
    ) throws(DAWError) -> (channel: NodeIDValue, lane: AutomationLane)? {
        let old = automationLane(for: target)
        if let old {
            try updateAutomation(of: old.channel) { lanes in lanes.removeAll { $0.id == old.lane.id } }
        }
        if let lane {
            guard lane.target == target else { throw .invalidArgument("lane \(lane.id) drives another target") }
            try Self.checkAutomatable(target)
            try lane.validate()
            try claimIDs { body in body(lane.id, "automation lane") }
            try updateAutomation(of: channel) { lanes in
                let at = lanes.firstIndex { $0.id > lane.id } ?? lanes.endIndex
                lanes.insert(lane, at: at)
            }
        }
        return old
    }

    /// MODEL-032: lanes are well formed, sorted by ID on their channel, and no two drive the same
    /// target.
    func validateAutomation() throws(DAWError) {
        var targets = Set<ParamTarget>()
        var problem: DAWError?
        func check(_ lanes: [AutomationLane], _ channel: NodeIDValue) {
            for (i, lane) in lanes.enumerated() where problem == nil {
                do throws(DAWError) {
                    try lane.validate()
                    try Self.checkAutomatable(lane.target)
                } catch {
                    problem = .invariant("automation lane \(lane.id): \(error)")
                    return
                }
                if i > 0, lanes[i - 1].id >= lane.id {
                    problem = .invariant("automation lanes of channel \(channel) are not sorted by id")
                } else if !targets.insert(lane.target).inserted {
                    problem = .invariant("two automation lanes drive the same target (lane \(lane.id))")
                }
            }
        }
        check(master.automation, master.id)
        for track in tracks { check(track.automation, track.id) }
        for bus in buses { check(bus.automation, bus.id) }
        if let problem { throw problem }
    }
}

extension AutomationLane {
    /// Points have strictly increasing ticks on the timeline and values in 0…1.
    func validate() throws(DAWError) {
        for (i, point) in points.enumerated() {
            try point.validate()
            if i > 0, points[i - 1].tick >= point.tick {
                throw .invalidArgument("points of lane \(id) are not in strictly increasing tick order")
            }
        }
    }
}

extension AutomationPoint {
    func validate() throws(DAWError) {
        guard tick.raw >= 0, tick <= Tick.timelineEnd else {
            throw .invalidArgument("automation point tick \(tick.raw) is off the timeline")
        }
        guard value.isFinite, (0...1).contains(value) else {
            throw .invalidArgument("automation value \(value) is outside 0…1")
        }
        if case .exp(let shape) = curve {
            guard shape.isFinite, abs(shape) <= Self.maxShape else {
                throw .invalidArgument("exponential shape \(shape) is outside ±\(Self.maxShape)")
            }
        }
    }
}
