import Foundation
import Testing

@testable import DAWModel

// T-088: insert chains (MODEL-005 InsertDevice, RemoveDevice, RestoreDevice, MoveDevice; DW-149),
// automation lanes leaving with their target (DW-234), and the velocity-0 repair on open (DW-150).
// The project is GraphFixtures.routing():
//
//   Vox (eq, comp ← Kick sidechain) → Group (comp, bypassed) → Main (eq) → master (delay)
//   Vox post-send → Verb (reverb); Kick pre-send → Verb

private let auDelay = DeviceSlot.Kind.au(AUDescriptor(identifier: "aufx:dely:appl", name: "AUDelay"))
private let vstAgain = DeviceSlot.Kind.vst3(VST3Descriptor(identifier: "/x.vst3#00", name: "Again"))

@Suite("Insert chains (MODEL-005, DW-149)")
struct InsertChainCommandTests {
    init() { TestCommands.register() }

    let p = GraphFixtures.routing()
    var vox: Track { p.tracks[0] }
    var kick: Track { p.tracks[1] }
    var group: Bus { p.buses[0] }
    var main: Bus { p.buses[1] }
    var verb: Bus { p.buses[2] }
    var masterID: NodeIDValue { p.master.id }

    /// `p` with a MIDI track "Keys" holding a sampler.
    func withKeys() throws -> (project: Project, keys: NodeIDValue, sampler: NodeIDValue) {
        var q = p
        _ = try AddTrack(name: "Keys", kind: .midi).applyChecked(to: &q)
        let keys = try #require(q.tracks.last?.id)
        _ = try SetInstrument(trackID: keys, device: .builtin(.sampler)).applyChecked(to: &q)
        return (q, keys, try #require(q.tracks.last?.instrument?.id))
    }

    // MARK: MODEL-005 round trips (apply → JSON-decoded inverse → redo)

    @Test("MODEL-005: InsertDevice puts a new slot into a track's, bus's or the master's chain, at an index or at the end; the inverse removes it")
    func insertDevice() throws {
        let next = p.ids.next
        let first = try expectApplyRoundTrip(
            InsertDevice(channel: vox.id, index: 0, device: .builtin(.delay), params: [ParamValue(index: 0, value: 250)]), on: p)
        #expect(first.tracks[0].inserts.map(\.id) == [next] + vox.inserts.map(\.id))
        #expect(first.tracks[0].inserts[0] == DeviceSlot(id: next, kind: .builtin(.delay), params: [ParamValue(index: 0, value: 250)]))
        #expect(first.ids.next == next + 1)

        let middle = try expectApplyRoundTrip(InsertDevice(channel: vox.id, index: 1, device: .builtin(.gain)), on: p)
        #expect(middle.tracks[0].inserts.map(\.id) == [vox.inserts[0].id, next, vox.inserts[1].id])

        // nil index appends; a plugin comes with its state.
        let bus = try expectApplyRoundTrip(InsertDevice(channel: verb.id, device: auDelay, pluginState: Data([7, 8])), on: p)
        #expect(bus.buses[2].inserts.map(\.id) == verb.inserts.map(\.id) + [next])
        #expect(bus.buses[2].inserts.last == DeviceSlot(id: next, kind: auDelay, pluginState: Data([7, 8])))

        // DECISIONS "T-088 master": the master's ID addresses the master's chain.
        let master = try expectApplyRoundTrip(InsertDevice(channel: masterID, index: 0, device: vstAgain), on: p)
        #expect(master.master.inserts.map(\.id) == [next] + p.master.inserts.map(\.id))
        let appended = try expectApplyRoundTrip(InsertDevice(channel: masterID, device: .builtin(.eq)), on: p)
        #expect(appended.master.inserts.map(\.id) == p.master.inserts.map(\.id) + [next])

        // A sidechained insert: a compressor on Main listening to Kick (no cycle).
        let sc = SidechainRef(source: kick.id, tap: .postFader)
        let side = try expectApplyRoundTrip(InsertDevice(channel: main.id, device: .builtin(.compressor), sidechainSource: sc), on: p)
        #expect(side.buses[1].inserts.last?.sidechainSource == sc)
    }

    @Test("MODEL-005: RemoveDevice removes an insert from any channel; undo puts it back with ID, params, state, bypass and sidechain at its index")
    func removeDevice() throws {
        var q = p
        let comp = vox.inserts[1].id  // sidechained from Kick
        _ = try SetParam(target: .device(slot: comp, index: 2), value: 0.5).applyChecked(to: &q)
        _ = try SetDeviceBypass(slotID: comp, bypass: true).applyChecked(to: &q)
        #expect(try expectApplyRoundTrip(RemoveDevice(slotID: comp), on: q).tracks[0].inserts.map(\.id) == [vox.inserts[0].id])
        #expect(try expectApplyRoundTrip(RemoveDevice(slotID: vox.inserts[0].id), on: q).tracks[0].inserts.map(\.id) == [comp])
        #expect(try expectApplyRoundTrip(RemoveDevice(slotID: group.inserts[0].id), on: p).buses[0].inserts.isEmpty)
        #expect(try expectApplyRoundTrip(RemoveDevice(slotID: p.master.inserts[0].id), on: p).master.inserts.isEmpty)

        // A plugin on the master keeps its state through undo.
        var r = p
        _ = try InsertDevice(channel: masterID, index: 0, device: auDelay, pluginState: Data([1, 2, 3])).applyChecked(to: &r)
        let removed = try expectApplyRoundTrip(RemoveDevice(slotID: r.master.inserts[0].id), on: r)
        #expect(removed.master.inserts == p.master.inserts)
    }

    @Test("MODEL-005: RestoreDevice puts exactly the slot given at its index, with its ID; it inverts to RemoveDevice")
    func restoreDevice() throws {
        var q = p
        let slot = q.tracks[0].inserts.remove(at: 0)
        #expect(try expectApplyRoundTrip(RestoreDevice(channel: vox.id, index: 0, slot: slot), on: q) == p)
        let other = DeviceSlot(id: p.ids.next, kind: .builtin(.reverb), params: [ParamValue(index: 0, value: 0.3)], bypass: true,
                               sidechainSource: SidechainRef(source: vox.id))
        let onMaster = try expectApplyRoundTrip(RestoreDevice(channel: masterID, index: 1, slot: other), on: p)
        #expect(onMaster.master.inserts.last == other && onMaster.ids.next == other.id + 1)
    }

    @Test("MODEL-005: MoveDevice reorders a channel's chain (the master's too); the inverse moves it back")
    func moveDevice() throws {
        let moved = try expectApplyRoundTrip(MoveDevice(slotID: vox.inserts[0].id, index: 1), on: p)
        #expect(moved.tracks[0].inserts.map(\.id) == [vox.inserts[1].id, vox.inserts[0].id])
        var q = p
        for kind in [NodeKind.eq, .reverb] { _ = try InsertDevice(channel: masterID, device: .builtin(kind)).applyChecked(to: &q) }
        let ids = q.master.inserts.map(\.id)  // delay, eq, reverb
        #expect(try expectApplyRoundTrip(MoveDevice(slotID: ids[2], index: 0), on: q).master.inserts.map(\.id) == [ids[2], ids[0], ids[1]])
        #expect(try expectApplyRoundTrip(MoveDevice(slotID: ids[0], index: 2), on: q).master.inserts.map(\.id) == [ids[1], ids[2], ids[0]])
    }

    @Test("MODEL-005: undo and redo of insert edits keep slot IDs, so later history entries (params, moves) still apply")
    func redoKeepsSlotIDs() throws {
        var project = p
        var stack = UndoStack()
        try stack.perform(InsertDevice(channel: masterID, index: 0, device: .builtin(.eq)), on: &project)
        let slot = project.master.inserts[0].id
        try stack.perform(SetParam(target: .device(slot: slot, index: 1), value: 0.25), on: &project)
        try stack.perform(MoveDevice(slotID: slot, index: 1), on: &project)
        try stack.perform(RemoveDevice(slotID: slot), on: &project)
        try stack.perform(InsertDevice(channel: vox.id, device: .builtin(.reverb)), on: &project)
        let final = project
        while try stack.undo(&project) != nil {}
        #expect(project == p)
        while try stack.redo(&project) != nil {}
        #expect(project == final)
    }

    @Test("MODEL-006: insert commands' wire shapes")
    func wireShapes() throws {
        let json = #"{"type":"InsertDevice","channel":1,"device":{"format":"builtin","node":"eq"},"params":[{"index":0,"value":0.5}]}"#
        let insert = try #require(try CommandRegistry.decode(Data(json.utf8)) as? InsertDevice)
        #expect(insert.channel == 1 && insert.index == nil && insert.device == .builtin(.eq) && insert.params == [ParamValue(index: 0, value: 0.5)])
        func wire(_ command: any Command) throws -> String { String(decoding: try CommandRegistry.encode(command), as: UTF8.self) }
        #expect(try wire(InsertDevice(channel: 1, index: 2, device: .builtin(.delay)))
            == #"{"channel":1,"device":{"format":"builtin","node":"delay"},"index":2,"type":"InsertDevice"}"#)
        #expect(try wire(RemoveDevice(slotID: 4)) == #"{"slotID":4,"type":"RemoveDevice"}"#)
        #expect(try wire(MoveDevice(slotID: 4, index: 0)) == #"{"index":0,"slotID":4,"type":"MoveDevice"}"#)
        #expect(try wire(RestoreDevice(channel: 1, index: 0, slot: DeviceSlot(id: 4, kind: .builtin(.eq))))
            == #"{"channel":1,"index":0,"slot":{"bypass":false,"id":4,"kind":{"format":"builtin","node":"eq"},"params":[]},"type":"RestoreDevice"}"#)
    }

    // MARK: MODEL-031 bad arguments

    @Test("MODEL-031: unknown channels and slots, indices out of range, instruments where an insert is expected and bad slots throw and change nothing")
    func badArguments() throws {
        let (q, keys, sampler) = try withKeys()
        let missing: NodeIDValue = 999
        let next = q.ids.next
        let eq = vox.inserts[0].id
        let cases: [(any Command, DAWError)] = [
            (InsertDevice(channel: missing, device: .builtin(.eq)), .notFound(kind: "channel", id: missing)),
            (InsertDevice(channel: vox.sends[0].id, device: .builtin(.eq)), .notFound(kind: "channel", id: vox.sends[0].id)),
            (InsertDevice(channel: vox.id, index: 3, device: .builtin(.eq)), .invalidArgument("insert index 3 is outside 0…2")),
            (InsertDevice(channel: masterID, index: -1, device: .builtin(.eq)), .invalidArgument("insert index -1 is outside 0…1")),
            (InsertDevice(channel: keys, device: .builtin(.sampler)),
             .invalidArgument("the built-in sampler is an instrument, not an insert (use SetInstrument)")),
            (InsertDevice(channel: vox.id, device: .builtin(.channelStrip)), .invalidArgument("built-in channelStrip is not an insert effect")),
            (InsertDevice(channel: vox.id, device: .builtin(.audioClipPlayer)), .invalidArgument("built-in audioClipPlayer is not an insert effect")),
            (InsertDevice(channel: vox.id, device: .builtin(.master)), .invalidArgument("built-in master is not an insert effect")),
            (InsertDevice(channel: vox.id, device: .builtin(.eq), pluginState: Data([1])),
             .invalidArgument("pluginState is for AU and VST3 devices, not built-ins")),
            (InsertDevice(channel: vox.id, device: .builtin(.eq), params: [ParamValue(index: 1, value: 0), ParamValue(index: 1, value: 1)]),
             .brokenInvariant("device slot \(next) has a bad or repeated param index 1")),
            (InsertDevice(channel: vox.id, device: .builtin(.eq), params: [ParamValue(index: 0, value: .nan)]),
             .brokenInvariant("device slot \(next) param 0 is not finite")),
            (InsertDevice(channel: vox.id, device: .builtin(.eq), params: [ParamValue(index: 4096, value: 0)]),
             .brokenInvariant("device slot \(next) has a bad or repeated param index 4096")),
            (InsertDevice(channel: vox.id, device: .builtin(.compressor), sidechainSource: SidechainRef(source: missing)),
             .notFound(kind: "track or bus", id: missing)),
            (InsertDevice(channel: vox.id, device: .builtin(.compressor), sidechainSource: SidechainRef(source: masterID)),
             .notFound(kind: "track or bus", id: masterID)),

            (RemoveDevice(slotID: missing), .notFound(kind: "device slot", id: missing)),
            (RemoveDevice(slotID: vox.id), .notFound(kind: "device slot", id: vox.id)),
            (RemoveDevice(slotID: sampler),
             .invalidArgument("device slot \(sampler) is an instrument, not an insert (use RemoveInstrument or SetInstrument)")),

            (MoveDevice(slotID: missing, index: 0), .notFound(kind: "device slot", id: missing)),
            (MoveDevice(slotID: sampler, index: 0),
             .invalidArgument("device slot \(sampler) is an instrument, not an insert (use RemoveInstrument or SetInstrument)")),
            (MoveDevice(slotID: eq, index: 2), .invalidArgument("insert index 2 is outside 0…1")),
            (MoveDevice(slotID: eq, index: -1), .invalidArgument("insert index -1 is outside 0…1")),
            (MoveDevice(slotID: p.master.inserts[0].id, index: 1), .invalidArgument("insert index 1 is outside 0…0")),

            (RestoreDevice(channel: missing, index: 0, slot: DeviceSlot(id: 900, kind: .builtin(.eq))), .notFound(kind: "channel", id: missing)),
            (RestoreDevice(channel: vox.id, index: 3, slot: DeviceSlot(id: 900, kind: .builtin(.eq))),
             .invalidArgument("insert index 3 is outside 0…2")),
            (RestoreDevice(channel: vox.id, index: 0, slot: DeviceSlot(id: eq, kind: .builtin(.eq))),
             .invalidArgument("device slot id \(eq) is already in use")),
            (RestoreDevice(channel: vox.id, index: 0, slot: DeviceSlot(id: 0, kind: .builtin(.eq))),
             .invalidArgument("device slot id 0 is outside 1…\(GraphNodeID.maxModelID)")),
            (RestoreDevice(channel: vox.id, index: 0, slot: DeviceSlot(id: 900, kind: .builtin(.eq), zones: [SamplerZone(assetID: 1)])),
             .brokenInvariant("device slot 900 has zones but is no sampler")),
            (RestoreDevice(channel: vox.id, index: 0, slot: DeviceSlot(id: 900, kind: .builtin(.eq), sidechainSource: SidechainRef(source: vox.id))),
             .routingCycle(path: [vox.id, vox.id])),
        ]
        for (command, error) in cases {
            var r = q
            #expect(throws: error, "\(type(of: command).type)") { _ = try command.applyChecked(to: &r) }
            #expect(r == q && r.ids.next == q.ids.next)
        }
    }

    // MARK: MODEL-030

    @Test("MODEL-030: an inserted (or restored) device's sidechain can't close a cycle; the error carries the path")
    func sidechainCycles() throws {
        func rejected(_ command: any Command, _ path: [NodeIDValue]) {
            var q = p
            #expect(throws: DAWError.routingCycle(path: path)) { _ = try command.applyChecked(to: &q) }
            #expect(q == p)
        }
        // Vox's own signal into its insert.
        rejected(InsertDevice(channel: vox.id, device: .builtin(.compressor), sidechainSource: SidechainRef(source: vox.id)), [vox.id, vox.id])
        // Kick already feeds Vox (Vox's compressor listens to it): Vox can't feed a Kick insert.
        rejected(InsertDevice(channel: kick.id, device: .builtin(.compressor), sidechainSource: SidechainRef(source: vox.id)),
                 [vox.id, kick.id, vox.id])
        // Group → Main: Main can't feed a Group insert, a plugin's included.
        rejected(InsertDevice(channel: group.id, index: 0, device: auDelay, sidechainSource: SidechainRef(source: main.id)),
                 [main.id, group.id, main.id])
        rejected(RestoreDevice(channel: group.id, index: 0, slot: DeviceSlot(id: 900, kind: .builtin(.compressor),
                                                                              sidechainSource: SidechainRef(source: main.id))),
                 [main.id, group.id, main.id])
        // The master is the sink: any track or bus may feed a master insert's sidechain.
        var q = p
        _ = try InsertDevice(channel: masterID, device: .builtin(.compressor), sidechainSource: SidechainRef(source: group.id)).applyChecked(to: &q)
        try q.validate()
    }

    // MARK: MODEL-020: the graph

    @Test("MODEL-020: GraphDescriptionBuilder emits a chain in order after inserts and moves; a master insert sits before the master strip")
    func graphOrder() throws {
        var q = p
        _ = try InsertDevice(channel: vox.id, index: 0, device: .builtin(.delay)).applyChecked(to: &q)
        let voxDelay = q.tracks[0].inserts[0].id
        _ = try InsertDevice(channel: masterID, device: .builtin(.reverb)).applyChecked(to: &q)
        let masterVerb = q.master.inserts[1].id
        _ = try InsertDevice(channel: masterID, index: 0, device: vstAgain).applyChecked(to: &q)
        let masterVST = q.master.inserts[0].id

        func chain(_ project: Project, from start: NodeIDValue) -> [NodeIDValue] {
            let graph = GraphDescriptionBuilder.build(project, runtime: RuntimeIDs.sequential(for: project))
            var out = [start]
            while let next = graph.edges.first(where: { $0.from == out.last! && $0.kind == .audio && $0.toPort == 0 }), out.count < 20 {
                out.append(next.to)
            }
            return out
        }
        let source = GraphNodeID.source(of: vox.id)
        #expect(chain(q, from: source).prefix(5) == [source, voxDelay, vox.inserts[0].id, vox.inserts[1].id, vox.id])
        let input = GraphNodeID.input(of: masterID)
        let tail = [masterID, GraphNodeID.output(of: masterID)]
        #expect(chain(q, from: input) == [input, masterVST, p.master.inserts[0].id, masterVerb] + tail)

        _ = try MoveDevice(slotID: masterVST, index: 2).applyChecked(to: &q)
        _ = try MoveDevice(slotID: voxDelay, index: 2).applyChecked(to: &q)
        #expect(chain(q, from: input) == [input, p.master.inserts[0].id, masterVerb, masterVST] + tail)
        #expect(chain(q, from: source).prefix(5) == [source, vox.inserts[0].id, vox.inserts[1].id, voxDelay, vox.id])

        _ = try RemoveDevice(slotID: masterVerb).applyChecked(to: &q)
        #expect(chain(q, from: input) == [input, p.master.inserts[0].id, masterVST] + tail)
        let graph = GraphDescriptionBuilder.build(q, runtime: RuntimeIDs.sequential(for: q))
        #expect(graph.nodes.contains { $0.id == masterVST && $0.kind == .vst3Plugin })
        #expect(!graph.nodes.contains { $0.id == masterVerb })
    }
}

// MARK: - DW-234: lanes leave with their target

@Suite("Lanes leave with their send or device (DW-234)")
struct AutomationCascadeTests {
    init() { TestCommands.register() }

