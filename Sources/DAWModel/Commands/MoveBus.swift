/// MODEL-005, DW-113 (T-102, 07 "Contract delta (T-102)"): moves a bus so it ends up at `index` in
/// the bus list, like `MoveTrack` does a track. Routing names buses by ID, so only the order changes.
public struct MoveBus: Command {
    public static let type = "MoveBus"

    public var busID: NodeIDValue
    /// The bus's new position, 0…bus count − 1.
    public var index: Int

    public init(busID: NodeIDValue, index: Int) {
        self.busID = busID
        self.index = index
    }

    public var label: String { "Move Bus" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let old = project.busIndex(busID) else { throw .notFound(kind: "bus", id: busID) }
        guard project.buses.indices.contains(index) else {
            throw .invalidArgument("bus index \(index) is outside 0…\(project.buses.count - 1)")
        }
        project.buses.insert(project.buses.remove(at: old), at: index)
        return MoveBus(busID: busID, index: old)
    }
}
