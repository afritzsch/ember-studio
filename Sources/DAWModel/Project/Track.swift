/// An audio or MIDI track (D-03).
public struct Track: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case audio, midi
    }

    /// Input monitoring (09).
    public enum Monitoring: String, Hashable, Sendable, Codable {
        case off, auto, on
    }

    public var id: NodeIDValue
    public var name: String
    public var kind: Kind
    public var color: TrackColor
    /// Sorted by start.
    public var clips: [Clip]
    public var takeFolders: [TakeFolder]
    /// MIDI tracks only: the sampler or plugin the notes play.
    public var instrument: DeviceSlot?
    /// In signal order.
    public var inserts: [DeviceSlot]
    public var strip: ChannelStripState
    public var sends: [Send]
    public var output: OutputTarget
    public var armed: Bool
    /// REC-001 (T-052): the device input channels an armed audio track records, 2·inputPair and
    /// 2·inputPair + 1 (0…`Track.maxInputPair`). Files from before T-052 read 0.
    public var inputPair: UInt32 = 0
    public var monitoring: Monitoring
    public var automation: [AutomationLane]

    public init(
        id: NodeIDValue, name: String, kind: Kind, color: TrackColor = .gray, clips: [Clip] = [],
        takeFolders: [TakeFolder] = [], instrument: DeviceSlot? = nil, inserts: [DeviceSlot] = [],
        strip: ChannelStripState = ChannelStripState(), sends: [Send] = [],
        output: OutputTarget = .master, armed: Bool = false, monitoring: Monitoring = .auto,
        automation: [AutomationLane] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.color = color
        self.clips = clips
        self.takeFolders = takeFolders
        self.instrument = instrument
        self.inserts = inserts
        self.strip = strip
        self.sends = sends
        self.output = output
        self.armed = armed
        self.monitoring = monitoring
        self.automation = automation
    }
}

// T-052: `inputPair` is additive. It is always written and read with a default, so older files open
// unchanged (no format version or migration, like `Project.metronome`, MODEL-042).
extension Track {
    /// REC-001: input channel pairs 0…15 (the engine sees at most 32 device channels).
    public static let maxInputPair: UInt32 = 15

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, color, clips, takeFolders, instrument, inserts, strip, sends, output, armed, inputPair,
            monitoring, automation
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(NodeIDValue.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        color = try c.decode(TrackColor.self, forKey: .color)
        clips = try c.decode([Clip].self, forKey: .clips)
        takeFolders = try c.decode([TakeFolder].self, forKey: .takeFolders)
        instrument = try c.decodeIfPresent(DeviceSlot.self, forKey: .instrument)
        inserts = try c.decode([DeviceSlot].self, forKey: .inserts)
        strip = try c.decode(ChannelStripState.self, forKey: .strip)
        sends = try c.decode([Send].self, forKey: .sends)
        output = try c.decode(OutputTarget.self, forKey: .output)
        armed = try c.decode(Bool.self, forKey: .armed)
        inputPair = try c.decodeIfPresent(UInt32.self, forKey: .inputPair) ?? 0
        monitoring = try c.decode(Monitoring.self, forKey: .monitoring)
        automation = try c.decode([AutomationLane].self, forKey: .automation)
    }
}
