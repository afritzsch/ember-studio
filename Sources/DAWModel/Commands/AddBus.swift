/// MODEL-005: adds an empty bus with a new ID, at `index` (default: the end).
public struct AddBus: Command {
    public static let type = "AddBus"

    public var name: String
    /// 0…bus count; nil appends.
    public var index: Int?
    /// Default: the master.
    public var output: OutputTarget?
    public var color: TrackColor?

    public init(name: String, index: Int? = nil, output: OutputTarget? = nil, color: TrackColor? = nil) {
        self.name = name
        self.index = index
        self.output = output
        self.color = color
    }

    public var label: String { "Add Bus" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        let at = index ?? project.buses.count
        guard (0...project.buses.count).contains(at) else { throw .invalidArgument("bus index \(at) is outside 0…\(project.buses.count)") }
        let output = output ?? .master
        // A new bus has nothing routed into it, so its output can't close a cycle.
        try project.checkOutputTarget(output)
        let id = project.ids.allocate()
        project.buses.insert(Bus(id: id, name: name, color: color ?? .gray, output: output), at: at)
        return RemoveBus(busID: id)
    }
}
