import AVFoundation
import Foundation
import Testing

@testable import DAWModel

// T-075 (11): automation recording (AUTO-006), stopped edits (AUTO-007, DW-237) and automatable
// params (DW-236). The project is GraphFixtures.routing() (Vox with eq + comp, Kick, sends).

@Suite("Automation recording (AUTO-006/007, T-075)")
@MainActor
struct AutomationRecordingTests {
    init() { TestCommands.register() }

    let p = GraphFixtures.routing()
    var vox: Track { p.tracks[0] }
    var gain: ParamTarget { .strip(channel: vox.id, param: .gain) }
    var mapping: AutomationMapping { p.automationMapping(for: gain) }

    func pt(_ tick: Int64, _ value: Float, _ curve: AutomationPoint.Curve = .linear) -> AutomationPoint {
        AutomationPoint(tick: Tick(tick), value: value, curve: curve)
    }

    func lane(_ project: Project, _ target: ParamTarget? = nil) -> AutomationLane? {
        project.automationLane(for: target ?? gain)?.lane
    }

    /// A store with a FakeEngine and a lane on Vox gain in `mode` (points 0 → 0.5, 3840 → 0.5).
    func rig(_ mode: AutomationLane.Mode, points: [AutomationPoint]? = nil) throws -> (ProjectStore, FakeEngine, AutomationRecorder) {
        let engine = FakeEngine()
        let store = ProjectStore(project: p)
        try store.attachEngine(engine, debounce: .zero)
        try store.perform(AddAutomationPoints(target: gain, points: points ?? [pt(0, 0.5), pt(3840, 0.5)]))
        try store.perform(SetAutomationMode(target: gain, mode: mode))
        return (store, engine, AutomationRecorder(store: store))
    }

    func playing(_ tick: Int64) -> TransportState {
        var t = TransportState()
        t.tick = Tick(tick)
        t.playing = true
        return t
    }

    func stopped(_ tick: Int64) -> TransportState {
        var t = TransportState()
        t.tick = Tick(tick)
        return t
    }

    // MARK: Thinning (AUTO-006)

    @Test("AUTO-006: RDP thinning keeps the ends, drops points within ε = 0.5 % of a line, keeps corners and spikes")
    func thinning() {
        // A straight ramp collapses to its ends.
        let ramp = (0...100).map { pt(Int64($0) * 10, Float($0) / 100) }
        #expect(AutomationThinning.thin(ramp) == [ramp[0], ramp[100]])
        // Noise below ε goes, a corner stays.
        let noisy = (0...50).map { pt(Int64($0) * 10, 0.5 + ($0 % 2 == 0 ? 0.002 : -0.002)) }
        #expect(AutomationThinning.thin(noisy).count == 2)
        let corner = (0...20).map { pt(Int64($0) * 10, $0 <= 10 ? 0 : Float($0 - 10) / 10) }
        #expect(AutomationThinning.thin(corner) == [corner[0], corner[10], corner[20]])
        // A spike just over ε is kept; just under is dropped.
        let over = [pt(0, 0.5), pt(10, 0.5 + 0.0051), pt(20, 0.5)]
        let under = [pt(0, 0.5), pt(10, 0.5 + 0.0049), pt(20, 0.5)]
        #expect(AutomationThinning.thin(over).count == 3)
        #expect(AutomationThinning.thin(under).count == 2)
        // Two points or fewer are returned as they are; a long gesture doesn't recurse.
        #expect(AutomationThinning.thin([pt(0, 1)]) == [pt(0, 1)])
        let long = (0..<200_000).map { pt(Int64($0), Float(sin(Double($0) / 3000) * 0.5 + 0.5)) }
        let thinned = AutomationThinning.thin(long)
        #expect(thinned.first == long.first && thinned.last == long.last && thinned.count < 400)
        // Every dropped point is within ε of the thinned curve.
        let lane = AutomationLane(id: 1, target: gain, points: thinned)
        #expect(long.allSatisfy { abs(lane.value(at: $0.tick)! - $0.value) <= 0.005 + 1e-6 })
    }