    let p = GraphFixtures.routing()
    var vox: Track { p.tracks[0] }
    var kick: Track { p.tracks[1] }
    var verb: Bus { p.buses[2] }
    var voxGain: ParamTarget { .strip(channel: vox.id, param: .gain) }

    /// Lanes with two points each and alternating non-default modes, so a restore must bring back
    /// points and mode.
    func withLanes(_ targets: [ParamTarget], on project: Project) throws -> Project {
        var q = project
        for (i, target) in targets.enumerated() {
            _ = try AddAutomationPoints(target: target, points: [
                AutomationPoint(tick: 0, value: 0.25), AutomationPoint(tick: 960, value: 0.75, curve: .hold),
            ]).applyChecked(to: &q)
            _ = try SetAutomationMode(target: target, mode: i.isMultiple(of: 2) ? .latch : .off).applyChecked(to: &q)
        }
        return q
    }

    func targets(_ project: Project) -> Set<ParamTarget> {
        var out = Set<ParamTarget>()
        project.forEachAutomationLane { lane, _ in out.insert(lane.target) }
        return out
    }

    /// One undo entry: undo restores the project (lanes with points and mode), redo removes again.
    func expectOneUndoStep(_ command: any Command, on project: Project, sourceLocation: SourceLocation = #_sourceLocation) throws {
        var q = project
        var stack = UndoStack()
        try stack.perform(command, on: &q)
        let applied = q
        #expect(try stack.undo(&q) != nil, sourceLocation: sourceLocation)
        #expect(q == project, sourceLocation: sourceLocation)
        #expect(!stack.canUndo, "one undo entry", sourceLocation: sourceLocation)
        _ = try stack.redo(&q)
        #expect(q == applied, sourceLocation: sourceLocation)
    }

