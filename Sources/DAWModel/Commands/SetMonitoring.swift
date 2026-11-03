/// MODEL-005, REC-020 (T-052 adds the field plumbing; the monitoring behaviour is T-054): a
/// track's input monitoring mode, `off`, `on` or `auto`.
///
/// A `HistoryExemptCommand` like `ArmTrack` (docs/autobuild/DECISIONS.md "T-052 undo"): persisted,
/// marks the project dirty, never in undo history.
public struct SetMonitoring: HistoryExemptCommand {
    public static let type = "SetMonitoring"

    public var trackID: NodeIDValue
    public var mode: Track.Monitoring

    public init(trackID: NodeIDValue, mode: Track.Monitoring) {
        self.trackID = trackID
        self.mode = mode
    }

    public var label: String { "Set Monitoring" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        let old = try project.updateTrack(trackID) { track in
            defer { track.monitoring = mode }
            return track.monitoring
        }
        return SetMonitoring(trackID: trackID, mode: old)
    }
}
