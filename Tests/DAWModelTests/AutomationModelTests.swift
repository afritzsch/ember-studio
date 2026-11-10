import Foundation
import Testing

@testable import DAWModel

// T-074 (11): automation lanes in the model. MODEL-005/006 round trips for the AUTO commands,
// MODEL-031/032 checks, AUTO-001/005/008 graph emission and engine sync. The project is
// GraphFixtures.routing():
//
//   Vox (eq, comp) → Group → Main → master; Vox post-send → Verb; Kick pre-send → Verb

@Suite("Automation model (AUTO, T-074)")
@MainActor
struct AutomationModelTests {
    init() { TestCommands.register() }

    let p = GraphFixtures.routing()
    var vox: Track { p.tracks[0] }
    var kick: Track { p.tracks[1] }
    var gain: ParamTarget { .strip(channel: vox.id, param: .gain) }
    var voxEQ: ParamTarget { .device(slot: vox.inserts[0].id, index: 1) }

    func lanes(_ project: Project) -> [AutomationLane] {
        var out: [AutomationLane] = []
        project.forEachAutomationLane { lane, _ in out.append(lane) }
        return out
    }

    func withLane(_ target: ParamTarget, _ points: [AutomationPoint]) throws -> Project {
        var q = p
        _ = try AddAutomationPoints(target: target, points: points).applyChecked(to: &q)
        return q
    }

    // MARK: MODEL-005 round trips

