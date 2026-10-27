/// MODEL-004: several commands applied as one edit and one undo entry, e.g. delete track = remove
/// the sends targeting it + remove the track. All or nothing: if a step throws, the project is
/// left as it was.
public struct CompositeCommand: Command {
    public static let type = "Composite"

    public var label: String
    public var commands: [any Command]

    public init(_ label: String, _ commands: [any Command]) {
        self.label = label
        self.commands = commands
    }

    /// The inverse runs the steps' inverses in reverse order.
    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        var working = project
        var inverses: [any Command] = []
        inverses.reserveCapacity(commands.count)
        for command in commands {
            inverses.append(try command.apply(to: &working))
        }
        project = working
        return CompositeCommand(label, inverses.reversed())
    }

    private enum CodingKeys: String, CodingKey { case label, commands }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        commands = try c.decode([AnyCommand].self, forKey: .commands).map(\.base)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(commands.map(AnyCommand.init), forKey: .commands)
    }
}
