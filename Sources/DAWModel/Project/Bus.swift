/// A bus: sums sends and track outputs routed to it (MIX-007).
public struct Bus: Identifiable, Hashable, Sendable, Codable {
    public var id: NodeIDValue
    public var name: String
    public var color: TrackColor
    public var inserts: [DeviceSlot]
    public var strip: ChannelStripState
    public var sends: [Send]
    public var output: OutputTarget
    public var automation: [AutomationLane]

    public init(
        id: NodeIDValue, name: String, color: TrackColor = .gray, inserts: [DeviceSlot] = [],
        strip: ChannelStripState = ChannelStripState(), sends: [Send] = [],
        output: OutputTarget = .master, automation: [AutomationLane] = []
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.inserts = inserts
        self.strip = strip
        self.sends = sends
        self.output = output
        self.automation = automation
    }
}