    // MARK: Mapping and evaluation

    @Test("AUTO-008: the model's mapping matches the engine's (gain db with 5/6 = unity, pan linear, send db), and inverts")
    func mappingRoundTrip() {
        #expect(abs(mapping.denormalize(5.0 / 6) - 1) < 1e-5)
        #expect(abs(mapping.normalize(1) - 5.0 / 6) < 1e-5)
        #expect(mapping.denormalize(0) == 0 && mapping.normalize(0) == 0)
        #expect(abs(mapping.denormalize(1) - ChannelStripState.maxGain) < 1e-4)
        for v in stride(from: Float(0.05), through: 1, by: 0.05) {
            #expect(abs(mapping.normalize(mapping.denormalize(v)) - v) < 1e-5)
        }
        let pan = p.automationMapping(for: .strip(channel: vox.id, param: .pan))
        #expect(pan.denormalize(0.5) == 0 && pan.normalize(-1) == 0 && pan.normalize(1) == 1)
        let send = p.automationMapping(for: .sendLevel(send: vox.sends[0].id))
        #expect(abs(send.denormalize(5.0 / 6) - 1) < 1e-5)
        // Built-in device params use their ParamInfo row; without a catalog they map 0…1 as is.
        let catalog = ParamCatalog.withInfos([.eq: [1: ParamDescriptor(index: 1, id: "hpFreq", name: "HP Freq", min: 20, max: 20_000, default: 20, curve: .log)]])
        let hp = p.automationMapping(for: .device(slot: vox.inserts[0].id, index: 1), catalog: catalog)
        #expect(abs(hp.denormalize(0.5) - 632.4555) < 0.01 && abs(hp.normalize(20_000) - 1) < 1e-5)
        #expect(p.automationMapping(for: .device(slot: vox.inserts[0].id, index: 1), catalog: ParamCatalog()) == .identity)
    }

    @Test("AUTO-004: lane evaluation in the model matches the engine's curves (linear, hold, exp; holds before and after)")
    func evaluation() {
        let lane = AutomationLane(id: 1, target: gain, points: [pt(100, 0.2), pt(200, 0.6, .hold), pt(300, 0.0, .exp(3)), pt(400, 1)])
        #expect(lane.value(at: 0) == 0.2 && lane.value(at: 100) == 0.2)
        #expect(abs(lane.value(at: 150)! - 0.4) < 1e-6)
        #expect(lane.value(at: 299) == 0.6 && lane.value(at: 300) == 0.0)
        let w = Float(expm1(3 * 0.25) / expm1(3.0))
        #expect(abs(lane.value(at: 325)! - w) < 1e-6)
        #expect(lane.value(at: 10_000) == 1)
        #expect(AutomationLane(id: 2, target: gain).value(at: 0) == nil)
    }

    // MARK: RecordAutomation (MODEL-005)

