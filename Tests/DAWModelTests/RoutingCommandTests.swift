import DAWModel
import Foundation
import Testing

// MODEL-005 (routing subset), MODEL-030 and MODEL-031: track, bus, send, output, sidechain and
// param commands.

/// Two tracks, two buses, a compressor on Vox and an EQ on the master:
///
///   Vox (comp) → A → master;  Vox post-send → B
///   Kick → master;            Kick pre-send → A
///   A → master;  B → master
enum RoutingProject {
    static func make() -> Project {
        var p = Project(id: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!, name: "routing")
        let a = p.ids.allocate()
        let b = p.ids.allocate()
        let vox = p.ids.allocate()
        let kick = p.ids.allocate()
        p.buses = [Bus(id: a, name: "A"), Bus(id: b, name: "B")]
        p.tracks = [
            Track(id: vox, name: "Vox", kind: .audio,
                  inserts: [DeviceSlot(id: p.ids.allocate(), kind: .builtin(.compressor))],
                  sends: [Send(id: p.ids.allocate(), target: b, level: 0.5)], output: .bus(a)),
            Track(id: kick, name: "Kick", kind: .audio,
                  sends: [Send(id: p.ids.allocate(), target: a, level: 0.25, tap: .preFader)]),
        ]
        p.master.inserts = [DeviceSlot(id: p.ids.allocate(), kind: .builtin(.eq))]
        return p
    }
}

extension Project {
    var a: Bus { buses[0] }
    var b: Bus { buses[1] }
    var vox: Track { tracks[0] }
    var kick: Track { tracks[1] }
}

/// Applies `command`, its inverse and the inverse's inverse; the project must go there, back,
/// and there again, and the inverses must survive JSON (MODEL-006) as the undo stack may persist
/// them one day. Returns the applied state.
@discardableResult
func expectApplyRoundTrip(
    _ command: any Command, on project: Project, sourceLocation: SourceLocation = #_sourceLocation
) throws -> Project {
    var p = project
    let inverse = try command.apply(to: &p)
    let applied = p
    #expect(applied != project, "\(type(of: command).type) changed nothing", sourceLocation: sourceLocation)
    try applied.validate()

    let decodedInverse = try CommandRegistry.decode(CommandRegistry.encode(inverse))
    let redo = try decodedInverse.apply(to: &p)
    #expect(p == project, "the inverse of \(type(of: command).type) restores the project", sourceLocation: sourceLocation)
    try p.validate()

    _ = try redo.apply(to: &p)
    #expect(p == applied, "the redo of \(type(of: command).type) gives the same project", sourceLocation: sourceLocation)
    return applied
}

@Suite("Routing commands")
struct RoutingCommandTests {
    init() { TestCommands.register() }

    let p = RoutingProject.make()

    // MARK: MODEL-005

    @Test("MODEL-005: AddTrack, RemoveTrack, MoveTrack and RenameTrack round-trip")
    func trackCommands() throws {
        let added = try expectApplyRoundTrip(AddTrack(name: "Bass", kind: .midi, index: 1, output: .bus(p.b.id)), on: p)
        #expect(added.tracks.map(\.name) == ["Vox", "Bass", "Kick"])
        #expect(added.tracks[1].kind == .midi && added.tracks[1].output == .bus(p.b.id))
        #expect(added.tracks[1].id == p.ids.next, "a new ID from the allocator")
        #expect(try expectApplyRoundTrip(AddTrack(name: "End", kind: .audio), on: p).tracks.last?.name == "End")

        let removed = try expectApplyRoundTrip(RemoveTrack(trackID: p.vox.id), on: p)
        #expect(removed.tracks.map(\.name) == ["Kick"])

        let moved = try expectApplyRoundTrip(MoveTrack(trackID: p.vox.id, index: 1), on: p)
        #expect(moved.tracks.map(\.name) == ["Kick", "Vox"])
        try expectApplyRoundTrip(RenameTrack(trackID: p.kick.id, name: "Kick In"), on: p)
    }

