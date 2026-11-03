/// MODEL-032: the project's invariants. `validate()` checks them all; `UndoStack` runs it after
/// every command in Debug (DW-031). Commands check what they touch with the narrower checks below
/// and throw rather than corrupt the project (MODEL-031).
///
/// A violation throws `routingCycle` for a cycle and `invalidArgument("invariant: …")` otherwise.
extension Project {
    public func validate() throws(DAWError) {
        try validateIDs()
        for track in tracks { try track.validateContents() }
        for bus in buses { try bus.validateContents() }
        try master.validateContents()
        try validateAssets()
        try validateRouting()
        try validateLoop()
        try metronome.validate()
    }

    /// Assets are well-formed and every audio clip's asset exists (T-030). An asset whose file is
    /// missing stays in the project, offline (MODEL-046), so its clips keep a valid reference.
    func validateAssets() throws(DAWError) {
        for asset in assets { try asset.validate() }
        let ids = Set(assets.map(\.id))
        for track in tracks {
            for case .audio(let clip) in track.clips where !ids.contains(clip.assetID) {
                throw .invariant("audio clip \(clip.id) uses missing asset \(clip.assetID)")
            }
        }
        // DW-140: sampler zones name existing assets too.
        try forEachDeviceSlot { (slot, _) throws(DAWError) in
            for zone in slot.zones where !ids.contains(zone.assetID) {
                throw .invariant("sampler \(slot.id) uses missing asset \(zone.assetID)")
            }
        }
    }

    /// The loop region is a non-empty range of non-negative ticks. Its minimum length (DW-060) is
    /// in samples, so a tempo edit can shrink it; `SetLoop` checks that, not this.
    func validateLoop() throws(DAWError) {
        guard let loop else { return }
        guard loop.start.raw >= 0, loop.end > loop.start, loop.end <= Tick.timelineEnd else {
            throw .invariant("loop [\(loop.start.raw), \(loop.end.raw)) is empty or off the timeline")
        }
    }

    /// Every ID is unique and in 1…`GraphNodeID.maxModelID` (NodeIDs carry a role in the top
    /// 8 bits, DW-094), and below the allocator's `next`, so it is never handed out again.
    func validateIDs() throws(DAWError) {
        var seen = Set<ModelID>()
        var problem: String?
        forEachID { id, kind in
            guard problem == nil else { return }
            if id == 0 || id > GraphNodeID.maxModelID {
                problem = "\(kind) id \(id) is outside 1…\(GraphNodeID.maxModelID)"
            } else if id >= ids.next {
                problem = "\(kind) id \(id) is not below the allocator's next id \(ids.next)"
            } else if !seen.insert(id).inserted {
                problem = "\(kind) id \(id) is used twice"
            }
        }
        if let problem { throw .invariant(problem) }
    }

    /// Outputs and sends name existing buses, sidechain sources are tracks or buses, and the
    /// routing is acyclic (MODEL-030).
    func validateRouting() throws(DAWError) {
        for (id, output, sends) in tracks.map({ ($0.id, $0.output, $0.sends) }) + buses.map({ ($0.id, $0.output, $0.sends) }) {
            if case .bus(let target) = output, busIndex(target) == nil {
                throw .invariant("channel \(id) outputs to missing bus \(target)")
            }
            for send in sends where busIndex(send.target) == nil {
                throw .invariant("send \(send.id) targets missing bus \(send.target)")
            }
        }
        try forEachDeviceSlot { (slot, _) throws(DAWError) in
            if let source = slot.sidechainSource?.source, !isTrackOrBus(source) {
                throw .invariant("device slot \(slot.id) has sidechain source \(source), which is no track or bus")
            }
        }
        if let cycle = RoutingGraph(self).cycle() { throw .routingCycle(path: cycle) }
    }

    /// Every ID in the document, with a word for its kind.
    func forEachID(_ body: (ModelID, String) -> Void) {
        body(master.id, "master")
        master.forEachID(body)
        for track in tracks { track.forEachID(body) }
        for bus in buses { bus.forEachID(body) }
        for asset in assets { body(asset.id, "asset") }
    }

    /// MODEL-031: for commands that re-insert an entity with its old IDs (undo of a remove, redo,
    /// JSON). Throws unless every ID is in range and unused, then reserves them in the allocator.
    mutating func claimIDs(_ entity: (_ body: (ModelID, String) -> Void) -> Void) throws(DAWError) {
        var used = Set<ModelID>()
        forEachID { id, _ in used.insert(id) }
        var claimed: [ModelID] = []
        var problem: DAWError?
        entity { id, kind in
            guard problem == nil else { return }
            if id == 0 || id > GraphNodeID.maxModelID {
                problem = .invalidArgument("\(kind) id \(id) is outside 1…\(GraphNodeID.maxModelID)")
            } else if !used.insert(id).inserted {
                problem = .invalidArgument("\(kind) id \(id) is already in use")
            }
            claimed.append(id)
        }
        if let problem { throw problem }
        for id in claimed { ids.reserve(id) }
    }
}

