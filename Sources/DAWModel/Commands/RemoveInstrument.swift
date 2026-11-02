/// MODEL-005 (T-042): removes a MIDI track's instrument. Without one the track is silent: its clip
/// player leaves the graph too (07 "Left out of the graph"). The inverse puts the slot back with
/// its ID, params, state and zones (`RestoreInstrument`).
public struct RemoveInstrument: Command {
    public static let type = "RemoveInstrument"

    public var trackID: NodeIDValue

    public init(trackID: NodeIDValue) {
        self.trackID = trackID
    }

    public var label: String { "Remove Instrument" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let track = project.track(trackID) else { throw .notFound(kind: "track", id: trackID) }
        guard let instrument = track.instrument else { throw .invalidArgument("track \(trackID) has no instrument") }
        try project.updateTrack(trackID) { $0.instrument = nil }
        return RestoreInstrument(trackID: trackID, instrument: instrument)
    }
}