    @Test("MODEL-005: AddAutomationPoints creates the lane (read) on the target's channel, sorted; the inverse removes it")
    func addCreatesLane() throws {
        let next = p.ids.next
        let added = try expectApplyRoundTrip(
            AddAutomationPoints(target: gain, points: [
                AutomationPoint(tick: 960, value: 1, curve: .exp(2)), AutomationPoint(tick: 0, value: 0),
            ]), on: p)
        let lane = try #require(added.track(vox.id)?.automation.first)
        #expect(lane == AutomationLane(id: next, target: gain, points: [
            AutomationPoint(tick: 0, value: 0), AutomationPoint(tick: 960, value: 1, curve: .exp(2)),
        ], mode: .read))
        #expect(lanes(added).count == 1)

        // A send's lane lives on the send's channel, a device's on the slot's channel.
        let send = try expectApplyRoundTrip(
            AddAutomationPoint(target: .sendLevel(send: kick.sends[0].id), point: AutomationPoint(tick: 0, value: 0.5)), on: p)
        #expect(send.track(kick.id)?.automation.count == 1)
        let device = try expectApplyRoundTrip(
            AddAutomationPoint(target: .device(slot: p.master.inserts[0].id, index: 6), point: AutomationPoint(tick: 0, value: 0.5)),
            on: p)
        #expect(device.master.automation.count == 1)
    }

    @Test("MODEL-005: AddAutomationPoints adds to an existing lane; the inverse restores it exactly")
    func addToExisting() throws {
        let q = try withLane(gain, [AutomationPoint(tick: 0, value: 0)])
        let added = try expectApplyRoundTrip(AddAutomationPoint(target: gain, point: AutomationPoint(tick: 480, value: 0.5, curve: .hold)), on: q)
        #expect(added.track(vox.id)?.automation[0].points.map(\.tick) == [0, 480])
        #expect(added.ids.next == q.ids.next, "no new lane")
    }

    @Test("MODEL-005: RemoveAutomationPoints removes points and keeps the (maybe empty) lane")
    func remove() throws {
        let q = try withLane(gain, [AutomationPoint(tick: 0, value: 0), AutomationPoint(tick: 960, value: 1)])
        let one = try expectApplyRoundTrip(RemoveAutomationPoints(target: gain, ticks: [960]), on: q)
        #expect(one.track(vox.id)?.automation[0].points == [AutomationPoint(tick: 0, value: 0)])
        let all = try expectApplyRoundTrip(RemoveAutomationPoints(target: gain, ticks: [0, 960]), on: q)
        #expect(all.track(vox.id)?.automation[0].points == [])
    }

    @Test("MODEL-005: MoveAutomationPoints moves points in time and value together, re-sorted")
    func move() throws {
        let q = try withLane(gain, [AutomationPoint(tick: 0, value: 0), AutomationPoint(tick: 960, value: 0.5)])
        let moved = try expectApplyRoundTrip(MoveAutomationPoints(target: gain, ticks: [0], deltaTicks: 1920, deltaValue: 0.25), on: q)
        #expect(moved.track(vox.id)?.automation[0].points ==
                [AutomationPoint(tick: 960, value: 0.5), AutomationPoint(tick: 1920, value: 0.25)])
        let both = try expectApplyRoundTrip(MoveAutomationPoints(target: gain, ticks: [0, 960], deltaTicks: 10, deltaValue: 0.5), on: q)
        #expect(both.track(vox.id)?.automation[0].points.map(\.value) == [0.5, 1])
    }

    @Test("MODEL-005, AUTO-005: SetAutomationMode sets the mode, creating an empty lane if needed")
    func mode() throws {
        let created = try expectApplyRoundTrip(SetAutomationMode(target: gain, mode: .off), on: p)
        #expect(created.track(vox.id)?.automation.first?.mode == .off)
        #expect(created.track(vox.id)?.automation.first?.points == [])
        let q = try withLane(gain, [AutomationPoint(tick: 0, value: 0)])
        let latched = try expectApplyRoundTrip(SetAutomationMode(target: gain, mode: .latch), on: q)
        #expect(latched.track(vox.id)?.automation.first?.mode == .latch)
    }

    @Test("MODEL-005: SetAutomationLane puts a lane back with its ID, in ID order, and inverts to itself")
    func setLane() throws {
        let q = try withLane(gain, [AutomationPoint(tick: 0, value: 0)])
        var r = try withLane(voxEQ, [AutomationPoint(tick: 0, value: 1)])
        _ = try AddAutomationPoint(target: gain, point: AutomationPoint(tick: 0, value: 0)).applyChecked(to: &r)
        let lane = try #require(q.track(vox.id)?.automation.first)
        let removed = try expectApplyRoundTrip(SetAutomationLane(channel: vox.id, target: gain, lane: nil), on: q)
        #expect(removed.track(vox.id)?.automation == [])
        // Lanes on one channel stay sorted by ID however they are put back.
        let ids = r.track(vox.id)?.automation.map(\.id) ?? []
        #expect(ids == ids.sorted() && ids.count == 2)
        var back = removed
        _ = try SetAutomationLane(channel: vox.id, target: gain, lane: lane).applyChecked(to: &back)
        #expect(back == q)
    }

    @Test("MODEL-006: every AUTO command survives a JSON round trip; points encode tick, value, curve, shape")
    func json() throws {
        let commands: [any Command] = [
            AddAutomationPoints(target: gain, points: [AutomationPoint(tick: 0, value: 0.25, curve: .exp(-3))]),
            AddAutomationPoint(target: voxEQ, point: AutomationPoint(tick: 10, value: 1, curve: .hold)),
            RemoveAutomationPoints(target: gain, ticks: [0, 10]),
            MoveAutomationPoints(target: gain, ticks: [5], deltaTicks: -5, deltaValue: 0.1),
            SetAutomationMode(target: gain, mode: .touch),
            SetAutomationLane(channel: vox.id, target: gain, lane: AutomationLane(id: 9, target: gain)),
        ]
        for command in commands {
            let data = try CommandRegistry.encode(command)
            let decoded = try CommandRegistry.decode(data)
            #expect(try CommandRegistry.encode(decoded) == data)
        }
        let point = String(decoding: try JSONEncoder.sorted.encode(AutomationPoint(tick: 960, value: 0.5, curve: .exp(2))), as: UTF8.self)
        #expect(point == #"{"curve":"exp","shape":2,"tick":960,"value":0.5}"#)
        let linear = try JSONDecoder().decode(AutomationPoint.self, from: Data(#"{"tick": 3, "value": 1}"#.utf8))
        #expect(linear == AutomationPoint(tick: 3, value: 1))
        let lane = try JSONDecoder().decode(AutomationLane.self, from: Data(#"{"id": 4, "target": {"kind": "sendLevel", "send": 9}}"#.utf8))
        #expect(lane == AutomationLane(id: 4, target: .sendLevel(send: 9), points: [], mode: .read))
    }

    // MARK: MODEL-031 / MODEL-032

    @Test("MODEL-031: bad automation edits throw and change nothing")
    func rejects() throws {
        let q = try withLane(gain, [AutomationPoint(tick: 0, value: 0), AutomationPoint(tick: 960, value: 1)])
        let bad: [any Command] = [
            AddAutomationPoints(target: gain, points: []),
            AddAutomationPoint(target: gain, point: AutomationPoint(tick: 0, value: 0.5)),             // tick taken
            AddAutomationPoints(target: gain, points: [AutomationPoint(tick: 5, value: 0), AutomationPoint(tick: 5, value: 1)]),
            AddAutomationPoint(target: gain, point: AutomationPoint(tick: 7, value: 1.5)),             // value > 1
            AddAutomationPoint(target: gain, point: AutomationPoint(tick: -1, value: 0)),              // off the timeline
            AddAutomationPoint(target: gain, point: AutomationPoint(tick: 7, value: .nan)),
            AddAutomationPoint(target: gain, point: AutomationPoint(tick: 7, value: 0, curve: .exp(51))),
            AddAutomationPoint(target: .strip(channel: vox.id, param: .solo), point: AutomationPoint(tick: 0, value: 1)),
            AddAutomationPoint(target: .strip(channel: vox.id, param: .phase), point: AutomationPoint(tick: 0, value: 1)),
            AddAutomationPoint(target: .strip(channel: 999, param: .gain), point: AutomationPoint(tick: 0, value: 1)),
            AddAutomationPoint(target: .sendLevel(send: 999), point: AutomationPoint(tick: 0, value: 1)),
            AddAutomationPoint(target: .device(slot: vox.inserts[0].id, index: 5000), point: AutomationPoint(tick: 0, value: 1)),
            RemoveAutomationPoints(target: gain, ticks: [480]),
            RemoveAutomationPoints(target: gain, ticks: [0, 0]),
            RemoveAutomationPoints(target: voxEQ, ticks: [0]),                                          // no lane
            MoveAutomationPoints(target: gain, ticks: [0], deltaTicks: 960),                           // collides
            MoveAutomationPoints(target: gain, ticks: [960], deltaValue: 0.5),                          // value > 1
            MoveAutomationPoints(target: gain, ticks: [0], deltaTicks: -1),                             // before 0
            SetAutomationMode(target: .strip(channel: 999, param: .pan), mode: .read),
            SetAutomationLane(channel: vox.id, target: gain, lane: AutomationLane(id: kick.id, target: gain)),  // ID in use
            SetAutomationLane(channel: vox.id, target: gain, lane: AutomationLane(id: q.ids.next, target: voxEQ)),
            SetAutomationLane(channel: 999, target: gain, lane: nil),
        ]
        for command in bad {
            var r = q
            #expect(throws: DAWError.self, "\(type(of: command).type)") { _ = try command.applyChecked(to: &r) }
            #expect(r == q)
        }
    }

    @Test("MODEL-032: validate() checks lanes: point order and range, ID order, one lane per target, automatable targets")
    func validation() throws {
        let q = try withLane(gain, [AutomationPoint(tick: 0, value: 0), AutomationPoint(tick: 960, value: 1)])
        try q.validate()
        func broken(_ edit: (inout Project) -> Void) -> Bool {
            var r = q
            edit(&r)
            return (try? r.validate()) == nil
        }
        #expect(broken { $0.tracks[0].automation[0].points.reverse() })
        #expect(broken { $0.tracks[0].automation[0].points[1].value = 2 })
        #expect(broken { $0.tracks[0].automation[0].target = .strip(channel: $0.tracks[0].id, param: .solo) })
        #expect(broken { r in r.tracks[1].automation = [AutomationLane(id: r.ids.allocate(), target: r.tracks[0].automation[0].target)] })
        #expect(broken { r in
            let lane = AutomationLane(id: r.ids.allocate(), target: .device(slot: r.tracks[0].inserts[0].id, index: 0))
            r.tracks[0].automation.insert(lane, at: 0)  // the newer ID first
        })
        // A lane whose target is gone (send removed) stays valid and is left out of the graph.
        var r = try withLane(.sendLevel(send: vox.sends[0].id), [AutomationPoint(tick: 0, value: 1)])
        _ = try RemoveSend(sendID: vox.sends[0].id).applyChecked(to: &r)
        try r.validate()
        #expect(GraphDescriptionBuilder.build(r, runtime: RuntimeIDs.sequential(for: r)).automation == [])
    }

    @Test("T-074: tracks decode with no `automation` key (default none)")
    func decodeDefault() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(vox)) as! [String: Any]
        json.removeValue(forKey: "automation")
        let track = try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(track.automation == [])
    }

    // MARK: AUTO-001/005/008: graph emission

    @Test("AUTO-001, AUTO-008: lanes go into the graph on their slots; off lanes disabled; empty lanes left out")
    func emission() throws {
        var q = try withLane(gain, [AutomationPoint(tick: 0, value: 0), AutomationPoint(tick: 960, value: 1, curve: .exp(3))])
        _ = try AddAutomationPoint(target: voxEQ, point: AutomationPoint(tick: 0, value: 0.5, curve: .hold)).applyChecked(to: &q)
        _ = try AddAutomationPoint(target: .sendLevel(send: vox.sends[0].id), point: AutomationPoint(tick: 0, value: 0.5))
            .applyChecked(to: &q)
        _ = try SetAutomationMode(target: voxEQ, mode: .off).applyChecked(to: &q)
        _ = try SetAutomationMode(target: .strip(channel: kick.id, param: .pan), mode: .read).applyChecked(to: &q)  // empty
        let runtime = RuntimeIDs.sequential(for: q)
        let graph = GraphDescriptionBuilder.build(q, runtime: runtime)
        let laneIDs = q.track(vox.id)!.automation.map(\.id)
        let gainLane = EngineGraph.Automation(
            laneID: laneIDs[0], target: runtime.stripParam(vox.id, ParamLayout.Strip.gain)!,
            points: [.init(tick: 0, value: 0), .init(tick: 960, value: 1, curve: 2, shape: 3)])
        let eqLane = EngineGraph.Automation(
            laneID: laneIDs[1], target: runtime.deviceParam(vox.inserts[0].id, 1)!,
            points: [.init(tick: 0, value: 0.5, curve: 1)], enabled: false)
        let sendLane = EngineGraph.Automation(
            laneID: laneIDs[2], target: runtime.sendLevelParam(vox.sends[0].id)!, points: [.init(tick: 0, value: 0.5)])
        #expect(graph.automation == [gainLane, eqLane, sendLane])
    }

    @Test("AUTO-008, MIX-006/007: a mute lane drives the strip's and every send's mute slot; solo-muted channels disable it")
    func muteLane() throws {
        let mute = ParamTarget.strip(channel: vox.id, param: .mute)
        var q = try withLane(mute, [AutomationPoint(tick: 0, value: 1)])
        var runtime = RuntimeIDs.sequential(for: q)
        var graph = GraphDescriptionBuilder.build(q, runtime: runtime)
        #expect(graph.automation.map { (lane: EngineGraph.Automation) in lane.target } ==
                [runtime.stripParam(vox.id, ParamLayout.Strip.mute)!, runtime.sendMuteParam(vox.sends[0].id)!])
        #expect(graph.automation.allSatisfy { (lane: EngineGraph.Automation) in lane.enabled })
        // Kick soloed: Vox is muted by solo, so its mute lane steps aside.
        _ = try SetParam(target: .strip(channel: kick.id, param: .solo), value: 1).applyChecked(to: &q)
        runtime = RuntimeIDs.sequential(for: q)
        graph = GraphDescriptionBuilder.build(q, runtime: runtime)
        #expect(graph.automation.count == 2 && graph.automation.allSatisfy { (lane: EngineGraph.Automation) in !lane.enabled })
    }

    @Test("AUTO-009, PLUG-015: a lane on a plugin param gives the slot a param slot for it")
    func pluginSlots() throws {
        var q = p
        let slot = q.ids.allocate()
        q.tracks[1].inserts = [DeviceSlot(id: slot, kind: .vst3(VST3Descriptor(identifier: "/x.vst3#ABC", name: "X")))]
        #expect(GraphDescriptionBuilder.paramRequirements(q, catalog: ParamCatalog())[slot] == nil)
        _ = try AddAutomationPoint(target: .device(slot: slot, index: 3), point: AutomationPoint(tick: 0, value: 1))
            .applyChecked(to: &q)
        #expect(GraphDescriptionBuilder.paramRequirements(q, catalog: ParamCatalog())[slot] == 4)
    }

    @Test("MODEL-021: an automation edit applies a graph; SetParam on an automated param still doesn't")
    func engineSync() async throws {
        let store = ProjectStore(project: p)
        let engine = FakeEngine()
        let sync = try store.attachEngine(engine, debounce: .zero)
        let applies = { engine.calls.filter { if case .applyGraph = $0 { true } else { false } }.count }
        let before = applies()
        try store.perform(AddAutomationPoints(target: gain, points: [AutomationPoint(tick: 0, value: 0), AutomationPoint(tick: 960, value: 1)]))
        try await Task.sleep(for: .milliseconds(40))
        #expect(applies() == before + 1)
        #expect(engine.appliedGraphs.last?.automation.count == 1)
        #expect(sync.appliedGraph?.automation.first?.target == sync.runtime.stripParam(vox.id, ParamLayout.Strip.gain))
        let after = applies()
        try store.perform(SetParam(target: gain, value: 0.5))
        try await Task.sleep(for: .milliseconds(40))
        #expect(applies() == after)
        store.undo()
        store.undo()
        try await Task.sleep(for: .milliseconds(40))
        #expect(engine.appliedGraphs.last?.automation == [])
        #expect(store.project == p)
    }

    @Test("BRIDGE-003: automation lanes cross the C++ GraphDescriptionBuilder field by field")
    func bridge() throws {
        var g = EngineGraph()
        g.automation = [
            .init(laneID: 5, target: 17, points: [.init(tick: 0, value: 0), .init(tick: 960, value: 1, curve: 2, shape: -4)]),
            .init(laneID: 6, target: 18, points: [.init(tick: 3, value: 0.5, curve: 1)], enabled: false),
        ]
        #expect(EngineClient.roundTrip(g) == g)
    }
}

extension JSONEncoder {
    fileprivate static var sorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