    @Test("AUTO-006, MODEL-005: RecordAutomation replaces [from, to], anchors the old curve one tick outside, inverse exact")
    func recordMerges() throws {
        var q = p
        _ = try AddAutomationPoints(target: gain, points: [pt(0, 0.2), pt(1000, 0.6), pt(2000, 0.2, .hold), pt(3000, 0.9)])
            .applyChecked(to: &q)
        _ = try SetAutomationMode(target: gain, mode: .touch).applyChecked(to: &q)
        let command = RecordAutomation(target: gain, from: 500, to: 1500, points: [pt(500, 1), pt(1500, 0)], mode: .touch)
        let applied = try expectApplyRoundTrip(command, on: q)
        let points = try #require(lane(applied)).points
        #expect(points.map(\.tick.raw) == [0, 499, 500, 1500, 1501, 2000, 3000])
        #expect(points[2] == pt(500, 1) && points[3] == pt(1500, 0))
        let old = try #require(lane(q))
        let new = try #require(lane(applied))
        // Outside the pass the lane plays what it played (linear segments: exactly).
        for tick in [0, 100, 498, 1502, 1700, 1999, 2000, 2500, 3000, 5000] as [Int64] {
            #expect(abs(new.value(at: Tick(tick))! - old.value(at: Tick(tick))!) < 1e-5, "tick \(tick)")
        }
        #expect(new.mode == .touch, "the lane's mode is kept")
        // Inside a hold segment the anchor holds too.
        let held = try expectApplyRoundTrip(
            RecordAutomation(target: gain, from: 2200, to: 2400, points: [pt(2200, 0.5), pt(2400, 0.5)], mode: .latch), on: q)
        let heldLane = try #require(lane(held))
        #expect(heldLane.points.contains(pt(2199, 0.2, .hold)) && heldLane.points.contains(pt(2401, 0.2, .hold)))
        #expect(heldLane.value(at: 2100) == 0.2 && heldLane.value(at: 2300) == 0.5 && heldLane.value(at: 2700) == 0.2)
        // A kept point next to the pass needs no anchor; a pass from 0 none before it.
        let edge = try expectApplyRoundTrip(
            RecordAutomation(target: gain, from: 0, to: 999, points: [pt(0, 0.3), pt(999, 0.3)], mode: .write), on: q)
        #expect(try #require(lane(edge)).points.map(\.tick.raw) == [0, 999, 1000, 2000, 3000])
    }

    @Test("AUTO-006, MODEL-031: RecordAutomation creates a lane in its mode (no anchors) and refuses bad input")
    func recordChecks() throws {
        let next = p.ids.next
        let created = try expectApplyRoundTrip(
            RecordAutomation(target: gain, from: 960, to: 1920, points: [pt(960, 0.4), pt(1920, 0.7)], mode: .latch), on: p)
        #expect(lane(created) == AutomationLane(id: next, target: gain, points: [pt(960, 0.4), pt(1920, 0.7)], mode: .latch))
        func refused(_ command: RecordAutomation) {
            var q = p
            #expect(throws: DAWError.self) { _ = try command.applyChecked(to: &q) }
            #expect(q == p)
        }
        refused(RecordAutomation(target: gain, from: 0, to: 10, points: [pt(0, 0.4)], mode: .read))
        refused(RecordAutomation(target: gain, from: 0, to: 10, points: [], mode: .touch))
        refused(RecordAutomation(target: gain, from: 10, to: 0, points: [pt(5, 0.4)], mode: .touch))
        refused(RecordAutomation(target: gain, from: 0, to: 10, points: [pt(11, 0.4)], mode: .touch))
        refused(RecordAutomation(target: gain, from: 0, to: 10, points: [pt(5, 0.4), pt(5, 0.5)], mode: .touch))
        refused(RecordAutomation(target: gain, from: 0, to: 10, points: [pt(5, 1.5)], mode: .touch))
        refused(RecordAutomation(target: .strip(channel: vox.id, param: .solo), from: 0, to: 10, points: [pt(5, 1)], mode: .touch))
        refused(RecordAutomation(target: .sendLevel(send: 999), from: 0, to: 10, points: [pt(5, 1)], mode: .touch))
        // JSON (MODEL-006): registered, round trips.
        let json = try CommandRegistry.encode(RecordAutomation(target: gain, from: 0, to: 10, points: [pt(0, 0.4)], mode: .touch))
        let decoded = try #require(try CommandRegistry.decode(json) as? RecordAutomation)
        #expect(decoded.mode == .touch && decoded.points == [pt(0, 0.4)] && decoded.to == 10)
    }

    // MARK: DW-236

