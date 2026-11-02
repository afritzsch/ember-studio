/// DW-140 (T-042): replaces a built-in sampler's zones (DSP-020). Each zone's asset must exist and
/// its ranges be the ones the sampler accepts (`SamplerZone`). The engine gets them as the node's
/// `configJSON`, with its `configVersion` bumped (DW-051). The inverse sets the old zones.
public struct SetSamplerZones: Command {
    public static let type = "SetSamplerZones"

    public var slotID: NodeIDValue
    public var zones: [SamplerZone]

    public init(slotID: NodeIDValue, zones: [SamplerZone]) {
        self.slotID = slotID
        self.zones = zones
    }

    public var label: String { "Edit Sampler Zones" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        try project.checkZoneAssets(zones)
        let old = try project.updateDeviceSlot(slotID) { (slot: inout DeviceSlot) throws(DAWError) -> [SamplerZone] in
            guard slot.isSampler else { throw .invalidArgument("device slot \(slotID) is not a sampler") }
            let old = slot.zones
            slot.zones = zones
            try slot.validate()
            return old
        }
        return SetSamplerZones(slotID: slotID, zones: old)
    }
}
