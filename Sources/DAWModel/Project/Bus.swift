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

// DW-235 (T-099): like Track, a missing `automation` key decodes as no lanes. Encoding is the
// synthesized one with the same keys, so saved files stay byte-identical.
extension Bus {
    private enum CodingKeys: String, CodingKey {
        case id, name, color, inserts, strip, sends, output, automation
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(NodeIDValue.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            color: try c.decode(TrackColor.self, forKey: .color),
            inserts: try c.decode([DeviceSlot].self, forKey: .inserts),
            strip: try c.decode(ChannelStripState.self, forKey: .strip),
            sends: try c.decode([Send].self, forKey: .sends),
            output: try c.decode(OutputTarget.self, forKey: .output),
            automation: try c.decodeIfPresent([AutomationLane].self, forKey: .automation) ?? [])
    }
}
