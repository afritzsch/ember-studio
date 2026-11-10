/// Sets a MIDI track's instrument slot to exactly `instrument` (nil: none), with the slot's own ID:
/// the inverse of `SetInstrument`, `RemoveInstrument` and itself, so undo and redo keep slot IDs
/// ("inverses keep IDs", 07). Checked like any input (MODEL-031): the slot ID must be unused (the
/// slot it replaces doesn't count), the slot valid, its sidechain source a track or bus and its
/// route acyclic (MODEL-030).
///
/// DW-234 (T-088): a replaced slot with another ID takes its automation lanes with it, and lanes
/// that already drove the restored slot are kept by the inverse; so the inverse is a composite
/// when lanes are involved, and `RestoreInstrument` alone otherwise.
public struct RestoreInstrument: Command {
    public static let type = "RestoreInstrument"

    public var trackID: NodeIDValue
    public var instrument: DeviceSlot?

    public init(trackID: NodeIDValue, instrument: DeviceSlot?) {
        self.trackID = trackID
        self.instrument = instrument
    }

    public var label: String { "Restore Instrument" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let track = project.track(trackID) else { throw .notFound(kind: "track", id: trackID) }
        guard track.kind == .midi else { throw .invalidArgument("track \(trackID) is not a MIDI track") }
        let replaced = track.instrument
        let restored = instrument?.id
        // DW-234: lanes of the slot coming back (a slot restored over itself keeps its lanes).
        var kept: [any Command] = []
        project.forEachAutomationLane { lane, channel in
            if let restored, restored != replaced?.id, lane.target.drivenSlot == restored {
                kept.append(SetAutomationLane(channel: channel, target: lane.target, lane: lane))
            }
        }
        var working = project
        // The slot being replaced gives up its ID first, so a slot can be restored over itself.
        try working.updateTrack(trackID) { $0.instrument = nil }
        if let instrument {
            try working.claimIDs(instrument.forEachID)
            _ = try working.placeInstrument(instrument, on: trackID)
        }
        var inverse: [any Command] = [RestoreInstrument(trackID: trackID, instrument: replaced)]
        if let gone = replaced?.id, gone != restored {
            inverse += try working.removeAutomationLanes { $0.drivenSlot == gone }  // DW-234
        }
        inverse += kept
        project = working
        return inverse.count == 1 ? inverse[0] : CompositeCommand(label, inverse)
    }
}

extension Project {
    /// T-042: puts `slot` into a MIDI track's instrument slot and returns the slot it replaced.
    /// The slot's ID must already be reserved. Checks the slot like `validate()` would (MODEL-031).
    mutating func placeInstrument(_ slot: DeviceSlot, on trackID: NodeIDValue) throws(DAWError) -> DeviceSlot? {
        guard let track = track(trackID) else { throw .notFound(kind: "track", id: trackID) }
        guard track.kind == .midi else { throw .invalidArgument("track \(trackID) is not a MIDI track") }
        try slot.checkInstrumentKind()
        try slot.validate()
        try checkZoneAssets(slot.zones)
        if let source = slot.sidechainSource?.source {
            guard isTrackOrBus(source) else { throw .notFound(kind: "track or bus", id: source) }
            try checkNewRoute(from: source, to: trackID)
        }
        let previous = track.instrument
        try updateTrack(trackID) { $0.instrument = slot }
        return previous
    }

    /// DW-140: every zone's asset exists.
    func checkZoneAssets(_ zones: [SamplerZone]) throws(DAWError) {
        for zone in zones where assetIndex(zone.assetID) == nil {
            throw .notFound(kind: "asset", id: zone.assetID)
        }
    }
}