    @Test("DW-236: ParamCatalog parses automatable; commands refuse a new lane on a non-automatable built-in param, validate stays lenient")
    func automatableFlag() throws {
        let json = #"[{"index":0,"id":"hpOn","name":"HP On","min":0,"max":1,"default":0,"curve":"linear","unit":"","automatable":false},{"index":1,"id":"hpFreq","name":"HP Freq","min":20,"max":20000,"default":20,"curve":"log","unit":"Hz","automatable":true}]"#
        let infos = ParamCatalog.parseInfos(json)
        #expect(infos[0]?.automatable == false && infos[1]?.automatable == true && infos[1]?.curve == .log)
        // The real engine's catalog says the same, and becomes the built-in catalog.
        let catalog = ParamCatalog(engine: try EngineClient(.offline()))
        #expect(!catalog.isAutomatable(.eq, 0) && catalog.isAutomatable(.eq, 1))
        #expect(!catalog.isAutomatable(.compressor, 6) && catalog.isAutomatable(.compressor, 0))
        #expect(!catalog.isAutomatable(.channelStrip, 3), "phase")
        #expect(catalog.isAutomatable(.vst3Plugin, 0), "plugins have no ParamInfo: automatable")
        #expect(ParamCatalog.builtin.isAutomatable(.eq, 0) == false)

        let hpOn = ParamTarget.device(slot: vox.inserts[0].id, index: 0)
        for command in [AddAutomationPoint(target: hpOn, point: pt(0, 1)) as any Command,
                        AddAutomationPoints(target: hpOn, points: [pt(0, 1)]), SetAutomationMode(target: hpOn, mode: .read),
                        RecordAutomation(target: hpOn, from: 0, to: 1, points: [pt(0, 1)], mode: .touch)] {
            var q = p
            #expect(throws: DAWError.invalidArgument("eq HP On can't be automated")) { _ = try command.apply(to: &q) }
        }
        // An automatable param of the same device is fine; an existing lane on hpOn (an old file)
        // still validates and stays editable.
        _ = try expectApplyRoundTrip(AddAutomationPoint(target: .device(slot: vox.inserts[0].id, index: 1), point: pt(0, 1)), on: p)
        var old = p
        old.tracks[0].automation = [AutomationLane(id: old.ids.allocate(), target: hpOn, points: [pt(0, 1)])]
        try old.validate()
        _ = try expectApplyRoundTrip(AddAutomationPoint(target: hpOn, point: pt(960, 0)), on: old)
    }

    // MARK: Recorder modes (AUTO-006)

    @Test("AUTO-006 touch: a held gesture is one RecordAutomation at release; the lane is suspended meanwhile and plays its curve after")
    func touchMode() throws {
        let (store, engine, recorder) = try rig(.touch)
        let slot = try #require(store.engineSync?.runtime.stripParam(vox.id, ParamLayout.Strip.gain))
        recorder.transportChanged(playing(0))
        engine.play()
        #expect(recorder.beginGesture(gain, value: 1.0, at: 960, playing: true))
        let laneID = try #require(lane(store.project)).id
        #expect(engine.suspendedLanes == [laneID])
        #expect(engine.getParam(slot) == 1.0, "the control's value goes straight to the slot")
        for (i, tick) in stride(from: 970, through: 1900, by: 10).enumerated() {
            recorder.move(gain, value: 1.0 + Float(i) * 0.01, at: Tick(Int64(tick)))
        }
        #expect(lane(store.project)?.points == [pt(0, 0.5), pt(3840, 0.5)], "nothing commits while held")
        #expect(store.project.track(vox.id)?.strip.gain == 1, "the static value doesn't change")
        recorder.endGesture(gain, at: 1920)
        #expect(engine.suspendedLanes.isEmpty)
        #expect(store.undoLabel == "Record Automation")
        let recorded = try #require(lane(store.project))
        #expect(recorded.points.first == pt(0, 0.5) && recorded.points.last == pt(3840, 0.5))
        #expect(recorded.points.contains { $0.tick == 959 } && recorded.points.contains { $0.tick == 1921 }, "anchors")
        #expect(abs(recorded.value(at: 960)! - mapping.normalize(1.0)) < 1e-5)
        #expect(abs(recorded.value(at: 1920)! - mapping.normalize(1.93)) < 1e-4)
        #expect(recorded.value(at: 2500) == 0.5, "back on the existing curve after release")
        let inside = recorded.points.filter { $0.tick >= 960 && $0.tick <= 1920 }
        #expect(inside.count < 20, "thinned: \(inside.count) of 95 points")
        // One undo restores the lane exactly.
        store.undo()
        #expect(lane(store.project)?.points == [pt(0, 0.5), pt(3840, 0.5)])
        // Not playing, or a read lane: the gesture doesn't record.
        #expect(!recorder.beginGesture(gain, value: 1, at: 0, playing: false))
        try store.perform(SetAutomationMode(target: gain, mode: .read))
        #expect(!recorder.beginGesture(gain, value: 1, at: 0, playing: true))
        #expect(recorder.passes.isEmpty)
    }

