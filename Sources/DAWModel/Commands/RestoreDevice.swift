/// Puts an insert back into a channel's chain with its own ID (T-088): the inverse of
/// `RemoveDevice` and the redo of `InsertDevice` ("inverses keep IDs", 07). Checked like any input
/// (MODEL-031): the channel exists, the index is in 0…insert count, the slot is valid and its ID
/// unused, its sidechain source is a track or bus and the route acyclic (MODEL-030). It checks what
/// `validate()` checks, not `InsertDevice`'s kind rule, so any insert a project holds can be put
/// back.
public struct RestoreDevice: Command {
    public static let type = "RestoreDevice"

    /// A track, bus or the master.
    public var channel: NodeIDValue
    /// 0…insert count.
    public var index: Int
    public var slot: DeviceSlot

    public init(channel: NodeIDValue, index: Int, slot: DeviceSlot) {
        self.channel = channel
        self.index = index
        self.slot = slot
    }

    public var label: String { "Restore Device" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard project.inserts(of: channel) != nil else { throw .notFound(kind: "channel", id: channel) }
        let inverse = project.inverseRestoringLanes(RemoveDevice(slotID: slot.id), label: "Remove Device") {
            $0.drivenSlot == slot.id
        }
        var working = project
        try working.claimIDs(slot.forEachID)
        try working.placeInsert(slot, on: channel, at: index)
        project = working
        return inverse
    }
}