    @Test("DW-234: RemoveSend removes the send's level lane in the same step; undo restores both")
    func removeSend() throws {
        let send = ParamTarget.sendLevel(send: vox.sends[0].id)
        let q = try withLanes([send, voxGain, .sendLevel(send: kick.sends[0].id)], on: p)
        let removed = try expectApplyRoundTrip(RemoveSend(sendID: vox.sends[0].id), on: q)
        #expect(targets(removed) == [voxGain, .sendLevel(send: kick.sends[0].id)])
        try expectOneUndoStep(RemoveSend(sendID: vox.sends[0].id), on: q)
    }

    @Test("DW-234: RemoveDevice removes every lane driving the slot (track, bus and master inserts); other lanes stay")
    func removeDevice() throws {
        let comp = vox.inserts[1].id, eq = vox.inserts[0].id, delay = p.master.inserts[0].id, rev = verb.inserts[0].id
        let q = try withLanes([.device(slot: comp, index: 0), .device(slot: comp, index: 2), .device(slot: eq, index: 1),
                               .device(slot: delay, index: 3), .device(slot: rev, index: 0)], on: p)
        let removed = try expectApplyRoundTrip(RemoveDevice(slotID: comp), on: q)
        #expect(targets(removed) == [.device(slot: eq, index: 1), .device(slot: delay, index: 3), .device(slot: rev, index: 0)])
        try expectOneUndoStep(RemoveDevice(slotID: comp), on: q)
        #expect(!targets(try expectApplyRoundTrip(RemoveDevice(slotID: delay), on: q)).contains(.device(slot: delay, index: 3)))
        #expect(!targets(try expectApplyRoundTrip(RemoveDevice(slotID: rev), on: q)).contains(.device(slot: rev, index: 0)))
    }

