/// MODEL-005 `MoveDevice` (T-088, DW-149): moves an insert within its own channel's chain so it
/// ends up at `index` (0…insert count − 1). Moving to another channel isn't part of MODEL-005
/// (DECISIONS "T-088 master"); an instrument slot is rejected. Reordering changes the graph
/// (MODEL-021), never the slot. The inverse moves it back.
public struct MoveDevice: Command {
    public static let type = "MoveDevice"

    public var slotID: NodeIDValue
    /// The slot's new position in its chain, 0…insert count − 1.
    public var index: Int

    public init(slotID: NodeIDValue, index: Int) {
        self.slotID = slotID
        self.index = index
    }

    public var label: String { "Move Device" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        let (channel, old) = try project.requireInsertLocation(slotID)
        try project.updateInserts(of: channel) { (inserts: inout [DeviceSlot]) throws(DAWError) in
            guard inserts.indices.contains(index) else {
                throw .invalidArgument("insert index \(index) is outside 0…\(inserts.count - 1)")
            }
            inserts.insert(inserts.remove(at: old), at: index)
        }
        return MoveDevice(slotID: slotID, index: old)
    }
}
