/// T-088 (MODEL-005, DW-149): the insert chains of tracks, buses and the master, for
/// `InsertDevice`, `RemoveDevice`, `RestoreDevice` and `MoveDevice`. The master is addressed by its
/// ID like a track or bus (DECISIONS "T-088 master"). An instrument slot is no insert: it keeps its
/// own commands (`SetInstrument`, `RemoveInstrument`), and the insert commands reject it.
extension Project {
    /// The insert chain of a track, bus or the master, in signal order.
    public func inserts(of channel: NodeIDValue) -> [DeviceSlot]? {
        if channel == master.id { return master.inserts }
        return track(channel)?.inserts ?? bus(channel)?.inserts
    }

    public mutating func updateInserts<R>(
        of channel: NodeIDValue, _ body: (inout [DeviceSlot]) throws(DAWError) -> R
    ) throws(DAWError) -> R {
        if channel == master.id { return try body(&master.inserts) }
        if let i = trackIndex(channel) { return try body(&tracks[i].inserts) }
        if let i = busIndex(channel) { return try body(&buses[i].inserts) }
        throw .notFound(kind: "channel", id: channel)
    }

    /// The channel whose insert chain holds slot `id`, and the slot's index in it. Nil for an
    /// unknown ID and for an instrument slot.
    public func insertLocation(_ id: NodeIDValue) -> (channel: NodeIDValue, index: Int)? {
        for track in tracks {
            if let i = track.inserts.firstIndex(where: { $0.id == id }) { return (track.id, i) }
        }
        for bus in buses {
            if let i = bus.inserts.firstIndex(where: { $0.id == id }) { return (bus.id, i) }
        }
        if let i = master.inserts.firstIndex(where: { $0.id == id }) { return (master.id, i) }
        return nil
    }

    /// `insertLocation`, or `notFound` for an unknown slot and `invalidArgument` for an instrument
    /// slot (MODEL-031).
    func requireInsertLocation(_ id: NodeIDValue) throws(DAWError) -> (channel: NodeIDValue, index: Int) {
        if let location = insertLocation(id) { return location }
        if tracks.contains(where: { $0.instrument?.id == id }) {
            throw .invalidArgument("device slot \(id) is an instrument, not an insert (use RemoveInstrument or SetInstrument)")
        }
        throw .notFound(kind: "device slot", id: id)
    }

    /// Puts `slot` into `channel`'s chain at `index` (nil: at the end) and returns the index used.
    /// The slot's ID must already be reserved. Checks the slot like `validate()` would (MODEL-031),
    /// and that its sidechain can't close a cycle (MODEL-030).
    @discardableResult
    mutating func placeInsert(_ slot: DeviceSlot, on channel: NodeIDValue, at index: Int?) throws(DAWError) -> Int {
        guard let count = inserts(of: channel)?.count else { throw .notFound(kind: "channel", id: channel) }
        let at = index ?? count
        guard (0...count).contains(at) else { throw .invalidArgument("insert index \(at) is outside 0…\(count)") }
        try slot.validate()
        try checkZoneAssets(slot.zones)
        if let source = slot.sidechainSource?.source {
            guard isTrackOrBus(source) else { throw .notFound(kind: "track or bus", id: source) }
            try checkNewRoute(from: source, to: channel)
        }
        try updateInserts(of: channel) { $0.insert(slot, at: at) }
        return at
    }
}

extension DeviceSlot {
    /// T-088: the built-ins `InsertDevice` places in an insert chain, the effects of 06. The
    /// sampler is an instrument (D-19); the other kinds are structure the graph builder makes.
    public static let builtinInsertKinds: Set<NodeKind> = [.gain, .eq, .compressor, .delay, .reverb]

    /// T-088: what may go into an insert chain through `InsertDevice`: a built-in effect or a
    /// hosted plugin (the descriptor doesn't say whether it is an effect, so plugins are taken as
    /// they are, like the instrument slot does).
    func checkInsertKind() throws(DAWError) {
        guard case .builtin(let node) = kind else { return }
        if node == .sampler {
            throw .invalidArgument("the built-in sampler is an instrument, not an insert (use SetInstrument)")
        }
        guard Self.builtinInsertKinds.contains(node) else {
            throw .invalidArgument("built-in \(node.rawValue) is not an insert effect")
        }
    }
}
