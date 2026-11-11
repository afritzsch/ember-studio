/// MODEL-005 (DW-106): the project's loop region, which the transport's loop follows (TIME-004).
/// `nil` clears it; a region with `isEnabled == false` stays in the project while looping is off.
///
/// The region must be a non-empty range on the timeline (MODEL-031). Since T-088 (DW-125, user
/// decision) there is no minimum length: the transport plays loops shorter than a block (T-089),
/// so the DW-060 refusal of enabled loops under 4096 samples is gone. The inverse is `RestoreLoop`.
public struct SetLoop: Command {
    public static let type = "SetLoop"

    public var loop: LoopRange?

    public init(loop: LoopRange?) {
        self.loop = loop
    }

    public init(start: Tick, end: Tick, isEnabled: Bool = true) {
        self.loop = LoopRange(start: start, end: end, isEnabled: isEnabled)
    }

    public var label: String { "Set Loop" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        if let loop {
            try loop.checkRange()
        }
        defer { project.loop = loop }
        return RestoreLoop(loop: project.loop)
    }
}

/// Puts a loop region back as it was: the inverse of `SetLoop`, and its own inverse's. It checks
/// the range, like `SetLoop`.
public struct RestoreLoop: Command {
    public static let type = "RestoreLoop"

    public var loop: LoopRange?

    public init(loop: LoopRange?) {
        self.loop = loop
    }

    public var label: String { "Set Loop" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        try loop?.checkRange()
        defer { project.loop = loop }
        return RestoreLoop(loop: project.loop)
    }
}

extension LoopRange {
    /// MODEL-031: a non-empty range on the timeline.
    func checkRange() throws(DAWError) {
        guard start.raw >= 0, end > start, end <= Tick.timelineEnd else {
            throw .invalidArgument("loop [\(start.raw), \(end.raw)) is empty or off the timeline")
        }
    }
}
