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
        try validateRouting()
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
    }

    func forEachID(_ body: (ModelID, String) -> Void) {
        body(id, "device slot")
    }
}

extension Track {
    func forEachID(_ body: (ModelID, String) -> Void) {
        body(id, "track")
        for clip in clips {
            body(clip.id, "clip")
            if case .midi(let midi) = clip { for note in midi.notes { body(note.id, "note") } }
        }
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
        try instrument?.validate()
        for slot in inserts { try slot.validate() }
        for clip in clips {
            guard clip.start.raw >= 0, clip.length.raw > 0 else {
                throw .invariant("clip \(clip.id) has start \(clip.start.raw), length \(clip.length.raw)")
            }
            switch clip {
            case .audio(let audio):
                guard kind == .audio else { throw .invariant("audio clip \(audio.id) on MIDI track \(id)") }
                guard audio.sourceOffsetSamples >= 0, audio.fadeIn.raw >= 0, audio.fadeOut.raw >= 0 else {
                    throw .invariant("audio clip \(audio.id) has a negative offset or fade")
                }
            case .midi(let midi):
                guard kind == .midi else { throw .invariant("MIDI clip \(midi.id) on audio track \(id)") }
                try midi.validateNotes()
            }
        }
    }
}

extension MidiClip {
    /// Notes are sorted by start, have a length, and fit MIDI's ranges.
    func validateNotes() throws(DAWError) {
        var previous = Tick(Int64.min)
        for note in notes {
            guard note.start >= previous else { throw .invariant("notes of clip \(id) are not sorted by start") }
            previous = note.start
            guard note.length.raw > 0, note.pitch <= 127, note.velocity <= 127, note.channel <= 15 else {
                throw .invariant("note \(note.id) has length \(note.length.raw), pitch \(note.pitch), velocity \(note.velocity), channel \(note.channel)")
            }
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
