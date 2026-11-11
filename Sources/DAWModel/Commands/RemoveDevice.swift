/// MODEL-005 `RemoveDevice` (T-088, DW-149): removes an insert from whichever channel holds it (a
/// track, a bus or the master). An instrument slot is rejected (`RemoveInstrument`). DW-234: the
/// automation lanes driving the slot go in the same step. The inverse puts the slot back with its
/// ID, params, state, bypass and sidechain at its index (`RestoreDevice`), then its lanes.
public struct RemoveDevice: Command {
    public static let type = "RemoveDevice"

    public var slotID: NodeIDValue

    public init(slotID: NodeIDValue) {
        self.slotID = slotID
    }

    public var label: String { "Remove Device" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        let (channel, index) = try project.requireInsertLocation(slotID)
        let slot = try project.updateInserts(of: channel) { $0.remove(at: index) }
        var restore: [any Command] = [RestoreDevice(channel: channel, index: index, slot: slot)]
        restore += try project.removeAutomationLanes { $0.drivenSlot == slotID }  // DW-234
        return restore.count == 1 ? restore[0] : CompositeCommand(label, restore)
    }
}
