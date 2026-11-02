/// MODEL-005 (T-042): puts an instrument with a new slot ID on a MIDI track, replacing the one
/// there. A built-in instrument is the sampler (D-19), which may come with its zones (DW-140);
/// hosted plugins (AU, VST3) are placed as they are. Once a track has an active instrument,
/// GraphDescriptionBuilder emits its clip player, the instrument and the MIDI edge between them.
/// The inverse is `RestoreInstrument` with what was there before.
public struct SetInstrument: Command {
    public static let type = "SetInstrument"

    public var trackID: NodeIDValue
    public var device: DeviceSlot.Kind
    /// Built-in sampler only.
    public var zones: [SamplerZone]?

    public init(trackID: NodeIDValue, device: DeviceSlot.Kind, zones: [SamplerZone]? = nil) {
        self.trackID = trackID
        self.device = device
        self.zones = zones
    }

    public var label: String { "Set Instrument" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        let slot = DeviceSlot(id: project.ids.allocate(), kind: device, zones: zones ?? [])
        let previous = try project.placeInstrument(slot, on: trackID)
        return RestoreInstrument(trackID: trackID, instrument: previous)
    }
}