    @Test("MODEL-005: redoing an add recreates the same IDs, so later history entries still apply")
    func redoKeepsIDs() throws {
        var project = p
        var stack = UndoStack()
        try stack.perform(AddTrack(name: "Bass", kind: .audio), on: &project)
        let bass = project.tracks.last!.id
        try stack.perform(AddBus(name: "C"), on: &project)
        let c = project.buses.last!.id
        try stack.perform(AddSend(channelID: bass, busID: c, level: 0.5), on: &project)
        try stack.perform(SetTrackOutput(channelID: bass, output: .bus(c)), on: &project)
        let final = project

        while try stack.undo(&project) != nil {}
        #expect(project == p)
        while try stack.redo(&project) != nil {}
        #expect(project == final)
        #expect(project.tracks.last?.id == bass && project.buses.last?.id == c)
    }

    @Test("MODEL-005: SetTrackOutput routes tracks and buses")
    func setOutput() throws {
        #expect(try expectApplyRoundTrip(SetTrackOutput(channelID: p.vox.id, output: .master), on: p).vox.output == .master)
        #expect(try expectApplyRoundTrip(SetTrackOutput(channelID: p.kick.id, output: .bus(p.b.id)), on: p).kick.output == .bus(p.b.id))
        #expect(try expectApplyRoundTrip(SetTrackOutput(channelID: p.a.id, output: .bus(p.b.id)), on: p).a.output == .bus(p.b.id))
    }

    @Test("MODEL-005: AddBus round-trips; RemoveBus takes the sends, outputs and sidechains that use it, and undo restores them")
    func busCommands() throws {
        let added = try expectApplyRoundTrip(AddBus(name: "C", index: 0, output: .bus(p.a.id)), on: p)
        #expect(added.buses.map(\.name) == ["C", "A", "B"] && added.buses[0].output == .bus(p.a.id))

        // B feeds A, a master insert listens to A, and Vox's compressor listens to Kick.
        // Removing A must cut Kick's send, Vox's and B's outputs and the master's sidechain.
        var q = p
        q.buses[1].output = .bus(p.a.id)
        q.master.inserts[0].sidechainSource = SidechainRef(source: p.a.id)
        q.tracks[0].inserts[0].sidechainSource = SidechainRef(source: p.kick.id, tap: .preFader)
        try q.validate()
        let removed = try expectApplyRoundTrip(RemoveBus(busID: p.a.id), on: q)
        #expect(removed.buses.map(\.name) == ["B"])
        #expect(removed.vox.output == .master && removed.buses[0].output == .master)
        #expect(removed.kick.sends.isEmpty && removed.vox.sends.count == 1)
        #expect(removed.master.inserts[0].sidechainSource == nil)
        #expect(removed.vox.inserts[0].sidechainSource == SidechainRef(source: p.kick.id, tap: .preFader))
    }

    @Test("MODEL-004: removing a track clears sidechains listening to it, as one undo entry")
    func removeTrackClearsSidechains() throws {
        var q = p
        q.master.inserts[0].sidechainSource = SidechainRef(source: p.kick.id)
        let removed = try expectApplyRoundTrip(RemoveTrack(trackID: p.kick.id), on: q)
        #expect(removed.master.inserts[0].sidechainSource == nil)

        var stack = UndoStack()
        try stack.perform(RemoveTrack(trackID: p.kick.id), on: &q)
        #expect(stack.undoEntries.count == 1 && stack.undoLabel == "Remove Track")
    }

    @Test("MODEL-005: AddSend, RemoveSend, SetSendLevel, SetSendTap round-trip")
    func sendCommands() throws {
        let added = try expectApplyRoundTrip(AddSend(channelID: p.kick.id, busID: p.b.id, level: 2, tap: .preFader), on: p)
        #expect(added.kick.sends.last == Send(id: p.ids.next, target: p.b.id, level: 2, tap: .preFader))
        let bussed = try expectApplyRoundTrip(AddSend(channelID: p.a.id, busID: p.b.id), on: p)
        #expect(bussed.a.sends == [Send(id: p.ids.next, target: p.b.id, level: 1, tap: .postFader)])

        var two = p
        two.tracks[0].sends.append(Send(id: two.ids.allocate(), target: p.a.id))
        let removed = try expectApplyRoundTrip(RemoveSend(sendID: two.vox.sends[0].id), on: two)
        #expect(removed.vox.sends.map(\.target) == [p.a.id], "the other send keeps its place; undo puts the first back at index 0")

        #expect(try expectApplyRoundTrip(SetSendLevel(sendID: p.vox.sends[0].id, level: 0), on: p).vox.sends[0].level == 0)
        #expect(try expectApplyRoundTrip(SetSendTap(sendID: p.kick.sends[0].id, tap: .postFader), on: p).kick.sends[0].tap == .postFader)
    }