    @Test("DW-234: RemoveInstrument and SetInstrument (replacing) remove the old instrument's lanes; undo restores them")
    func instrument() throws {
        var k = p
        _ = try AddTrack(name: "Keys", kind: .midi).applyChecked(to: &k)
        let keys = k.tracks[2].id
        _ = try SetInstrument(trackID: keys, device: .builtin(.sampler)).applyChecked(to: &k)
        let sampler = try #require(k.tracks[2].instrument?.id)
        let q = try withLanes([.device(slot: sampler, index: 0), .device(slot: sampler, index: 1), voxGain], on: k)

        #expect(targets(try expectApplyRoundTrip(RemoveInstrument(trackID: keys), on: q)) == [voxGain])
        try expectOneUndoStep(RemoveInstrument(trackID: keys), on: q)
        let replaced = try expectApplyRoundTrip(SetInstrument(trackID: keys, device: vstAgain), on: q)
        #expect(targets(replaced) == [voxGain])
        try expectOneUndoStep(SetInstrument(trackID: keys, device: vstAgain), on: q)

        // RestoreInstrument over a slot with lanes takes them; over itself it keeps them.
        let other = DeviceSlot(id: q.ids.next, kind: auDelay)
        #expect(targets(try expectApplyRoundTrip(RestoreInstrument(trackID: keys, instrument: other), on: q)) == [voxGain])
        #expect(targets(try expectApplyRoundTrip(RestoreInstrument(trackID: keys, instrument: nil), on: q)) == [voxGain])
        var bypassed = try #require(q.tracks[2].instrument)
        bypassed.bypass = true
        #expect(targets(try expectApplyRoundTrip(RestoreInstrument(trackID: keys, instrument: bypassed), on: q)) == targets(q))
    }

