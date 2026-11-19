/// Puts a whole bus back with its own IDs: the inverse of `RemoveBus` and the redo of `AddBus`
/// (see `RestoreTrack`). The sends, outputs and sidechains `RemoveBus` cut are restored by the
/// commands that follow it in the same composite.
public struct RestoreBus: Command {
    public static let type = "RestoreBus"

    public var bus: Bus
    /// 0…bus count.
    public var index: Int

    public init(bus: Bus, index: Int) {
        self.bus = bus
        self.index = index
    }

    public var label: String { "Restore Bus" }

    /// DW-334: the bus snapshot's inserts follow a session-rate change.
    public func rescaled(from: Double, to: Double) -> any Command {
        RestoreBus(bus: bus.rescaled(from: from, to: to), index: index)
    }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard (0...project.buses.count).contains(index) else {
            throw .invalidArgument("bus index \(index) is outside 0…\(project.buses.count)")
        }
        try bus.validateContents()
        try project.claimIDs(bus.forEachID)
        project.buses.insert(bus, at: index)
        try project.validateRouting()
        return RemoveBus(busID: bus.id)
    }
}