    @Test("MODEL-005: SetSidechain sets and clears a device's sidechain source")
    func sidechain() throws {
        let comp = p.vox.inserts[0].id
        let set = try expectApplyRoundTrip(SetSidechain(slotID: comp, source: SidechainRef(source: p.kick.id, tap: .preFader)), on: p)
        #expect(set.vox.inserts[0].sidechainSource == SidechainRef(source: p.kick.id, tap: .preFader))
        let cleared = try expectApplyRoundTrip(SetSidechain(slotID: comp, source: nil), on: set)
        #expect(cleared == p)
        // The master can listen to anything: nothing comes back out of it.
        try expectApplyRoundTrip(SetSidechain(slotID: p.master.inserts[0].id, source: SidechainRef(source: p.a.id)), on: p)
    }

    @Test("MODEL-005, DW-094: SetParam reaches strip controls, send levels and device params")
    func setParam() throws {
        func set(_ target: ParamTarget, _ value: Float?, on project: Project? = nil) throws -> Project {
            try expectApplyRoundTrip(SetParam(target: target, value: value), on: project ?? p)
        }
        #expect(try set(.strip(channel: p.vox.id, param: .gain), 0.5).vox.strip.gain == 0.5)
        #expect(try set(.strip(channel: p.a.id, param: .pan), -1).a.strip.pan == -1)
        #expect(try set(.strip(channel: p.master.id, param: .gain), ChannelStripState.maxGain).master.strip.gain == ChannelStripState.maxGain)
        #expect(try set(.strip(channel: p.kick.id, param: .mute), 1).kick.strip.mute)
        #expect(try set(.strip(channel: p.b.id, param: .solo), 0.5).b.strip.solo, "switches are on at ≥ 0.5")
        #expect(try set(.strip(channel: p.vox.id, param: .phase), 1).vox.strip.phaseInvert)
        #expect(try set(.sendLevel(send: p.kick.sends[0].id), 1.5).kick.sends[0].level == 1.5)

        // Device params stay sorted by index; nil removes the stored value (back to the default).
        let comp = p.vox.inserts[0].id
        let one = try set(.device(slot: comp, index: 3), 0.7)
        let two = try set(.device(slot: comp, index: 1), 0.2, on: one)
        #expect(two.vox.inserts[0].params == [ParamValue(index: 1, value: 0.2), ParamValue(index: 3, value: 0.7)])
        #expect(try set(.device(slot: comp, index: 3), 0.9, on: two).vox.inserts[0].params.map(\.value) == [0.2, 0.9])
        #expect(try set(.device(slot: comp, index: 1), nil, on: two).vox.inserts[0].params == [ParamValue(index: 3, value: 0.7)])

        #expect(SetParam(target: .strip(channel: 1, param: .gain), value: 1).label == "Set Gain")
        #expect(SetParam(target: .device(slot: 1, index: 0), value: 1).label == "Set Parameter")
    }

