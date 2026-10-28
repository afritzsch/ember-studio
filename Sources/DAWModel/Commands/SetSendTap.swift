/// MODEL-005: whether a send taps its channel before or after the fader (MIX-007). Changes where
/// the send's edge starts, so it rebuilds the graph; it can't close a cycle, since both taps belong
/// to the same channel.
public struct SetSendTap: Command {
    public static let type = "SetSendTap"

    public var sendID: ModelID
    public var tap: SignalTap

    public init(sendID: ModelID, tap: SignalTap) {
        self.sendID = sendID
        self.tap = tap
    }

    public var label: String { "Set Send Tap" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        let old = try project.updateSend(sendID) { send in
            defer { send.tap = tap }
            return send.tap
        }
        return SetSendTap(sendID: sendID, tap: old)
    }
}
