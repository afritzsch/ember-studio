/// Lookups and in-place updates for the routing commands (MODEL-005, MODEL-031): channels, sends
/// and device slots by ID. Every `update…` throws `notFound` for an unknown ID instead of changing
/// anything.
///
/// "Channel" means a track, a bus or the master. Only tracks and buses route: they have an output
/// and sends. The master is the sink.
extension Project {
    public func isTrackOrBus(_ id: NodeIDValue) -> Bool {
        trackIndex(id) != nil || busIndex(id) != nil
    }

    /// The main output of a track or bus.
    public func output(of channel: NodeIDValue) -> OutputTarget? {
        track(channel)?.output ?? bus(channel)?.output
    }

    /// The sends of a track or bus.
    public func sends(of channel: NodeIDValue) -> [Send]? {
        track(channel)?.sends ?? bus(channel)?.sends
    }

    /// The strip of a track, bus or the master.
    public func strip(of channel: NodeIDValue) -> ChannelStripState? {
        if channel == master.id { return master.strip }
        return track(channel)?.strip ?? bus(channel)?.strip
    }

    public mutating func updateOutput<R>(
        of channel: NodeIDValue, _ body: (inout OutputTarget) throws(DAWError) -> R
    ) throws(DAWError) -> R {
        if let i = trackIndex(channel) { return try body(&tracks[i].output) }
        if let i = busIndex(channel) { return try body(&buses[i].output) }
        throw .notFound(kind: "track or bus", id: channel)
    }

    public mutating func updateSends<R>(
        of channel: NodeIDValue, _ body: (inout [Send]) throws(DAWError) -> R
    ) throws(DAWError) -> R {
        if let i = trackIndex(channel) { return try body(&tracks[i].sends) }
        if let i = busIndex(channel) { return try body(&buses[i].sends) }
        throw .notFound(kind: "track or bus", id: channel)
    }

    public mutating func updateStrip<R>(
        of channel: NodeIDValue, _ body: (inout ChannelStripState) throws(DAWError) -> R
    ) throws(DAWError) -> R {
        if channel == master.id { return try body(&master.strip) }
        if let i = trackIndex(channel) { return try body(&tracks[i].strip) }
        if let i = busIndex(channel) { return try body(&buses[i].strip) }
        throw .notFound(kind: "channel", id: channel)
    }

    /// The track or bus that owns send `id`, and the send's index in its list.
    public func sendLocation(_ id: ModelID) -> (channel: NodeIDValue, index: Int)? {
        for track in tracks {
            if let i = track.sends.firstIndex(where: { $0.id == id }) { return (track.id, i) }
        }
        for bus in buses {
            if let i = bus.sends.firstIndex(where: { $0.id == id }) { return (bus.id, i) }
        }
        return nil
    }

    public mutating func updateSend<R>(
        _ id: ModelID, _ body: (inout Send) throws(DAWError) -> R
    ) throws(DAWError) -> R {
        guard let (channel, index) = sendLocation(id) else { throw .notFound(kind: "send", id: id) }
        return try updateSends(of: channel) { (sends: inout [Send]) throws(DAWError) -> R in
            try body(&sends[index])
        }
    }

    /// Calls `body` with every device slot (instruments, track, bus and master inserts) and the
    /// channel that holds it, in layout order. Unlike the graph builder, it includes bypassed
    /// slots and an instrument on an audio track: routing checks count them all.
    public func forEachDeviceSlot<E: Error>(_ body: (DeviceSlot, _ channel: NodeIDValue) throws(E) -> Void) throws(E) {
        for track in tracks {
            if let instrument = track.instrument { try body(instrument, track.id) }
            for slot in track.inserts { try body(slot, track.id) }
        }
        for bus in buses {
            for slot in bus.inserts { try body(slot, bus.id) }
        }
        for slot in master.inserts { try body(slot, master.id) }
    }

    /// The channel that holds device slot `id`.
    public func deviceSlotOwner(_ id: NodeIDValue) -> NodeIDValue? {
        var owner: NodeIDValue?
        forEachDeviceSlot { slot, channel in
            if slot.id == id { owner = channel }
        }
        return owner
    }

    public mutating func updateDeviceSlot<R>(
        _ id: NodeIDValue, _ body: (inout DeviceSlot) throws(DAWError) -> R
    ) throws(DAWError) -> R {
        for t in tracks.indices {
            if tracks[t].instrument?.id == id { return try body(&tracks[t].instrument!) }
            if let i = tracks[t].inserts.firstIndex(where: { $0.id == id }) { return try body(&tracks[t].inserts[i]) }
        }
        for b in buses.indices {
            if let i = buses[b].inserts.firstIndex(where: { $0.id == id }) { return try body(&buses[b].inserts[i]) }
        }
        if let i = master.inserts.firstIndex(where: { $0.id == id }) { return try body(&master.inserts[i]) }
        throw .notFound(kind: "device slot", id: id)
    }

    /// MODEL-030: throws `routingCycle` if routing `from` into `to` (an output, a send or a
    /// sidechain) would close a cycle. The path follows the new route and comes back:
    /// `[from, to, …, from]`. Run it on the project before the route is added.
    public func checkNewRoute(from: NodeIDValue, to: NodeIDValue) throws(DAWError) {
        if let back = RoutingGraph(self).path(from: to, to: from) {
            throw .routingCycle(path: [from] + back)
        }
    }

    /// MODEL-031: throws unless `target` exists.
    func checkOutputTarget(_ target: OutputTarget) throws(DAWError) {
        if case .bus(let id) = target, busIndex(id) == nil { throw .notFound(kind: "bus", id: id) }
    }
}
