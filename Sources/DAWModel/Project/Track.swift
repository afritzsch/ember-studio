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
