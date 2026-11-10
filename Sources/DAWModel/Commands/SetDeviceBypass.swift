/// MODEL-005 `SetDeviceBypass` (T-064, PLUG-018): host-side bypass of a device slot (an instrument
/// or an insert of a track, bus or the master; built-in or plugin). The slot stays in the graph
/// either way: the engine's bypass slot passes its input through, delayed by the device's latency
/// so PDC doesn't move, and the plugin keeps its state. So a toggle is a param-slot write, never a
/// rebuild (MODEL-021), and it can't close a cycle (MODEL-030 already counts bypassed devices).
/// The inverse sets the old value.
public struct SetDeviceBypass: Command {
    public static let type = "SetDeviceBypass"

    public var slotID: NodeIDValue
    public var bypass: Bool

    public init(slotID: NodeIDValue, bypass: Bool) {
        self.slotID = slotID
        self.bypass = bypass
    }

    public var label: String { bypass ? "Bypass Device" : "Enable Device" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        let old = try project.updateDeviceSlot(slotID) { slot in
            defer { slot.bypass = bypass }
            return slot.bypass
        }
        return SetDeviceBypass(slotID: slotID, bypass: old)
    }
}
