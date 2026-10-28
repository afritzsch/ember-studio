/// MODEL-005: sets the time signature from `tick` on, adding an event there or changing the one
/// that is there. A signature always starts a new bar; off a bar line of the previous one, that bar
/// is cut short (03). Clips keep their ticks.
public struct SetTimeSignature: Command {
    public static let type = "SetTimeSignature"

    public var tick: Tick
    public var numerator: Int
    /// A power of two, 1…64.
    public var denominator: Int

    public init(tick: Tick, numerator: Int, denominator: Int) {
        self.tick = tick
        self.numerator = numerator
        self.denominator = denominator
    }

    public var label: String { "Set Time Signature" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        try checkEventTick(tick)
        var events = project.tempoMap.timeSignatures
        let event = TimeSignatureEvent(tick: tick, numerator: numerator, denominator: denominator)
        let inverse: any Command
        if let i = events.firstIndex(where: { $0.tick == tick }) {
            inverse = SetTimeSignature(tick: tick, numerator: events[i].numerator, denominator: events[i].denominator)
            events[i] = event
        } else {
            inverse = RemoveTimeSignature(tick: tick)
            events.insert(event, at: events.firstIndex { $0.tick > tick } ?? events.count)
        }
        try project.setTempoMap(tempoEvents: project.tempoMap.tempoEvents, timeSignatures: events)
        return inverse
    }
}

/// Removes a time-signature change: the inverse of `SetTimeSignature` adding one. The signature
/// at tick 0 stays.
public struct RemoveTimeSignature: Command {
    public static let type = "RemoveTimeSignature"

    public var tick: Tick

    public init(tick: Tick) {
        self.tick = tick
    }

    public var label: String { "Remove Time Signature" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard tick.raw != 0 else { throw .invalidArgument("the time signature at tick 0 can't be removed") }
        var events = project.tempoMap.timeSignatures
        guard let i = events.firstIndex(where: { $0.tick == tick }) else {
            throw .invalidArgument("no time signature at tick \(tick.raw)")
        }
        let removed = events.remove(at: i)
        try project.setTempoMap(tempoEvents: project.tempoMap.tempoEvents, timeSignatures: events)
        return SetTimeSignature(tick: tick, numerator: removed.numerator, denominator: removed.denominator)
    }
}
