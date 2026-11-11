/// MODEL-005: removes a send. DW-234 (T-088): the automation lane driving its level goes in the same
/// step; undo puts the send back, then the lane.
public struct RemoveSend: Command {
    public static let type = "RemoveSend"

    public var sendID: ModelID

    public init(sendID: ModelID) {
        self.sendID = sendID
    }

    public var label: String { "Remove Send" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let (channel, index) = project.sendLocation(sendID) else { throw .notFound(kind: "send", id: sendID) }
        let send = try project.updateSends(of: channel) { $0.remove(at: index) }
        var restore: [any Command] = [RestoreSend(channelID: channel, send: send, index: index)]
        restore += try project.removeAutomationLanes { $0.drivenSend == sendID }  // DW-234
        return restore.count == 1 ? restore[0] : CompositeCommand(label, restore)
    }
}
