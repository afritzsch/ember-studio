/// MODEL-005 (DW-106): the project's loop region, which the transport's loop follows (TIME-004).
/// `nil` clears it; a region with `isEnabled == false` stays in the project while looping is off.
///
/// DW-060: the transport splits a block at most once (TIME-005), so a loop shorter than a block
/// plays once and then leaves a gap. An enabled loop must be at least `LoopRange.minLengthSamples`
/// long at the tempo when it is set. A later tempo edit can still shrink it; that isn't rejected
/// (see `Project.validateLoop`), so the inverse is `RestoreLoop`, which puts the old region back
/// without the length check: undo must not fail because the tempo changed in between.
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
            let samples = project.samples(from: loop.start, to: loop.end)
            guard !loop.isEnabled || samples >= LoopRange.minLengthSamples else {
                throw .invalidArgument("loop [\(loop.start.raw), \(loop.end.raw)) is \(samples) samples, shorter than \(LoopRange.minLengthSamples)")
            }
        }
        defer { project.loop = loop }
        return RestoreLoop(loop: project.loop)
    }
}

/// Puts a loop region back as it was: the inverse of `SetLoop`, and its own inverse's. It checks
/// only the range, not DW-060's minimum length, which depends on the tempo at the time.
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
    /// DW-060: the engine's largest block (`daw::kMaxBlock`, ENG-004).
    public static let minLengthSamples: Int64 = 4096

    /// MODEL-031: a non-empty range on the timeline.
    func checkRange() throws(DAWError) {
        guard start.raw >= 0, end > start, end <= Tick.timelineEnd else {
            throw .invalidArgument("loop [\(start.raw), \(end.raw)) is empty or off the timeline")
        }
    }
}