    @Test("DW-234: RemoveBus also removes the lanes of the sends into it (the bus's own lanes leave with it); undo restores all")
    func removeBus() throws {
        let voxSend = ParamTarget.sendLevel(send: vox.sends[0].id), kickSend = ParamTarget.sendLevel(send: kick.sends[0].id)
        let q = try withLanes([voxSend, kickSend, .device(slot: verb.inserts[0].id, index: 1),
                               .strip(channel: verb.id, param: .pan), voxGain], on: p)
        let removed = try expectApplyRoundTrip(RemoveBus(busID: verb.id), on: q)
        #expect(targets(removed) == [voxGain])
        try expectOneUndoStep(RemoveBus(busID: verb.id), on: q)
    }

    @Test("DW-234: through ProjectStore, a removal and its lanes are one undo entry and the applied graph drops the lanes")
    @MainActor
    func storeAndGraph() async throws {
        let comp = vox.inserts[1].id
        let q = try withLanes([.device(slot: comp, index: 0), voxGain], on: p)
        let store = ProjectStore(project: q)
        let engine = FakeEngine()
        let sync = try store.attachEngine(engine, debounce: .milliseconds(1))
        sync.flush()
        let before = try #require(sync.appliedGraph?.automation.count)
        try store.perform(RemoveDevice(slotID: comp))
        sync.flush()
        #expect(sync.appliedGraph?.automation.count == before - 1, "the device's lane left the graph with the lane")
        #expect(store.undoLabel == "Remove Device")
        #expect(targets(store.project) == [voxGain])
        store.undo()
        sync.flush()
        #expect(store.project == q && !store.canUndo)
        store.redo()
        #expect(targets(store.project) == [voxGain])
    }