extension DAWError {
    /// MODEL-032: a broken invariant.
    static func invariant(_ detail: String) -> DAWError { .invalidArgument("invariant: \(detail)") }
}

extension ChannelStripState {
    /// +12 dB as linear amplitude: the top of a fader and of a send level (MIX-005, MIX-007).
    public static let maxGain = Float(3.981_071_7)

    func validate(_ owner: NodeIDValue) throws(DAWError) {
        guard gain.isFinite, (0...Self.maxGain).contains(gain) else {
            throw .invariant("channel \(owner) gain \(gain) is outside 0…\(Self.maxGain)")
        }
        guard pan.isFinite, (-1...1).contains(pan) else {
            throw .invariant("channel \(owner) pan \(pan) is outside −1…1")
        }
    }
}

extension Send {
    /// MIX-007: 0…+12 dB, linear.
    public static let maxLevel = ChannelStripState.maxGain

    func validate() throws(DAWError) {
        guard level.isFinite, (0...Self.maxLevel).contains(level) else {
            throw .invariant("send \(id) level \(level) is outside 0…\(Self.maxLevel)")
        }
    }
}

extension DeviceSlot {
    /// The highest param index a slot may store (ParamCatalog reads at most 4096 params a kind).
    public static let maxParamIndex = 4095

    func validate() throws(DAWError) {
        var seen = Set<Int>()
        for param in params {
            guard (0...Self.maxParamIndex).contains(param.index), seen.insert(param.index).inserted else {
                throw .invariant("device slot \(id) has a bad or repeated param index \(param.index)")
            }
            guard param.value.isFinite else { throw .invariant("device slot \(id) param \(param.index) is not finite") }
        }
        // DW-140
        guard zones.isEmpty || isSampler else { throw .invariant("device slot \(id) has zones but is no sampler") }
        for zone in zones { try zone.validate(slot: id) }
    }

    /// T-042: what may sit in an instrument slot. The only built-in instrument is the sampler
    /// (D-19); hosted plugins are taken as they are (the descriptor doesn't say whether it is an
    /// instrument).
    func checkInstrumentKind() throws(DAWError) {
        if case .builtin(let node) = kind, node != .sampler {
            throw .invariant("device slot \(id) is a built-in \(node), which is no instrument")
        }
    }

    func forEachID(_ body: (ModelID, String) -> Void) {
        body(id, "device slot")
    }
}

extension Track {
    func forEachID(_ body: (ModelID, String) -> Void) {
        body(id, "track")
        for clip in clips { clip.forEachID(body) }
        for folder in takeFolders { body(folder.id, "take folder") }
        instrument?.forEachID(body)
        for slot in inserts { slot.forEachID(body) }
        for send in sends { body(send.id, "send") }
        for lane in automation { body(lane.id, "automation lane") }
    }

    /// Everything about the track that doesn't depend on the rest of the project.
    func validateContents() throws(DAWError) {
        try strip.validate(id)
        for send in sends { try send.validate() }
        if let instrument {
            // T-042: the instrument slot is a MIDI track's; a built-in one is the sampler (D-19).
            guard kind == .midi else { throw .invariant("audio track \(id) has an instrument") }
            try instrument.checkInstrumentKind()
            try instrument.validate()
        }
        for slot in inserts { try slot.validate() }
        for (i, clip) in clips.enumerated() {
            switch clip {
            case .audio(let audio):
                guard kind == .audio else { throw .invariant("audio clip \(audio.id) on MIDI track \(id)") }
            case .midi(let midi):
                guard kind == .midi else { throw .invariant("MIDI clip \(midi.id) on audio track \(id)") }
            }
            try clip.validate()
            // DW-110
            if i > 0, !Clip.timelineOrder(clips[i - 1], clip) {
                throw .invariant("clips of track \(id) are not sorted by start (then id)")
            }
        }
    }
}

extension MidiClip {
    /// Notes are sorted by (start, id) and each is in range (`Note.validate`, T-042).
    func validateNotes() throws(DAWError) {
        for (i, note) in notes.enumerated() {
            if i > 0, !Note.clipOrder(notes[i - 1], note) {
                throw .invariant("notes of clip \(id) are not sorted by start (then id)")
            }
            try note.validate()
        }
    }
}

extension Bus {
    func forEachID(_ body: (ModelID, String) -> Void) {
        body(id, "bus")
        for slot in inserts { slot.forEachID(body) }
        for send in sends { body(send.id, "send") }
        for lane in automation { body(lane.id, "automation lane") }
    }

    func validateContents() throws(DAWError) {
        try strip.validate(id)
        for send in sends { try send.validate() }
        for slot in inserts { try slot.validate() }
    }
}

extension MasterChannel {
    /// Everything inside the master but its own ID.
    func forEachID(_ body: (ModelID, String) -> Void) {
        for slot in inserts { slot.forEachID(body) }
        for lane in automation { body(lane.id, "automation lane") }
    }

    func validateContents() throws(DAWError) {
        try strip.validate(id)
        for slot in inserts { try slot.validate() }
    }
}
