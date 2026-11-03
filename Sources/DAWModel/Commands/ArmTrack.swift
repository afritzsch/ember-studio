/// MODEL-005, REC-001 (T-052): arms or disarms a track for recording and picks the input channel
/// pair an audio track records (channels 2·inputPair, 2·inputPair + 1; 0…`Track.maxInputPair`).
/// `inputPair` left out keeps the track's. A MIDI track can be armed too (its input is MIDI,
/// T-053); engine sync arms device input only for audio tracks.
///
/// A `HistoryExemptCommand` (07, docs/autobuild/DECISIONS.md "T-052 undo"): persisted and marks
/// the project dirty, but never in undo history, so ⌘Z doesn't disarm a track. Engine sync turns
/// a change into `armInput` (REC-022: arming is structural).
public struct ArmTrack: HistoryExemptCommand {
    public static let type = "ArmTrack"

    public var trackID: NodeIDValue
    public var armed: Bool
    public var inputPair: UInt32?

    public init(trackID: NodeIDValue, armed: Bool, inputPair: UInt32? = nil) {
        self.trackID = trackID
        self.armed = armed
        self.inputPair = inputPair
    }

    public var label: String { armed ? "Arm Track" : "Disarm Track" }

    /// The inverse sets both back; only callers that apply it themselves use it.
    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        if let inputPair, inputPair > Track.maxInputPair {
            throw .invalidArgument("input pair \(inputPair) is outside 0…\(Track.maxInputPair)")
        }
        return try project.updateTrack(trackID) { track in
            let inverse = ArmTrack(trackID: trackID, armed: track.armed, inputPair: track.inputPair)
            track.armed = armed
            if let inputPair { track.inputPair = inputPair }
            return inverse
        }
    }
}
