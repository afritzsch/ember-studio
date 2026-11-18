/// MODEL-005, DW-113 (T-102, 07 "Contract delta (T-102)"): renames a bus, like `RenameTrack` does a
/// track. `notFound` for an unknown bus; the inverse is the rename back.
public struct RenameBus: Command {
    public static let type = "RenameBus"

    public var busID: NodeIDValue
    public var name: String

    public init(busID: NodeIDValue, name: String) {
        self.busID = busID
        self.name = name
    }

    public var label: String { "Rename Bus" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        let oldName = try project.updateBus(busID) { bus in
            defer { bus.name = name }
            return bus.name
        }
        return RenameBus(busID: busID, name: oldName)
    }
}