    @Test("DW-094: ParamTarget JSON shape")
    func paramTargetJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func json(_ target: ParamTarget) throws -> String { String(decoding: try encoder.encode(target), as: UTF8.self) }
        #expect(try json(.strip(channel: 7, param: .gain)) == #"{"channel":7,"kind":"strip","param":"gain"}"#)
        #expect(try json(.sendLevel(send: 9)) == #"{"kind":"sendLevel","send":9}"#)
        #expect(try json(.device(slot: 5, index: 2)) == #"{"index":2,"kind":"device","slot":5}"#)
        let decoded = try CommandRegistry.decode(Data(#"{"type":"SetParam","target":{"kind":"strip","channel":3,"param":"mute"},"value":1}"#.utf8))
        #expect((decoded as? SetParam)?.target == .strip(channel: 3, param: .mute))
    }

    // MARK: MODEL-030

    @Test("MODEL-030: bus A → B, then B → A is rejected with the cycle's path")
    func busCycle() throws {
        var project = p
        var stack = UndoStack()
        try stack.perform(SetTrackOutput(channelID: p.a.id, output: .bus(p.b.id)), on: &project)
        let before = project
        #expect(throws: DAWError.routingCycle(path: [p.b.id, p.a.id, p.b.id])) {
            try stack.perform(SetTrackOutput(channelID: p.b.id, output: .bus(p.a.id)), on: &project)
        }
        #expect(throws: DAWError.routingCycle(path: [p.b.id, p.a.id, p.b.id])) {
            try stack.perform(AddSend(channelID: p.b.id, busID: p.a.id), on: &project)
        }
        #expect(project == before && stack.undoEntries.count == 1, "a rejected edit changes nothing")
    }

    @Test("MODEL-030: self-routing and longer cycles through sends and sidechains are rejected")
    func otherCycles() throws {
        let a = p.a.id, b = p.b.id, vox = p.vox.id, kick = p.kick.id
        func expectCycle(_ path: [NodeIDValue], on project: Project? = nil, _ command: any Command,
                         sourceLocation: SourceLocation = #_sourceLocation) {
            var q = project ?? p
            #expect(throws: DAWError.routingCycle(path: path), sourceLocation: sourceLocation) { _ = try command.apply(to: &q) }
        }
        expectCycle([a, a], SetTrackOutput(channelID: a, output: .bus(a)))
        expectCycle([b, b], AddSend(channelID: b, busID: b))

        // A sidechain from a channel into its own device closes a loop through the device.
        let comp = p.vox.inserts[0].id
        expectCycle([vox, vox], SetSidechain(slotID: comp, source: SidechainRef(source: vox, tap: .preFader)))
        // Vox feeds A, so A can't sidechain Vox's compressor.
        expectCycle([a, vox, a], SetSidechain(slotID: comp, source: SidechainRef(source: a)))

        // A 3-bus chain: A → B → C → master; then C → A closes it through two hops. Kick's
        // sidechain from C into Vox: the shortest way back is Vox → B (send) → C.
        var chain = p
        _ = try AddBus(name: "C").apply(to: &chain)
        let c = chain.buses[2].id
        _ = try SetTrackOutput(channelID: a, output: .bus(b)).apply(to: &chain)
        _ = try AddSend(channelID: b, busID: c).apply(to: &chain)
        expectCycle([c, a, b, c], on: chain, SetTrackOutput(channelID: c, output: .bus(a)))
        expectCycle([c, vox, b, c], on: chain, SetSidechain(slotID: comp, source: SidechainRef(source: c)))
        // Fine: C → master, Kick → C, sidechain from C into a master insert.
        var ok = chain
        _ = try SetTrackOutput(channelID: kick, output: .bus(c)).apply(to: &ok)
        _ = try SetSidechain(slotID: p.master.inserts[0].id, source: SidechainRef(source: c)).apply(to: &ok)
        try ok.validate()
    }

    @Test("MODEL-030: a bypassed device's sidechain still counts, so un-bypassing never needs a check")
    func bypassedSidechainCounts() {
        var q = p
        q.tracks[0].inserts[0].bypass = true
        q.buses[0].inserts = [DeviceSlot(id: q.ids.allocate(), kind: .builtin(.compressor), bypass: true,
                                         sidechainSource: SidechainRef(source: p.b.id))]
        // B → (sidechain) A; Vox → A and Vox → B already. Now B → A as an output is fine...
        var r = q
        #expect(throws: Never.self) { _ = try SetTrackOutput(channelID: p.b.id, output: .bus(p.a.id)).apply(to: &r) }
        // ...but A → B closes A → B → (sidechain) A.
        #expect(throws: DAWError.routingCycle(path: [p.a.id, p.b.id, p.a.id])) {
            _ = try SetTrackOutput(channelID: p.a.id, output: .bus(p.b.id)).apply(to: &q)
        }
    }

    // MARK: MODEL-031

    @Test("MODEL-031: unknown IDs and bad arguments throw and change nothing")
    func invalidCommands() {
        let missing: NodeIDValue = 999
        let comp = p.vox.inserts[0].id
        let cases: [(any Command, DAWError)] = [
            (RemoveTrack(trackID: missing), .notFound(kind: "track", id: missing)),
            (RemoveTrack(trackID: p.a.id), .notFound(kind: "track", id: p.a.id)),
            (MoveTrack(trackID: missing, index: 0), .notFound(kind: "track", id: missing)),
            (MoveTrack(trackID: p.vox.id, index: 2), .invalidArgument("track index 2 is outside 0…1")),
            (AddTrack(name: "x", kind: .audio, index: 3), .invalidArgument("track index 3 is outside 0…2")),
            (AddTrack(name: "x", kind: .audio, output: .bus(p.vox.id)), .notFound(kind: "bus", id: p.vox.id)),
            (AddBus(name: "x", index: -1), .invalidArgument("bus index -1 is outside 0…2")),
            (AddBus(name: "x", output: .bus(missing)), .notFound(kind: "bus", id: missing)),
            (RemoveBus(busID: p.vox.id), .notFound(kind: "bus", id: p.vox.id)),
            (SetTrackOutput(channelID: p.master.id, output: .bus(p.a.id)), .notFound(kind: "track or bus", id: p.master.id)),
            (SetTrackOutput(channelID: p.vox.id, output: .bus(p.kick.id)), .notFound(kind: "bus", id: p.kick.id)),
            (AddSend(channelID: missing, busID: p.a.id), .notFound(kind: "track or bus", id: missing)),
            (AddSend(channelID: p.vox.id, busID: p.master.id), .notFound(kind: "bus", id: p.master.id)),
            (AddSend(channelID: p.vox.id, busID: p.a.id, level: -0.1), .invalidArgument("send level -0.1 is outside 0…3.9810717")),
            (AddSend(channelID: p.vox.id, busID: p.a.id, level: .nan), .invalidArgument("send level nan is outside 0…3.9810717")),
            (RemoveSend(sendID: p.vox.id), .notFound(kind: "send", id: p.vox.id)),
            (SetSendLevel(sendID: p.vox.sends[0].id, level: 4), .invalidArgument("send level 4.0 is outside 0…3.9810717")),
            (SetSendTap(sendID: missing, tap: .preFader), .notFound(kind: "send", id: missing)),
            (SetSidechain(slotID: p.vox.id, source: nil), .notFound(kind: "device slot", id: p.vox.id)),
            (SetSidechain(slotID: comp, source: SidechainRef(source: p.master.id)), .notFound(kind: "track or bus", id: p.master.id)),
            (SetParam(target: .strip(channel: missing, param: .gain), value: 1), .notFound(kind: "channel", id: missing)),
            (SetParam(target: .strip(channel: p.vox.id, param: .gain), value: 4), .invalidArgument("gain 4.0 is outside 0…3.9810717")),
            (SetParam(target: .strip(channel: p.vox.id, param: .pan), value: 1.5), .invalidArgument("pan 1.5 is outside −1…1")),
            (SetParam(target: .strip(channel: p.vox.id, param: .pan), value: .infinity), .invalidArgument("pan inf is not finite")),
            (SetParam(target: .strip(channel: p.vox.id, param: .mute), value: nil), .invalidArgument("mute needs a value")),
            (SetParam(target: .strip(channel: p.master.id, param: .solo), value: 1), .invalidArgument("the master has no solo")),
            (SetParam(target: .sendLevel(send: missing), value: 1), .notFound(kind: "send", id: missing)),
            (SetParam(target: .device(slot: comp, index: -1), value: 1), .invalidArgument("param index -1 is outside 0…4095")),
            (SetParam(target: .device(slot: comp, index: 0), value: .nan), .invalidArgument("param value nan is not finite")),
            (SetParam(target: .device(slot: missing, index: 0), value: 1), .notFound(kind: "device slot", id: missing)),
            (RestoreSend(channelID: p.kick.id, send: Send(id: p.vox.id, target: p.b.id), index: 0),
             .invalidArgument("send id \(p.vox.id) is already in use")),
            (RestoreSend(channelID: p.kick.id, send: Send(id: 900, target: p.b.id), index: 2), .invalidArgument("send index 2 is outside 0…1")),
            (RestoreTrack(track: Track(id: GraphNodeID.maxModelID + 1, name: "x", kind: .audio), index: 0),
             .invalidArgument("track id \(GraphNodeID.maxModelID + 1) is outside 1…\(GraphNodeID.maxModelID)")),
            (RestoreTrack(track: Track(id: 900, name: "x", kind: .audio, output: .bus(missing)), index: 0),
             .brokenInvariant("channel 900 outputs to missing bus \(missing)")),
            (RestoreBus(bus: Bus(id: 900, name: "x", sends: [Send(id: 901, target: 900)]), index: 0),
             .routingCycle(path: [900, 900])),
        ]
        for (command, error) in cases {
            var q = p
            #expect(throws: error, "\(type(of: command).type)") { _ = try command.applyChecked(to: &q) }
        }
    }

    @Test("MODEL-031: fuzz — random routing commands, valid or not, never break an invariant; undo-all restores the start")
    func fuzz() throws {
        var rng = SplitMix64(seed: 0x7_0022)
        var performed = 0
        var rejected = 0
        for _ in 0..<150 {
            var project = p
            var stack = UndoStack()
            for _ in 0..<40 {
                let command = randomRoutingCommand(for: project, using: &rng)
                let before = project
                do {
                    try stack.perform(command, on: &project)
                    performed += 1
                } catch {
                    rejected += 1
                    #expect(project == before)
                }
                try project.validate()
            }
            while try stack.undo(&project) != nil { try project.validate() }
            #expect(project == p)
        }
        #expect(performed > 2000 && rejected > 1000, "performed \(performed), rejected \(rejected)")
    }
}

