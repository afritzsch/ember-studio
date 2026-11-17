import DAWModel
import Foundation
import Testing

// DW-204 (T-063, PLUG-015 second half): a plugin's own edits (`pluginParamEdited` events) reach the
// document as undoable SetParam gestures, one undo entry per gesture (MODEL-003), without echoes.
// The engine side (events from VST3 begin/perform/endEdit and AU gestures) is in DAWEngineTests'
// PluginEditorTests; the real-engine round trip is in DAWControlTests' PluginEditControlTests.

@Suite("Plugin-side parameter edits (DW-204)")
@MainActor
struct PluginEditRecorderTests {
    /// A store on a FakeEngine with an audio track carrying a VST3 insert and a built-in EQ.
    private func makeStore() throws -> (ProjectStore, FakeEngine, vst3: NodeIDValue, eq: NodeIDValue) {
        let store = ProjectStore(project: Project(name: "P"))
        store.autosavePolicy = nil
        let engine = FakeEngine()
        try store.attachEngine(engine, debounce: .zero)
        try store.perform(AddTrack(name: "Fx", kind: .audio))
        let track = store.project.tracks[0].id
        try store.perform(InsertDevice(channel: track, device: .vst3(VST3Descriptor(identifier: "/x.vst3#01", name: "X"))))
        try store.perform(InsertDevice(channel: track, device: .builtin(.eq)))
        let inserts = store.project.tracks[0].inserts
        return (store, engine, inserts[0].id, inserts[1].id)
    }

    private func post(_ engine: FakeEngine, _ slot: NodeIDValue, _ index: Int, _ phase: PluginParamEdit.Phase, _ value: Float = .nan) {
        engine.post(EngineEvent(pluginEdit: PluginParamEdit(index: index, value: value, phase: phase), slot: slot))
    }

    private func undoDepth(_ store: ProjectStore) -> Int {
        var n = 0
        while store.canUndo {
            store.undo()
            n += 1
        }
        for _ in 0..<n { store.redo() }
        return n
    }

    private func param(_ store: ProjectStore, _ slot: NodeIDValue, _ index: Int) -> Float? {
        store.project.tracks[0].inserts.first { $0.id == slot }?.params.first { $0.index == index }?.value
    }

    @Test("DW-204, MODEL-003: a 100-step plugin gesture is one undo entry; DeviceSlot.params and the param slot follow it")
    func gestureIsOneEntry() throws {
        let (store, engine, vst3, _) = try makeStore()
        let before = undoDepth(store)
        post(engine, vst3, 0, .begin)
        for step in 1...100 { post(engine, vst3, 0, .value, Float(step) / 100) }
        _ = store.engineSync?.pollEvents()
        #expect(store.isGestureActive, "still held")
        #expect(param(store, vst3, 0) == 1)
        post(engine, vst3, 0, .end)
        _ = store.engineSync?.pollEvents()
        #expect(!store.isGestureActive)
        #expect(undoDepth(store) == before + 1 && store.undoLabel == "Set Parameter")
        // The engine has it (MODEL-021: a param slot write).
        let id = try #require(store.engineSync?.runtime.paramID(vst3, 0))
        #expect(engine.getParam(id) == 1)
        store.undo()
        #expect(param(store, vst3, 0) == nil, "the param is not set again")
        store.redo()
        #expect(param(store, vst3, 0) == 1)
    }

    @Test("DW-204: the engine's echo of the model's value, and a value the document already has, make no entry")
    func echoesMakeNoEntry() throws {
        let (store, engine, vst3, _) = try makeStore()
        try store.perform(SetParam(target: .device(slot: vst3, index: 1), value: 0.25))
        let before = undoDepth(store)
        post(engine, vst3, 1, .value, 0.25)  // ungestured echo
        post(engine, vst3, 1, .begin)
        post(engine, vst3, 1, .value, 0.25)
        post(engine, vst3, 1, .end)
        _ = store.engineSync?.pollEvents()
        #expect(undoDepth(store) == before)
        // After an undo the plugin follows the model; its report of the restored value is no edit.
        try store.perform(SetParam(target: .device(slot: vst3, index: 1), value: 0.75))
        store.undo()
        let afterUndo = undoDepth(store)
        post(engine, vst3, 1, .value, 0.25)
        _ = store.engineSync?.pollEvents()
        #expect(undoDepth(store) == afterUndo && store.canRedo, "the redo stays")
    }

    @Test("DW-204: ungestured values of one poll are one entry; values of another poll another")
    func ungesturedGroupPerPoll() throws {
        let (store, engine, vst3, _) = try makeStore()
        let before = undoDepth(store)
        post(engine, vst3, 0, .value, 0.1)
        post(engine, vst3, 1, .value, 0.2)
        post(engine, vst3, 0, .value, 0.3)  // the newest wins
        _ = store.engineSync?.pollEvents()
        #expect(undoDepth(store) == before + 1)
        #expect(param(store, vst3, 0) == 0.3 && param(store, vst3, 1) == 0.2)
        post(engine, vst3, 2, .value, 0.4)
        _ = store.engineSync?.pollEvents()
        #expect(undoDepth(store) == before + 2)
        store.undo()
        #expect(param(store, vst3, 2) == nil && param(store, vst3, 0) == 0.3)
    }

