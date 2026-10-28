/// MODEL-005: routes the main output of a track or a bus to a bus or the master. Rejected with
/// `routingCycle` if the bus already feeds the channel (MODEL-030, D-14).
public struct SetTrackOutput: Command {
    public static let type = "SetTrackOutput"

    /// A track or a bus.
    public var channelID: NodeIDValue
    public var output: OutputTarget

    public init(channelID: NodeIDValue, output: OutputTarget) {
        self.channelID = channelID
        self.output = output
    }

    public var label: String { "Set Output" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let old = project.output(of: channelID) else { throw .notFound(kind: "track or bus", id: channelID) }
        try project.checkOutputTarget(output)
        if case .bus(let bus) = output { try project.checkNewRoute(from: channelID, to: bus) }
        try project.updateOutput(of: channelID) { $0 = output }
        return SetTrackOutput(channelID: channelID, output: old)
    }
}
