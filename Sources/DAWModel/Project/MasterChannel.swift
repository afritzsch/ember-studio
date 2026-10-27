/// The master channel, the graph's final node (MIX-009).
public struct MasterChannel: Identifiable, Hashable, Sendable, Codable {
    public var id: NodeIDValue
    public var inserts: [DeviceSlot]
    public var strip: ChannelStripState
    public var automation: [AutomationLane]

    public init(
        id: NodeIDValue, inserts: [DeviceSlot] = [], strip: ChannelStripState = ChannelStripState(),
        automation: [AutomationLane] = []
    ) {
        self.id = id
        self.inserts = inserts
        self.strip = strip
        self.automation = automation
    }
}
