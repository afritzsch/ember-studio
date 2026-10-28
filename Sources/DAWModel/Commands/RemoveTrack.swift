/// MODEL-005: removes a track with everything on it. Sidechains that listen to it are cleared
/// (MODEL-004: one edit, one undo entry); undo restores them.
public struct RemoveTrack: Command {
    public static let type = "RemoveTrack"

    public var trackID: NodeIDValue

    public init(trackID: NodeIDValue) {
        self.trackID = trackID
    }

    public var label: String { "Remove Track" }

    public func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let index = project.trackIndex(trackID) else { throw .notFound(kind: "track", id: trackID) }
        let track = project.tracks.remove(at: index)
        var restore: [any Command] = [RestoreTrack(track: track, index: index)]
        restore += try project.clearSidechains(from: trackID)
        return restore.count == 1 ? restore[0] : CompositeCommand(label, restore)
    }
}

extension Project {
    /// Clears every sidechain whose source is `channel` and returns the commands that set them
    /// back, in layout order.
    mutating func clearSidechains(from channel: NodeIDValue) throws(DAWError) -> [any Command] {
        var listening: [(slot: NodeIDValue, ref: SidechainRef)] = []
        forEachDeviceSlot { slot, _ in
            if let ref = slot.sidechainSource, ref.source == channel { listening.append((slot.id, ref)) }
        }
        for (slot, _) in listening {
            try updateDeviceSlot(slot) { $0.sidechainSource = nil }
        }
        return listening.map { SetSidechain(slotID: $0.slot, source: $0.ref) }
    }
}
