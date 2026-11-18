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

// DW-235 (T-099): like Track, a missing `automation` key decodes as no lanes. Encoding is the
// synthesized one with the same keys, so saved files stay byte-identical.
extension MasterChannel {
    private enum CodingKeys: String, CodingKey {
        case id, inserts, strip, automation
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(NodeIDValue.self, forKey: .id),
            inserts: try c.decode([DeviceSlot].self, forKey: .inserts),
            strip: try c.decode(ChannelStripState.self, forKey: .strip),
            automation: try c.decodeIfPresent([AutomationLane].self, forKey: .automation) ?? [])
    }
}