    @Test("AUTO-006 latch: from the first grab it keeps writing the last value until stop, then the lane resumes")
    func latchMode() throws {
        let (store, engine, recorder) = try rig(.latch)
        recorder.transportChanged(playing(0))
        #expect(recorder.beginGesture(gain, value: 2.0, at: 960, playing: true))
        recorder.move(gain, value: 0.5, at: 1200)
        recorder.endGesture(gain, at: 1300)
        #expect(recorder.isRecording(gain) && !engine.suspendedLanes.isEmpty, "still writing after release")
        #expect(recorder.committed.isEmpty)
        recorder.transportChanged(playing(2000))
        recorder.transportChanged(playing(2400))
        recorder.transportChanged(stopped(2400))
        #expect(engine.suspendedLanes.isEmpty)
        let command = try #require(recorder.committed.last)
        #expect(command.from == 960 && command.to == 2400 && command.mode == .latch)
        let recorded = try #require(lane(store.project))
        #expect(abs(recorded.value(at: 2400)! - mapping.normalize(0.5)) < 1e-5, "holds the last value until stop")
        #expect(abs(recorded.value(at: 1800)! - mapping.normalize(0.5)) < 1e-5)
        #expect(recorded.value(at: 3000) == 0.5, "the lane resumes after stop")
        #expect(store.undoLabel == "Record Automation")
    }

    @Test("AUTO-006 write: from play to stop the lane is overwritten with the control's value, gesture or not")
    func writeMode() throws {
        let (store, engine, recorder) = try rig(.write, points: [pt(0, 0.1), pt(1000, 0.9), pt(5000, 0.1)])
        let slot = try #require(store.engineSync?.runtime.stripParam(vox.id, ParamLayout.Strip.gain))
        engine.setParam(slot, 1.0)  // what the control holds at play
        recorder.transportChanged(playing(480))
        #expect(recorder.isRecording(gain) && engine.suspendedLanes.count == 1)
        recorder.transportChanged(playing(1200))
        #expect(recorder.beginGesture(gain, value: 0.25, at: 1500, playing: true))
        recorder.endGesture(gain, at: 1600)
        recorder.transportChanged(playing(2880))
        recorder.transportChanged(stopped(2880))
        let recorded = try #require(lane(store.project))
        #expect(abs(recorded.value(at: 480)! - mapping.normalize(1.0)) < 1e-5)
        #expect(abs(recorded.value(at: 1000)! - mapping.normalize(1.0)) < 0.01, "the old 0.9 point is overwritten")
        #expect(!recorded.points.contains { $0.tick == 1000 })
        #expect(abs(recorded.value(at: 2000)! - mapping.normalize(0.25)) < 1e-5, "holds the gesture's value until stop")
        #expect(recorded.value(at: 0) == 0.1, "before play: untouched")
        #expect(abs(recorded.value(at: 5000)! - 0.1) < 1e-6, "after stop: the existing curve")
        #expect(recorder.committed.count == 1 && engine.suspendedLanes.isEmpty)
        // A write lane without a gesture: the whole pass holds the value at play.
        recorder.transportChanged(playing(0))
        recorder.transportChanged(stopped(960))
        #expect(recorder.committed.count == 2 && recorder.committed[1].points.map(\.value).allSatisfy { $0 == recorder.committed[1].points[0].value })
    }