    @Test("DW-204: overlapping gestures of one plugin share one entry; built-in and unknown slots are ignored")
    func overlappingAndIgnored() throws {
        let (store, engine, vst3, eq) = try makeStore()
        let before = undoDepth(store)
        post(engine, vst3, 0, .begin)
        post(engine, vst3, 1, .begin)
        post(engine, vst3, 0, .value, 0.5)
        post(engine, vst3, 1, .value, 0.6)
        post(engine, vst3, 0, .end)
        _ = store.engineSync?.pollEvents()
        #expect(store.isGestureActive)
        post(engine, vst3, 1, .value, 0.7)
        post(engine, vst3, 1, .end)
        post(engine, eq, 0, .value, 3)       // a built-in: not a plugin edit
        post(engine, 9999, 0, .value, 3)     // no such slot
        _ = store.engineSync?.pollEvents()
        #expect(!store.isGestureActive && undoDepth(store) == before + 1)
        #expect(param(store, vst3, 1) == 0.7)
        #expect(store.project.tracks[0].inserts[1].params.allSatisfy { $0.index != 0 || $0.value != 3 })
    }

    @Test("DW-204: a gesture ends when its slot leaves the project, its editor closes, or the engine detaches")
    func gesturesEnd() throws {
        let (store, engine, vst3, _) = try makeStore()
        post(engine, vst3, 0, .begin)
        post(engine, vst3, 0, .value, 0.4)
        _ = store.engineSync?.pollEvents()
        #expect(store.isGestureActive)
        store.engineSync?.pluginEdits.endGestures(slot: vst3)  // the editor closed mid-drag
        #expect(!store.isGestureActive && param(store, vst3, 0) == 0.4 && store.undoLabel == "Set Parameter")
        post(engine, vst3, 0, .end)  // a late end changes nothing
        _ = store.engineSync?.pollEvents()
        #expect(!store.isGestureActive)

        // The slot is removed while its gesture is open (the removal ends the store's gesture too).
        post(engine, vst3, 0, .begin)
        post(engine, vst3, 0, .value, 0.9)
        _ = store.engineSync?.pollEvents()
        let sync = try #require(store.engineSync)
        store.endGesture()
        try store.perform(RemoveDevice(slotID: vst3))
        _ = sync.pollEvents()
        #expect(sync.pluginEdits.openGestures.isEmpty && !store.isGestureActive)

        // Detaching the engine ends what is open.
        let (store2, engine2, vst3b, _) = try makeStore()
        post(engine2, vst3b, 0, .begin)
        _ = store2.engineSync?.pollEvents()
        #expect(store2.isGestureActive)
        store2.detachEngine()
        #expect(!store2.isGestureActive)
    }
}

// docs/autobuild/DECISIONS.md "T-063 first-edit undo" (option c): undoing the first plugin-side edit of
// a param the document didn't set writes the plugin's pre-gesture value to its slot.
extension PluginEditRecorderTests {
    @Test("DW-204 (T-063 first-edit undo): undo of a first plugin edit writes the plugin's pre-gesture value; redo and later sets still work; one entry, document unset")
    func firstEditUndoRestoresBaseline() throws {
        let (store, engine, vst3, _) = try makeStore()
        let before = undoDepth(store)
        // The editor's knob was at 0.8 (begin carries it) and moves to 0.3.
        post(engine, vst3, 0, .begin, 0.8)
        post(engine, vst3, 0, .value, 0.5)
        post(engine, vst3, 0, .value, 0.3)
        post(engine, vst3, 0, .end)
        _ = store.engineSync?.pollEvents()
        #expect(undoDepth(store) == before + 1)
        let sync = try #require(store.engineSync)
        let id = try #require(sync.runtime.paramID(vst3, 0))
        func slotValue() -> Float {
            #expect(sync.runtime.paramID(vst3, 0) == id, "the param keeps its slot")
            return engine.getParam(sync.runtime.paramID(vst3, 0) ?? id)
        }
        #expect(slotValue() == 0.3)

        store.undo()
        #expect(param(store, vst3, 0) == nil, "the document is unset again")
        #expect(slotValue() == 0.8, "the plugin goes back to its own value")
        store.redo()
        #expect(slotValue() == 0.3)

        // A later set (another control, automation) still works, and undoing it goes back to 0.3.
        try store.perform(SetParam(target: .device(slot: vst3, index: 0), value: 0.6))
        #expect(slotValue() == 0.6)
        store.undo()
        #expect(slotValue() == 0.3)
        // A second gesture on a param the document sets keeps the first baseline.
        post(engine, vst3, 0, .begin, 0.3)
        post(engine, vst3, 0, .value, 0.1)
        post(engine, vst3, 0, .end)
        _ = store.engineSync?.pollEvents()
        store.undo()
        store.undo()
        #expect(param(store, vst3, 0) == nil && slotValue() == 0.8)
    }
}
