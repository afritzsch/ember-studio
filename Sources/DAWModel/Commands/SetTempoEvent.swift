/// MODEL-005: sets the tempo from `tick` on (a step change, 03), adding an event there or
/// changing the one that is there. Audio clips keep their tick positions and length in ticks, so
/// they move but don't stretch (D-06); their source offsets are samples and stay. The playhead is
/// the engine's: it keeps its sample position (DW-061 is open).
public struct SetTempoEvent: Command {
    public static let type = "SetTempoEvent"

    public var tick: Tick
    public var bpm: Double

    public init(tick: Tick, bpm: Double) {
        self.tick = tick
        self.bpm = bpm
    }

    public var label: String { "Set Tempo" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        try checkEventTick(tick)
        var events = project.tempoMap.tempoEvents
        let inverse: any Command
        if let i = events.firstIndex(where: { $0.tick == tick }) {
            inverse = SetTempoEvent(tick: tick, bpm: events[i].bpm)
            events[i].bpm = bpm
        } else {
            inverse = RemoveTempoEvent(tick: tick)
            events.insert(TempoEvent(tick: tick, bpm: bpm), at: events.firstIndex { $0.tick > tick } ?? events.count)
        }
        try project.setTempoMap(tempoEvents: events, timeSignatures: project.tempoMap.timeSignatures)
        return inverse
    }
}

/// MODEL-005: removes a tempo change. The event at tick 0 is the starting tempo and stays.
public struct RemoveTempoEvent: Command {
    public static let type = "RemoveTempoEvent"

    public var tick: Tick

    public init(tick: Tick) {
        self.tick = tick
    }

    public var label: String { "Remove Tempo Change" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard tick.raw != 0 else { throw .invalidArgument("the tempo event at tick 0 can't be removed") }
        var events = project.tempoMap.tempoEvents
        guard let i = events.firstIndex(where: { $0.tick == tick }) else {
            throw .invalidArgument("no tempo event at tick \(tick.raw)")
        }
        let removed = events.remove(at: i)
        try project.setTempoMap(tempoEvents: events, timeSignatures: project.tempoMap.timeSignatures)
        return SetTempoEvent(tick: tick, bpm: removed.bpm)
    }
}

/// MODEL-031: tempo and signature events lie on the timeline. The rest (bpm, numerator and
/// denominator ranges) is the tempo map's validation, reported as `invalidTempoMap` (DW-021).
func checkEventTick(_ tick: Tick) throws(DAWError) {
    guard (0...Tick.timelineEnd.raw).contains(tick.raw) else {
        throw .invalidArgument("tick \(tick.raw) is outside 0…\(Tick.timelineEnd.raw)")
    }
}