    @Test("AUTO-006: a loop wrap ends the pass at the wrap and starts another at the loop start (one command per pass)")
    func loopWrapSplits() throws {
        let (store, _, recorder) = try rig(.latch)
        recorder.transportChanged(playing(960))
        #expect(recorder.beginGesture(gain, value: 2.0, at: 1000, playing: true))
        recorder.transportChanged(playing(1900))
        recorder.transportChanged(playing(970))  // wrapped to the loop start
        #expect(recorder.committed.count == 1 && recorder.committed[0].to == 1900)
        #expect(recorder.isRecording(gain) && recorder.passes[gain]?.from == 970 && recorder.passes[gain]?.held == true)
        recorder.endGesture(gain, at: 1000)
        recorder.transportChanged(stopped(1100))
        #expect(recorder.committed.count == 2 && recorder.committed[1].from == 970 && recorder.committed[1].to == 1100)
        _ = store
    }

    // MARK: Stopped (AUTO-007, DW-237)

    @Test("AUTO-007: stopped controls show the lane at the playhead; a move edits the point under the playhead, else holds until the playhead moves")
    func stoppedEdits() throws {
        let (store, _, recorder) = try rig(.read, points: [pt(0, 0.2), pt(960, 0.6), pt(1920, 0.2)])
        recorder.transportChanged(stopped(480))
        #expect(abs(recorder.displayedValue(gain, staticValue: 1, playhead: 480) - mapping.denormalize(0.4)) < 1e-5)
        #expect(recorder.isAutomated(gain))
        // A point exactly at the playhead: its value changes, undoably.
        recorder.transportChanged(stopped(960))
        #expect(try recorder.stoppedEdit(gain, value: 2.0, at: 960) == .editedPoint(960))
        #expect(abs(lane(store.project)!.points[1].value - mapping.normalize(2.0)) < 1e-6)
        #expect(store.undoLabel == "Edit Automation")
        store.undo()
        #expect(lane(store.project)!.points[1].value == 0.6)
        // No point there: the caller's SetParam holds, and the control shows it until the playhead changes.
        recorder.transportChanged(stopped(480))
        #expect(try recorder.stoppedEdit(gain, value: 2.0, at: 480) == .heldUntilPlayheadMoves)
        try store.perform(SetParam(target: gain, value: 2.0))
        #expect(recorder.displayedValue(gain, staticValue: 2.0, playhead: 480) == 2.0)
        recorder.transportChanged(stopped(480))
        #expect(recorder.displayedValue(gain, staticValue: 2.0, playhead: 480) == 2.0, "same playhead: still held")
        recorder.transportChanged(stopped(500))
        #expect(abs(recorder.displayedValue(gain, staticValue: 2.0, playhead: 500) - mapping.denormalize(0.2 + 0.4 * 500 / 960)) < 1e-4)
        // An off lane, or no points: the control shows its own value.
        try store.perform(SetAutomationMode(target: gain, mode: .off))
        #expect(recorder.displayedValue(gain, staticValue: 2.0, playhead: 500) == 2.0)
        #expect(try recorder.stoppedEdit(gain, value: 1, at: 960) == StoppedEdit.none)
    }

    typealias StoppedEdit = AutomationRecorder.StoppedEdit

    // MARK: Real engine: a recorded touch gesture plays back

