/// MODEL-005: removes a send.
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
        return RestoreSend(channelID: channel, send: send, index: index)
    }
}
