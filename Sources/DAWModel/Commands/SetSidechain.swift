/// MODEL-005: sets or clears the track or bus that feeds a device slot's sidechain input (MIX-008).
/// Rejected with `routingCycle` if the device's channel already feeds the source (MODEL-030), a
/// channel's own signal included.
public struct SetSidechain: Command {
    public static let type = "SetSidechain"

    public var slotID: NodeIDValue
    /// Nil clears the sidechain.
    public var source: SidechainRef?

    public init(slotID: NodeIDValue, source: SidechainRef?) {
        self.slotID = slotID
        self.source = source
    }

    public var label: String { "Set Sidechain" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let owner = project.deviceSlotOwner(slotID) else { throw .notFound(kind: "device slot", id: slotID) }
        if let source {
            guard project.isTrackOrBus(source.source) else { throw .notFound(kind: "track or bus", id: source.source) }
            try project.checkNewRoute(from: source.source, to: owner)
        }
        let old = try project.updateDeviceSlot(slotID) { slot in
            defer { slot.sidechainSource = source }
            return slot.sidechainSource
        }
        return SetSidechain(slotID: slotID, source: old)
    }
}
