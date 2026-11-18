import Foundation
import Testing

@testable import DAWModel

// DW-277 (T-095, docs/autobuild/DECISIONS.md "T-095 app decisions"): edits from a plugin's own editor
// (T-063 `pluginParamEdited` events) feed the AutomationRecorder while automation recording is on,
// exactly like a UI control's gesture (AUTO-006 touch/latch/write; AUTO-007 stopped point edits).
// Events go the real way: FakeEngine → EngineSync.pollEvents → AutomationRecorder.pluginEdited,
// else PluginEditRecorder's SetParam (DW-204).

@Suite("Plugin editor edits feed automation recording (DW-277, AUTO-006/007)")
@MainActor
struct PluginEditAutomationTests {
    /// A store on a FakeEngine: track Fx with a VST3 insert whose param 0 has a lane in `mode`
    /// (points 0 → 0.5, 3840 → 0.5), and the store's recorder.
    private func rig(_ mode: AutomationLane.Mode, points: [AutomationPoint]? = nil) throws
        -> (ProjectStore, FakeEngine, AutomationRecorder, slot: NodeIDValue, target: ParamTarget) {
        let store = ProjectStore(project: Project(name: "P"))
        store.autosavePolicy = nil
        let engine = FakeEngine()
        try store.attachEngine(engine, debounce: .zero)
        try store.perform(AddTrack(name: "Fx", kind: .audio))
        let track = store.project.tracks[0].id
        try store.perform(InsertDevice(channel: track, device: .vst3(VST3Descriptor(identifier: "/x.vst3#01", name: "X"))))
        let slot = store.project.tracks[0].inserts[0].id
        let target = ParamTarget.device(slot: slot, index: 0)
        try store.perform(AddAutomationPoints(target: target, points: points ?? [pt(0, 0.5), pt(3840, 0.5)]))
        try store.perform(SetAutomationMode(target: target, mode: mode))
        let recorder = AutomationRecorder(store: store)
        return (store, engine, recorder, slot, target)
    }

    private func pt(_ tick: Int64, _ value: Float) -> AutomationPoint { AutomationPoint(tick: Tick(tick), value: value) }

    /// Posts plugin edits at the playhead `tick` and polls them through engine sync, as the app does.
    private func edits(_ engine: FakeEngine, _ store: ProjectStore, _ recorder: AutomationRecorder, at tick: Int64,
                       _ slot: NodeIDValue, _ list: [(PluginParamEdit.Phase, Float)]) {
        engine.locate(Tick(tick))
        recorder.transportChanged(engine.transport())
        for (phase, value) in list {
            engine.post(EngineEvent(pluginEdit: PluginParamEdit(index: 0, value: value, phase: phase), slot: slot))
        }
        _ = store.engineSync?.pollEvents()
    }

    private func lane(_ store: ProjectStore, _ target: ParamTarget) -> AutomationLane? {
        store.project.automationLane(for: target)?.lane
    }

    private func param(_ store: ProjectStore, _ slot: NodeIDValue) -> Float? {
        store.project.tracks[0].inserts.first { $0.id == slot }?.params.first { $0.index == 0 }?.value
    }

    @Test("DW-277 touch: a plugin gesture while playing is one RecordAutomation at its end; no SetParam; the lane is suspended meanwhile")
    func touchRecordsPluginGesture() throws {
        let (store, engine, recorder, slot, target) = try rig(.touch)
        #expect(store.engineSync?.automationRecorder === recorder, "the recorder attaches itself")
        engine.play()
        edits(engine, store, recorder, at: 960, slot, [(.begin, 0.5), (.value, 0.9)])
        #expect(recorder.passes[target]?.held == true)
        #expect(engine.suspendedLanes == [try #require(lane(store, target)).id])
        let id = try #require(store.engineSync?.runtime.paramID(slot, 0))
        #expect(engine.getParam(id) == 0.9, "the plugin's value goes to its slot while the lane is suspended")
        edits(engine, store, recorder, at: 1440, slot, [(.value, 0.1)])
        #expect(!store.isGestureActive, "no SetParam gesture opened")
        edits(engine, store, recorder, at: 1920, slot, [(.end, .nan)])
        #expect(recorder.passes.isEmpty && engine.suspendedLanes.isEmpty)
        #expect(store.undoLabel == "Record Automation")
        let recorded = try #require(lane(store, target))
        #expect(abs(recorded.value(at: 960)! - 0.9) < 1e-5 && abs(recorded.value(at: 1920)! - 0.1) < 1e-5)
        #expect(recorded.value(at: 3000) == 0.5, "back on the existing curve after the gesture")
        #expect(param(store, slot) == nil, "the document's static value is untouched")
        store.undo()
        #expect(lane(store, target)?.points == [pt(0, 0.5), pt(3840, 0.5)], "one undo entry")
    }

