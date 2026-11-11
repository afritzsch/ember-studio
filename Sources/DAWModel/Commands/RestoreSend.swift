/// Puts a send back with its own ID: the inverse of `RemoveSend` and the redo of `AddSend` (see
/// `RestoreTrack`). Checked like `AddSend`, cycles included (MODEL-030/031).
public struct RestoreSend: Command {
    public static let type = "RestoreSend"

    /// The sending track or bus.
    public var channelID: NodeIDValue
    public var send: Send
    /// Position in the channel's sends, 0…send count.
    public var index: Int

    public init(channelID: NodeIDValue, send: Send, index: Int) {
        self.channelID = channelID
        self.send = send
        self.index = index
    }

    public var label: String { "Restore Send" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let count = project.sends(of: channelID)?.count else { throw .notFound(kind: "track or bus", id: channelID) }
        guard (0...count).contains(index) else { throw .invalidArgument("send index \(index) is outside 0…\(count)") }
        guard project.busIndex(send.target) != nil else { throw .notFound(kind: "bus", id: send.target) }
        try checkSendLevel(send.level)
        try project.checkNewRoute(from: channelID, to: send.target)
        // DW-234: RemoveSend takes the send's lanes, so lanes it had before coming back are kept.
        let inverse = project.inverseRestoringLanes(RemoveSend(sendID: send.id), label: "Remove Send") {
            $0.drivenSend == send.id
        }
        try project.claimIDs { body in body(send.id, "send") }
        try project.updateSends(of: channelID) { $0.insert(send, at: index) }
        return inverse
    }
}