    @Test("AUTO-006: a touch gesture recorded through the recorder plays back from the real engine (offline render), 0 RT violations")
    func touchPlaysBack() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "autorec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appending(path: "dc.wav")
        try writeDCWAV(wav, frames: 4 * 48_000)
        let engine = try EngineClient(.offline(sampleRate: 48_000))
        let store = ProjectStore(project: Project(name: "autorec"))
        let sync = try store.attachEngine(engine)
        try store.perform(AddTrack(name: "DC", kind: .audio))
        let track = store.project.tracks[0].id
        let id = store.project.ids.next
        let loaded = try #require(await engine.waitForJob(engine.loadAsset(id, path: wav.path)).asset)
        try store.perform(ImportAsset(asset: AssetRef(id: id, path: wav.path, channels: Int(loaded.channels),
                                                      originalSampleRate: loaded.fileSampleRate, frames: loaded.fileFrames)))
        try store.perform(AddClip(trackID: track, start: 0, assetID: id))
        let target = ParamTarget.strip(channel: track, param: .gain)
        let m = store.project.automationMapping(for: target)
        // An existing lane at unity, in touch mode.
        try store.perform(AddAutomationPoints(target: target, points: [AutomationPoint(tick: 0, value: m.normalize(1))]))
        try store.perform(SetAutomationMode(target: target, mode: .touch))
        let recorder = AutomationRecorder(store: store)
        // The gesture: grab at beat 2 (−12 dB), ride down to −24 dB, release at beat 4.
        #expect(recorder.beginGesture(target, value: 0.25, at: 960, playing: true))
        for tick in stride(from: 970, through: 2880, by: 10) {
            let f = Double(tick - 960) / 1920
            recorder.move(target, value: Float(pow(10, (-12 - 12 * f) / 20)), at: Tick(Int64(tick)))
        }
        recorder.endGesture(target, at: 2880)
        #expect(store.undoLabel == "Record Automation")

        await sync.settle()
        #expect(await engine.graphApplied(engine.graphStatus().submittedVersion).lastError == nil)
        let path = dir.appending(path: "out.wav").path
        let spec = ExportSpec(path: path, blockSize: 256, tailEnabled: false)
        let result = try #require(await engine.waitForJob(engine.renderOffline(from: 0, to: 3840, spec: spec)).render)
        #expect(result.rtViolations == 0)
        let file = try AVAudioFile(forReading: URL(filePath: path))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let left = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        // 120 bpm, 48 kHz: 25 frames per tick. Gains are relative to the lane's unity before the
        // gesture (the DC level after the mono source's centre pan).
        let unity = Double(left[480 * 25])
        #expect(abs(unity - 0.25) < 0.01, "0.5 DC, centre-panned twice-√½ (−6 dB) at unity")
        func gainAt(_ tick: Int) -> Double { Double(left[tick * 25 + 20]) / unity }
        func db(_ g: Double) -> Double { 20 * log10(g) }
        #expect(abs(db(gainAt(100))) < 0.01, "before the gesture: the lane's unity")
        #expect(abs(db(gainAt(1000)) - -12.25) < 0.5, "early in the gesture")
        #expect(abs(db(gainAt(1920)) - -18) < 0.5, "mid-gesture")
        #expect(abs(db(gainAt(2860)) - -24) < 0.5, "just before release")
        #expect(abs(db(gainAt(3400))) < 0.05, "after release: back on the existing curve")
    }

    private func writeDCWAV(_ url: URL, frames: Int) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frames * 4))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(3)); append(UInt16(1))
        append(UInt32(48_000)); append(UInt32(192_000)); append(UInt16(4)); append(UInt16(32))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(frames * 4))
        for _ in 0..<frames { append(Float(0.5).bitPattern) }
        try data.write(to: url)
    }
}

extension ParamCatalog {
    /// A catalog with ParamInfo rows only (tests).
    static func withInfos(_ infos: [NodeKind: [Int: ParamDescriptor]]) -> ParamCatalog {
        var catalog = ParamCatalog()
        catalog.infos = infos
        return catalog
    }
}