    @Test("DW-277 latch/write: a plugin menu change (ungestured value) while playing latches until stop")
    func latchUngesturedValue() throws {
        let (store, engine, recorder, slot, target) = try rig(.latch)
        engine.play()
        edits(engine, store, recorder, at: 960, slot, [(.value, 0.25)])
        #expect(recorder.isRecording(target) && recorder.passes[target]?.held == false, "latched after a grab and release")
        engine.locate(Tick(2400))
        recorder.transportChanged(engine.transport())
        engine.stop()
        recorder.transportChanged(engine.transport())
        let command = try #require(recorder.committed.last)
        #expect(command.from == 960 && command.to == 2400 && command.mode == .latch)
        #expect(abs(lane(store, target)!.value(at: 2000)! - 0.25) < 1e-5)
        #expect(param(store, slot) == nil && store.undoLabel == "Record Automation")
    }

    @Test("DW-277: a read lane while playing, or no lane, keeps DW-204's SetParam gesture (one undo entry)")
    func readLaneKeepsSetParam() throws {
        let (store, engine, recorder, slot, target) = try rig(.read)
        engine.play()
        edits(engine, store, recorder, at: 960, slot, [(.begin, 0.5), (.value, 0.7), (.end, .nan)])
        #expect(recorder.passes.isEmpty && recorder.committed.isEmpty)
        #expect(param(store, slot) == 0.7 && store.undoLabel == "Set Parameter")
        #expect(lane(store, target)?.points == [pt(0, 0.5), pt(3840, 0.5)])
    }

    @Test("DW-277 stopped (AUTO-007): a plugin edit on an automated param edits the lane's point at the playhead, in the plugin gesture's one undo entry; elsewhere it is a SetParam")
    func stoppedEditsPoint() throws {
        let (store, engine, recorder, slot, target) = try rig(.read, points: [pt(0, 0.2), pt(960, 0.6), pt(1920, 0.2)])
        edits(engine, store, recorder, at: 960, slot, [(.begin, 0.6), (.value, 0.8), (.value, 0.9), (.end, .nan)])
        #expect(lane(store, target)?.points.map(\.value) == [0.2, 0.9, 0.2])
        #expect(param(store, slot) == nil)
        store.undo()
        #expect(lane(store, target)?.points.map(\.value) == [0.2, 0.6, 0.2], "the gesture is one undo entry")
        // No point under the playhead: the plugin's value is a plain SetParam (held until the playhead moves).
        edits(engine, store, recorder, at: 480, slot, [(.begin, 0.4), (.value, 0.3), (.end, .nan)])
        #expect(param(store, slot) == 0.3 && store.undoLabel == "Set Parameter")
        #expect(lane(store, target)?.points.map(\.value) == [0.2, 0.6, 0.2])
    }

    @Test("DW-277: a newly attached engine (handover) gets the recorder at the next transport poll")
    func reattachesAfterHandover() throws {
        let (store, _, recorder, _, _) = try rig(.touch)
        let next = FakeEngine()
        let sync = try store.attachEngine(next, debounce: .zero)
        #expect(sync.automationRecorder == nil)
        recorder.transportChanged(next.transport())
        #expect(sync.automationRecorder === recorder)
    }
}