    @Test("DW-234: lanes whose target was already gone (files from before T-088) stay valid, stay out of the graph, and survive undo of a restore")
    func orphanLanes() throws {
        // Removing the send directly leaves its lane behind, as removals did before T-088.
        var q = try withLanes([.sendLevel(send: vox.sends[0].id), .device(slot: vox.inserts[0].id, index: 1)], on: p)
        let send = q.tracks[0].sends.remove(at: 0)
        let eq = q.tracks[0].inserts.remove(at: 0)
        try q.validate()
        let graph = GraphDescriptionBuilder.build(q, runtime: RuntimeIDs.sequential(for: q))
        #expect(graph.automation.isEmpty)

        // Bringing the target back adopts the lane; undoing that leaves the project exactly as it was.
        let sendBack = try expectApplyRoundTrip(RestoreSend(channelID: vox.id, send: send, index: 0), on: q)
        #expect(targets(sendBack) == targets(q))
        let eqBack = try expectApplyRoundTrip(RestoreDevice(channel: vox.id, index: 0, slot: eq), on: q)
        #expect(targets(eqBack) == targets(q))
        try expectOneUndoStep(RestoreSend(channelID: vox.id, send: send, index: 0), on: q)
        try expectOneUndoStep(RestoreDevice(channel: vox.id, index: 0, slot: eq), on: q)
    }
}

// MARK: - DW-150: velocity 0 is repaired on open

@Suite("Velocity-0 repair on open (DW-150)")
@MainActor
struct VelocityRepairTests {
    @Test("DW-150: a project.json with velocity-0 notes opens with them set to 1 and reported; other broken invariants still fail")
    func velocityZeroRepaired() async throws {
        let temp = try TempFolder("velocity")
        defer { temp.remove() }
        let folder = temp.url.appending(path: "V.dawproject")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = GraphFixtures.fixturesDir.appending(path: "projects/velocity_zero.json")
        try FileManager.default.copyItem(at: fixture, to: folder.appending(path: "project.json"))

        let store = try await ProjectStore.open(folder, recover: false)
        store.autosavePolicy = nil
        // The fixture is midi_tempo with notes 7 (velocity 80) and 11 (velocity 100) at 0.
        var expected = try GraphFixtures.project(named: "midi_tempo")
        for t in expected.tracks.indices {
            for c in expected.tracks[t].clips.indices {
                guard case .midi(var clip) = expected.tracks[t].clips[c] else { continue }
                for n in clip.notes.indices where [7, 11].contains(clip.notes[n].id) { clip.notes[n].velocity = 1 }
                expected.tracks[t].clips[c] = .midi(clip)
            }
        }
        #expect(store.project == expected)
        #expect(store.loadReport.repairs == ["set the velocity of note 7 from 0 to 1 (DW-150)",
                                             "set the velocity of note 11 from 0 to 1 (DW-150)"])

        // Validation stays strict otherwise: a pitch out of range is still invalidProject.
        var json = try String(contentsOf: fixture, encoding: .utf8)
        json = json.replacingOccurrences(of: "\"pitch\" : 40", with: "\"pitch\" : 128")
        try Data(json.utf8).write(to: folder.appending(path: "project.json"))
        do {
            _ = try await ProjectStore.open(folder, recover: false)
            Issue.record("expected invalidProject")
        } catch {
            guard case .invalidProject = error else { Issue.record("got \(error)"); return }
        }
    }
}
