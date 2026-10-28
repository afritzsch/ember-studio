/// MODEL-005: adds a send from a track or bus into a bus (MIX-007), with a new ID, at the end of
/// the channel's sends. Rejected with `routingCycle` if the bus already feeds the channel
/// (MODEL-030, D-14).
public struct AddSend: Command {
    public static let type = "AddSend"

    /// The sending track or bus.
    public var channelID: NodeIDValue
    /// The receiving bus.
    public var busID: NodeIDValue
    /// Linear, 0…+12 dB. Default 1 (0 dB).
    public var level: Float?
    /// Default: post-fader.
    public var tap: SignalTap?

    public init(channelID: NodeIDValue, busID: NodeIDValue, level: Float? = nil, tap: SignalTap? = nil) {
        self.channelID = channelID
        self.busID = busID
        self.level = level
        self.tap = tap
    }

    public var label: String { "Add Send" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard project.isTrackOrBus(channelID) else { throw .notFound(kind: "track or bus", id: channelID) }
        guard project.busIndex(busID) != nil else { throw .notFound(kind: "bus", id: busID) }
        let level = level ?? 1
        try checkSendLevel(level)
        try project.checkNewRoute(from: channelID, to: busID)
        let id = project.ids.allocate()
        try project.updateSends(of: channelID) { $0.append(Send(id: id, target: busID, level: level, tap: tap ?? .postFader)) }
        return RemoveSend(sendID: id)
    }
}

/// MODEL-031: send levels are linear, 0…+12 dB (MIX-007).
func checkSendLevel(_ level: Float) throws(DAWError) {
    guard level.isFinite, (0...Send.maxLevel).contains(level) else {
        throw .invalidArgument("send level \(level) is outside 0…\(Send.maxLevel)")
    }
}
