/// MODEL-005: removes a bus with its inserts and sends. Everything that pointed at it goes too, as
/// one edit (MODEL-004): sends into it are removed, outputs into it fall back to the master and
/// sidechains listening to it are cleared. DW-234 (T-088): the automation lanes of the sends into
/// it go too (the bus's own lanes leave with the bus). Undo restores all of it.
public struct RemoveBus: Command {
    public static let type = "RemoveBus"

    public var busID: NodeIDValue

    public init(busID: NodeIDValue) {
        self.busID = busID
    }

    public var label: String { "Remove Bus" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let index = project.busIndex(busID) else { throw .notFound(kind: "bus", id: busID) }
        let bus = project.buses.remove(at: index)
        // Restore the bus first: everything else refers to it.
        var restore: [any Command] = [RestoreBus(bus: bus, index: index)]
        let channels = project.tracks.map(\.id) + project.buses.map(\.id)
        var cutSends = Set<ModelID>()
        for channel in channels {
            try project.updateSends(of: channel) { sends in
                // Ascending indices, so re-inserting them in this order lands each where it was.
                for (i, send) in sends.enumerated() where send.target == busID {
                    restore.append(RestoreSend(channelID: channel, send: send, index: i))
                    cutSends.insert(send.id)
                }
                sends.removeAll { $0.target == busID }
            }
        }
        for channel in channels where project.output(of: channel) == .bus(busID) {
            try project.updateOutput(of: channel) { $0 = .master }
            restore.append(SetTrackOutput(channelID: channel, output: .bus(busID)))
        }
        restore += try project.clearSidechains(from: busID)
        restore += try project.removeAutomationLanes { $0.drivenSend.map(cutSends.contains) ?? false }  // DW-234
        return restore.count == 1 ? restore[0] : CompositeCommand(label, restore)
    }
}