extension Command {
    /// Like UndoStack: apply to a copy, keep it only on success.
    func applyChecked(to project: inout Project) throws(DAWError) -> any Command {
        var working = project
        let inverse = try apply(to: &working)
        project = working
        return inverse
    }
}

extension DAWError {
    static func brokenInvariant(_ detail: String) -> DAWError { .invalidArgument("invariant: \(detail)") }
}

/// Half of these name real channels, sends and slots; the rest pick from all IDs or a missing one.
func randomRoutingCommand(for project: Project, using rng: inout SplitMix64) -> any Command {
    let tracks = project.tracks.map(\.id)
    let buses = project.buses.map(\.id)
    let channels = tracks + buses
    let sends = (project.tracks.flatMap(\.sends) + project.buses.flatMap(\.sends)).map(\.id)
    var slots: [NodeIDValue] = []
    project.forEachDeviceSlot { slot, _ in slots.append(slot.id) }
    let anything = channels + sends + slots + [project.master.id, 999]
    func pick(_ ids: [ModelID]) -> ModelID {
        (Bool.random(using: &rng) ? ids.randomElement(using: &rng) : nil) ?? anything.randomElement(using: &rng)!
    }
    func output() -> OutputTarget { Int.random(in: 0..<4, using: &rng) == 0 ? .master : .bus(pick(buses)) }
    func level() -> Float { [0, 0.5, 1, 3.9, 4, -1].randomElement(using: &rng)! }
    func tap() -> SignalTap { Bool.random(using: &rng) ? .preFader : .postFader }

    switch Int.random(in: 0..<16, using: &rng) {
    case 0: return AddTrack(name: "T", kind: Bool.random(using: &rng) ? .audio : .midi,
                            index: Int.random(in: -1...tracks.count + 1, using: &rng), output: output())
    case 1: return RemoveTrack(trackID: pick(tracks))
    case 2: return MoveTrack(trackID: pick(tracks), index: Int.random(in: -1...tracks.count, using: &rng))
    case 3: return AddBus(name: "B", output: output())
    case 4: return RemoveBus(busID: pick(buses))
    case 5, 6: return SetTrackOutput(channelID: pick(channels), output: output())
    case 7, 8: return AddSend(channelID: pick(channels), busID: pick(buses), level: level(), tap: tap())
    case 9: return RemoveSend(sendID: pick(sends))
    case 10: return SetSendLevel(sendID: pick(sends), level: level())
    case 11: return SetSendTap(sendID: pick(sends), tap: tap())
    case 12, 13:
        return SetSidechain(slotID: pick(slots), source: Bool.random(using: &rng) ? SidechainRef(source: pick(channels), tap: tap()) : nil)
    case 14:
        let param = [ParamTarget.StripParam.gain, .pan, .mute, .solo, .phase].randomElement(using: &rng)!
        return SetParam(target: .strip(channel: pick(channels + [project.master.id]), param: param), value: level())
    default:
        return SetParam(target: .device(slot: pick(slots), index: Int.random(in: -1...3, using: &rng)),
                        value: Bool.random(using: &rng) ? level() : nil)
    }
}
