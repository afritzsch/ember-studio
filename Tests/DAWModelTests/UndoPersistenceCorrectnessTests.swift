import Foundation
import Testing

@testable import DAWModel

// T-112: undo and persistence correctness (07 "Contract delta (T-112)").
//   DW-334: undo/redo across a session-rate change (history rescaled, MODEL-002).
//   DW-336: gestures have an owner; other sources get their own undo entries (MODEL-003).
//   DW-337: dirty past the undo cap. DW-338: save mid-gesture leaves the store dirty.
//   DW-335: Save As autosave race (MODEL-044). DW-339: ID reservation for ImportAsset.

/// Parks the store's file-operation queue after a save (`ProjectStore.afterSaveIO`), so a test can
/// act while a slow save is "being written" (DW-335), without a clock.
private actor SaveGate {
    private var armed = false
    private var parked: CheckedContinuation<Void, Never>?
    private var parkWaiters: [CheckedContinuation<Void, Never>] = []

    func arm() { armed = true }

    func pass() async {
        guard armed else { return }
        armed = false
        await withCheckedContinuation { continuation in
            parked = continuation
            for waiter in parkWaiters { waiter.resume() }
            parkWaiters = []
        }
    }

    func waitUntilParked() async {
        if parked != nil { return }
        await withCheckedContinuation { parkWaiters.append($0) }
    }

    func release() {
        parked?.resume()
        parked = nil
    }
}

/// The commands whose undo or redo entries snapshot absolute sample values (DW-334).
enum SnapshottingScenario: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case splitClip = "SplitClip → [RemoveClip, SetClip]"
    case removeClip = "RemoveClip → RestoreClip"
    case removeAudioTrack = "RemoveTrack (clips, take folder) → RestoreTrack"
    case removeMidiTrack = "RemoveTrack (sampler zones) → RestoreTrack"
    case removeTakeFolder = "RemoveTakeFolder → RestoreTakeFolder"
    case setSamplerZones = "SetSamplerZones → SetSamplerZones"
    case removeInstrument = "RemoveInstrument → RestoreInstrument"
    case replaceInstrument = "SetInstrument (replacing) → RestoreInstrument"
    case addClip = "AddClip (offset) → redo RestoreClip"
    case createTakeFolder = "CreateTakeFolder (offsets) → redo RestoreTakeFolder"

    var testDescription: String { rawValue }

    func command(in p: Project) -> any Command {
        let audio = p.tracks[0], takes = p.tracks[1], keys = p.tracks[2]
        let asset = p.assets[0].id
        switch self {
        case .splitClip: return SplitClip(clipID: audio.clips[0].id, at: Tick(960))
        case .removeClip: return RemoveClip(clipID: audio.clips[1].id)
        case .removeAudioTrack: return RemoveTrack(trackID: takes.id)
        case .removeMidiTrack: return RemoveTrack(trackID: keys.id)
        case .removeTakeFolder: return RemoveTakeFolder(folderID: takes.takeFolders[0].id)
        case .setSamplerZones:
            return SetSamplerZones(slotID: keys.instrument!.id, zones: [SamplerZone(assetID: asset, loopStart: 10_001, loopEnd: 20_003)])
        case .removeInstrument: return RemoveInstrument(trackID: keys.id)
        case .replaceInstrument:
            return SetInstrument(trackID: keys.id, device: .builtin(.sampler),
                                 zones: [SamplerZone(assetID: asset, loopStart: 7, loopEnd: 9)])
        case .addClip:
            return AddClip(trackID: audio.id, start: Tick(15_360), length: Tick(960), assetID: asset, sourceOffsetSamples: 12_345)
        case .createTakeFolder:
            return CreateTakeFolder(trackID: audio.id, takes: [
                .init(start: Tick(19_200), length: Tick(960), assetID: asset, sourceOffsetSamples: 3_333),
                .init(start: Tick(19_200), length: Tick(960), assetID: asset, sourceOffsetSamples: 777),
            ])
        }
    }
}

@Suite("Undo and persistence correctness (T-112: DW-334..DW-339)")
@MainActor
struct UndoPersistenceCorrectnessTests {
    // MARK: Fixtures

    /// At 48 kHz: an audio track with a clip 10 s into its file and one at an odd offset, an audio
    /// track with a take folder of two audio takes, and a MIDI track whose sampler has a looped and
    /// an unlooped zone. Odd values make 44.1 kHz round.
    static func fixture() throws -> Project {
        var p = Project()
        let asset = AssetRef(id: p.ids.next, path: "/tmp/a.wav", channels: 2, originalSampleRate: 48_000, frames: 48_000 * 60)
        _ = try ImportAsset(asset: asset).apply(to: &p)
        _ = try AddTrack(name: "Audio", kind: .audio).apply(to: &p)
        _ = try AddTrack(name: "Takes", kind: .audio).apply(to: &p)
        _ = try AddTrack(name: "Keys", kind: .midi).apply(to: &p)
        let (audio, takes, keys) = (p.tracks[0].id, p.tracks[1].id, p.tracks[2].id)
        _ = try AddClip(trackID: audio, start: Tick(0), length: Tick(3_840), assetID: asset.id,
                        sourceOffsetSamples: 480_000).apply(to: &p)
        _ = try AddClip(trackID: audio, start: Tick(7_680), length: Tick(1_920), assetID: asset.id,
                        sourceOffsetSamples: 48_081).apply(to: &p)
        _ = try CreateTakeFolder(trackID: takes, takes: [
            .init(start: Tick(0), length: Tick(1_920), assetID: asset.id, sourceOffsetSamples: 1_001),
            .init(start: Tick(0), length: Tick(1_920), assetID: asset.id, sourceOffsetSamples: 96_003),
        ]).apply(to: &p)
        _ = try SetInstrument(trackID: keys, device: .builtin(.sampler),
                              zones: [SamplerZone(assetID: asset.id, loopStart: 4_801, loopEnd: 96_001),
                                      SamplerZone(assetID: asset.id, rootKey: 72)]).apply(to: &p)
        try p.validate()
        return p
    }

    /// `p` as `SetSessionSampleRate(rate)` leaves it.
    private func scaled(_ p: Project, to rate: Double) throws -> Project {
        var q = p
        _ = try SetSessionSampleRate(sampleRate: rate).apply(to: &q)
        return q
    }

    private func store(_ p: Project) -> ProjectStore {
        let store = ProjectStore(project: p)
        store.autosavePolicy = nil
        return store
    }

    private func gain(_ store: ProjectStore, _ track: Int = 0) -> Float { store.project.tracks[track].strip.gain }

    // MARK: DW-334: undo across a session-rate change

    @Test("DW-334 repro: split at 48 kHz, switch to 96 kHz, undo → the clip still starts 10 s into its file")
    func splitRepro() throws {
        let store = store(try Self.fixture())
        let clip = store.project.tracks[0].clips[0].id
        try store.perform(SplitClip(clipID: clip, at: Tick(960)))
        try store.perform(SetSessionSampleRate(sampleRate: 96_000))
        store.undo()
        guard case .audio(let restored) = try #require(store.project.tracks[0].clips.first(where: { $0.id == clip })) else {
            Issue.record("not an audio clip")
            return
        }
        // 10 s at 96 kHz; before T-112 undo wrote the 48 kHz value back (5 s).
        #expect(restored.sourceOffsetSamples == 960_000)
        #expect(store.project.tracks[0].clips.count == 2)
        #expect(store.canRedo, "the history is intact (no failed step cleared it)")
        try store.project.validate()
    }

    @Test("DW-334, MODEL-002: perform X, change the rate, undo/redo → the rescaled states (undo stack)",
          arguments: SnapshottingScenario.allCases, [96_000.0, 44_100])
    func undoAcrossRateChange(_ scenario: SnapshottingScenario, rate: Double) throws {
        let original = try Self.fixture()
        let store = store(original)
        try store.perform(scenario.command(in: original))
        let after = store.project
        try store.perform(SetSessionSampleRate(sampleRate: rate))
        #expect(store.canUndo)
        store.undo()
        #expect(store.project == (try scaled(original, to: rate)), "undo → the original at the new rate")
        #expect(store.canRedo)
        store.redo()
        #expect(store.project == (try scaled(after, to: rate)), "redo → X's result at the new rate")
        store.undo()
        #expect(store.project == (try scaled(original, to: rate)))
        try store.project.validate()
        if rate == 96_000 {
            // At an exact ratio, X done at the new rate (its own sample arguments rescaled too) gives
            // the same document as X then the change.
            var direct = try scaled(original, to: rate)
            _ = try scenario.command(in: direct).rescaled(from: 48_000, to: rate).apply(to: &direct)
            #expect(direct == (try scaled(after, to: rate)), "X at 96 kHz == X at 48 kHz, then 96 kHz")
        }
    }

    @Test("DW-334: perform X, undo, change the rate, redo/undo → the rescaled states (redo stack)",
          arguments: SnapshottingScenario.allCases, [96_000.0, 44_100])
    func redoAcrossRateChange(_ scenario: SnapshottingScenario, rate: Double) throws {
        let original = try Self.fixture()
        let store = store(original)
        try store.perform(scenario.command(in: original))
        let after = store.project
        store.undo()
        try store.perform(SetSessionSampleRate(sampleRate: rate))
        #expect(store.canRedo, "a history-exempt rate change keeps the redo stack")
        store.redo()
        #expect(store.project == (try scaled(after, to: rate)))
        store.undo()
        #expect(store.project == (try scaled(original, to: rate)))
        try store.project.validate()
    }

    @Test("DW-334: a rate change inside an open gesture (an engine-side change, DW-130) rescales the gesture's commands too")
    func rateChangeMidGesture() throws {
        let original = try Self.fixture()
        let store = store(original)
        store.beginGesture("Split")
        try store.perform(SplitClip(clipID: original.tracks[0].clips[0].id, at: Tick(960)))
        try store.perform(SetSessionSampleRate(sampleRate: 44_100))
        try store.perform(SplitClip(clipID: store.project.tracks[0].clips[1].id, at: Tick(1_920)))
        store.endGesture()
        store.undo()
        #expect(store.project == (try scaled(original, to: 44_100)))
    }

    @Test("DW-334: Command.rescaled is the identity by default and recurses through composites")
    func rescaledDefaults() throws {
        let rename = RenameTrack(trackID: 3, name: "x").rescaled(from: 48_000, to: 96_000)
        #expect((rename as? RenameTrack)?.name == "x")
        let clip = AudioClip(id: 9, assetID: 1, start: Tick(0), length: Tick(960), sourceOffsetSamples: 1_001)
        let composite = CompositeCommand("c", [RenameTrack(trackID: 3, name: "x"), SetClip(clip: .audio(clip))])
            .rescaled(from: 48_000, to: 96_000)
        let steps = try #require((composite as? CompositeCommand)?.commands)
        guard let set = steps[1] as? SetClip, case .audio(let scaled) = set.clip else {
            Issue.record("SetClip expected")
            return
        }
        #expect(scaled.sourceOffsetSamples == 2_002 && steps[0] is RenameTrack)
    }

    // MARK: DW-336: gesture owners

    @Test("DW-336 repro: a track added mid-\"Set Gain\" gesture by another owner survives one undo and gets its own entry",
          arguments: [GestureOwner.recording, .control, .pluginEditor, .automation])
    func nonOwnerGetsOwnEntry(_ other: GestureOwner) async throws {
        let store = store(Project())
        try store.perform(AddTrack(name: "T", kind: .audio))
        let track = store.project.tracks[0].id
        var changes = store.changeStream().makeAsyncIterator()

        store.beginGesture("Set Gain")
        try store.perform(SetParam(target: .strip(channel: track, param: .gain), value: 0.5))
        try store.perform(AddTrack(name: "Rec", kind: .audio), as: other)
        #expect(store.isGestureActive && store.hasOpenGesture(owner: .ui), "a non-owner's command doesn't end the gesture")
        #expect(!store.hasOpenGesture(owner: other))
        try store.perform(SetParam(target: .strip(channel: track, param: .gain), value: 0.25))
        store.endGesture()
        #expect(!store.isGestureActive)

        var causes: [(ProjectChange.Cause, String)] = []
        for _ in 0..<4 { if let c = await changes.next() { causes.append((c.cause, c.label)) } }
        #expect(causes.map(\.0) == [.gestureUpdate, .perform, .gestureUpdate, .gestureEnd])
        let setLabel = SetParam(target: .strip(channel: track, param: .gain), value: 0).label
        #expect(causes.map(\.1) == [setLabel, "Add Track", setLabel, "Set Gain"])

        #expect(store.undoLabel == "Set Gain")
        store.undo()
        #expect(gain(store) == 1, "the gesture is undone")
        #expect(store.project.tracks.map(\.name) == ["T", "Rec"], "the other owner's track survives")
        #expect(store.undoLabel == "Add Track")
        store.undo()
        #expect(store.project.tracks.map(\.name) == ["T"])
        store.redo()
        store.redo()
        #expect(gain(store) == 0.25 && store.project.tracks.count == 2)
    }

    @Test("DW-336: two owners' overlapping gestures are two entries, and one owner's end leaves the other's open")
    func overlappingOwners() throws {
        let store = store(Project())
        try store.perform(AddTrack(name: "A", kind: .audio))
        try store.perform(AddTrack(name: "B", kind: .audio))
        let (a, b) = (store.project.tracks[0].id, store.project.tracks[1].id)
        store.beginGesture("Gain A")
        store.beginGesture("Gain B", owner: .pluginEditor)
        store.beginGesture("nested", owner: .pluginEditor)
        try store.perform(SetParam(target: .strip(channel: a, param: .gain), value: 0.5))
        try store.perform(SetParam(target: .strip(channel: b, param: .gain), value: 0.5), as: .pluginEditor)
        store.endGesture(owner: .pluginEditor)
        #expect(store.hasOpenGesture(owner: .pluginEditor), "nesting within an owner works as before")
        store.endGesture(owner: .control)  // not open: does nothing
        store.endGesture(owner: .pluginEditor)
        #expect(!store.hasOpenGesture(owner: .pluginEditor) && store.hasOpenGesture(owner: .ui))
        #expect(store.undoLabel == "Gain B")
        try store.perform(SetParam(target: .strip(channel: a, param: .gain), value: 0.25))
        store.endGesture()
        #expect(store.undoLabel == "Gain A")
        store.undo()
        #expect(gain(store, 0) == 1 && gain(store, 1) == 0.5)
        store.undo()
        #expect(gain(store, 1) == 1)
    }

    @Test("DW-336: undo ends every owner's open gesture first (undo during a drag undoes the drag)")
    func undoEndsAllGestures() throws {
        let store = store(Project())
        try store.perform(AddTrack(name: "A", kind: .audio))
        let a = store.project.tracks[0].id
        store.beginGesture("Gain", owner: .pluginEditor)
        try store.perform(SetParam(target: .strip(channel: a, param: .gain), value: 0.5), as: .pluginEditor)
        store.undo()
        #expect(!store.isGestureActive && gain(store) == 1)
        #expect(store.undoLabel == "Add Track")
    }

    /// A store on a FakeEngine with an audio track carrying a VST3 insert (as PluginEditRecorderTests).
    private func pluginStore() throws -> (ProjectStore, FakeEngine, track: NodeIDValue, vst3: NodeIDValue) {
        let store = store(Project(name: "P"))
        let engine = FakeEngine()
        try store.attachEngine(engine, debounce: .zero)
        try store.perform(AddTrack(name: "Fx", kind: .audio))
        let track = store.project.tracks[0].id
        try store.perform(InsertDevice(channel: track, device: .vst3(VST3Descriptor(identifier: "/x.vst3#01", name: "X"))))
        return (store, engine, track, store.project.tracks[0].inserts[0].id)
    }

    private func post(_ engine: FakeEngine, _ store: ProjectStore, _ slot: NodeIDValue, _ phase: PluginParamEdit.Phase, _ value: Float = .nan) {
        engine.post(EngineEvent(pluginEdit: PluginParamEdit(index: 0, value: value, phase: phase), slot: slot))
        _ = store.engineSync?.pollEvents()
    }

    private func pluginParam(_ store: ProjectStore, _ slot: NodeIDValue) -> Float? {
        store.project.tracks[0].inserts.first { $0.id == slot }?.params.first { $0.index == 0 }?.value
    }

    @Test("DW-336: PluginEditRecorder neither adopts nor closes a UI gesture; a plugin gesture during a fader drag is its own entry")
    func pluginEditorDuringUIGesture() throws {
        let (store, engine, track, vst3) = try pluginStore()
        store.beginGesture("Set Gain")
        try store.perform(SetParam(target: .strip(channel: track, param: .gain), value: 0.5))
        post(engine, store, vst3, .begin)
        post(engine, store, vst3, .value, 0.3)
        post(engine, store, vst3, .end)
        #expect(store.hasOpenGesture(owner: .ui), "the plugin's end doesn't close the UI's gesture")
        #expect(!store.hasOpenGesture(owner: .pluginEditor))
        #expect(store.undoLabel == PluginEditRecorder.label, "the plugin gesture is its own entry")
        // An ungestured plugin value (a preset) while the UI drags is its own entry as well.
        post(engine, store, vst3, .value, 0.4)
        _ = store.engineSync?.pollEvents()
        try store.perform(SetParam(target: .strip(channel: track, param: .gain), value: 0.25))
        store.endGesture()
        #expect(store.undoLabel == "Set Gain")
        store.undo()
        #expect(gain(store) == 1 && pluginParam(store, vst3) == 0.4, "undoing the drag keeps the plugin's edits")
        store.undo()
        #expect(pluginParam(store, vst3) == 0.3)
        store.undo()
        #expect(pluginParam(store, vst3) == nil)
    }

    @Test("DW-336: a UI drag during an open plugin gesture: the UI's end doesn't close the plugin's gesture")
    func uiGestureDuringPluginGesture() throws {
        let (store, engine, track, vst3) = try pluginStore()
        post(engine, store, vst3, .begin)
        post(engine, store, vst3, .value, 0.3)
        store.beginGesture("Set Gain")
        try store.perform(SetParam(target: .strip(channel: track, param: .gain), value: 0.5))
        store.endGesture()
        #expect(store.hasOpenGesture(owner: .pluginEditor) && store.undoLabel == "Set Gain")
        post(engine, store, vst3, .value, 0.6)
        post(engine, store, vst3, .end)
        #expect(!store.isGestureActive && store.undoLabel == PluginEditRecorder.label)
        store.undo()
        #expect(pluginParam(store, vst3) == nil && gain(store) == 0.5)
    }

    @Test("DW-336: a recording finished during a UI gesture is its own \"Record\" entry")
    func recordingImportDuringGesture() throws {
        let store = store(Project())
        try store.perform(AddTrack(name: "Mic", kind: .audio))
        let mic = store.project.tracks[0].id
        store.beginGesture("Set Gain")
        try store.perform(SetParam(target: .strip(channel: mic, param: .gain), value: 0.5))
        let take = RecordedTake(track: mic, file: "/tmp/rec/Mic Take 1.caf", startSample: 0, frames: 48_000, sampleRate: 48_000)
        let asset = try #require(try store.importRecording(take))
        #expect(store.hasOpenGesture(owner: .ui))
        store.endGesture()
        store.undo()
        #expect(gain(store) == 1 && store.project.asset(asset) != nil && store.project.tracks[0].clips.count == 1)
    }

    // MARK: DW-337: dirty past the undo cap

    @Test("DW-337: undoing everything left after the cap trimmed entries still reports dirty")
    func dirtyPastCap() throws {
        let store = ProjectStore(project: Project(), undoLimit: 3)
        store.autosavePolicy = nil
        for i in 0..<5 { try store.perform(AddTrack(name: "\(i)", kind: .audio)) }
        while store.canUndo { store.undo() }
        #expect(store.project.tracks.count == 2, "two entries were trimmed")
        #expect(store.isDirty, "not the opened state: two tracks remain")
        while store.canRedo { store.redo() }
        #expect(store.isDirty)

        // Saved at the top, undone to the trimmed bottom and redone: dirty, then clean.
        store.markClean()
        #expect(!store.isDirty)
        while store.canUndo { store.undo() }
        #expect(store.isDirty)
        while store.canRedo { store.redo() }
        #expect(!store.isDirty)

        // Within the cap nothing changes: undoing everything returns to the clean start.
        let small = ProjectStore(project: Project(), undoLimit: 3)
        small.autosavePolicy = nil
        for i in 0..<3 { try small.perform(AddTrack(name: "\(i)", kind: .audio)) }
        while small.canUndo { small.undo() }
        #expect(!small.isDirty)
    }

    @Test("DW-337: UndoStack's marker at the trimmed bottom isn't the empty project's")
    func baseSerial() throws {
        var stack = UndoStack(limit: 2)
        var p = Project()
        #expect(stack.stateMarker == 0)
        for i in 0..<3 { try stack.perform(AddTrack(name: "\(i)", kind: .audio), on: &p) }
        while stack.canUndo { try stack.undo(&p) }
        #expect(stack.stateMarker != 0)
        let bottom = stack.stateMarker
        try stack.redo(&p)
        try stack.undo(&p)
        #expect(stack.stateMarker == bottom)
        stack.removeAll()
        #expect(stack.stateMarker != bottom && stack.stateMarker != 0, "dropped history: a state of its own")
    }

    // MARK: DW-338: save mid-gesture

    @Test("DW-338: save mid-gesture with changes writes the mid-gesture project and leaves the store dirty")
    func saveMidGesture() async throws {
        let temp = try TempFolder("t112")
        defer { temp.remove() }
        let folder = temp.url.appending(path: "P.dawproject")
        let store = store(Project(name: "p"))
        try store.perform(AddTrack(name: "T", kind: .audio))
        let track = store.project.tracks[0].id
        try await store.save(to: folder)
        #expect(!store.isDirty)

        // Without gesture changes the save is as before.
        store.beginGesture("Set Gain")
        try await store.save(to: nil)
        #expect(!store.isDirty)
        try store.perform(SetParam(target: .strip(channel: track, param: .gain), value: 0.5))
        try await store.save(to: nil)
        #expect(store.isDirty, "the file holds the gesture's values so far, no undo position")
        let saved = try ProjectFile.decode(Data(contentsOf: folder.appending(path: "project.json"))).project
        #expect(saved.tracks[0].strip.gain == 0.5)
        store.endGesture()
        #expect(store.isDirty)
        store.undo()
        #expect(store.isDirty, "undoing the gesture (gain 1) doesn't match the file (0.5)")
        store.redo()
        try await store.save(to: nil)
        #expect(!store.isDirty)
        store.undo()
        #expect(store.isDirty)
    }

    // MARK: DW-335: Save As autosave race

    @Test("DW-335, MODEL-044: an edit made during Save As is autosaved into the new folder; the old folder's autosave is removed on the queue",
          .timeLimit(.minutes(1)))
    func saveAsAutosave() async throws {
        let temp = try TempFolder("t112")
        defer { temp.remove() }
        let old = temp.url.appending(path: "A.dawproject"), new = temp.url.appending(path: "B.dawproject")
        let oldAutosave = old.appending(path: "autosave/project.json"), newAutosave = new.appending(path: "autosave/project.json")
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        let store = ProjectStore(project: Project(name: "p"))
        // Autosaves are called by hand (the debounce never fires during the test).
        store.autosavePolicy = AutosavePolicy(interval: .seconds(3600), debounce: .seconds(3600))
        try await store.save(to: old)
        try store.perform(AddTrack(name: "before", kind: .audio))
        try await store.autosave()
        #expect(exists(oldAutosave))

        let gate = SaveGate()
        store.afterSaveIO = { await gate.pass() }
        await gate.arm()
        let saving = Task { try await store.save(to: new) }
        await gate.waitUntilParked()  // the new folder is written; the save hasn't resumed yet
        #expect(!exists(oldAutosave), "the old folder's autosave goes on the queue, right after the save")
        try store.perform(AddTrack(name: "during", kind: .audio))
        let ticket = store.autosaveTicket
        let autosaving = Task { try await store.autosave() }
        while store.autosaveTicket == ticket { await Task.yield() }  // queued behind the save
        await gate.release()
        try await saving.value
        try await autosaving.value  // its write ran on the queue after the save

        #expect(store.folderURL == new && store.isDirty)
        #expect(!exists(oldAutosave), "nothing was written into the old folder")
        let autosaved = try ProjectFile.decode(Data(contentsOf: newAutosave)).project
        #expect(autosaved.tracks.map(\.name) == ["before", "during"])
        let main = try ProjectFile.decode(Data(contentsOf: new.appending(path: "project.json"))).project
        #expect(main.tracks.map(\.name) == ["before"])
        await store.close()
        #expect(!exists(newAutosave))
    }

    // MARK: DW-339: ID reservation

    @Test("DW-339: reserveID hands out an ID later allocations skip, ImportAsset claims it, and it isn't an edit")
    func reserveID() throws {
        let store = store(Project())
        try store.perform(AddTrack(name: "Mic", kind: .audio))
        let mic = store.project.tracks[0].id
        store.markClean()
        let undoDepth = store.undoLabel

        let reserved = store.reserveID()
        #expect(!store.isDirty && store.undoLabel == undoDepth)
        // A recording finished while the reserved asset loads gets other IDs.
        let take = RecordedTake(track: mic, file: "/tmp/rec/Mic Take 1.caf", startSample: 0, frames: 48_000, sampleRate: 48_000)
        let recorded = try #require(try store.importRecording(take))
        #expect(recorded != reserved)
        #expect(!store.project.tracks[0].clips.contains { $0.id == reserved })
        try store.perform(ImportAsset(asset: AssetRef(id: reserved, path: "/tmp/b.wav", channels: 2, originalSampleRate: 48_000,
                                                      frames: 48_000)))
        #expect(Set(store.project.assets.map(\.id)) == [recorded, reserved])
        try store.project.validate()
        let second = store.reserveID()
        #expect(second > reserved && second > recorded)
    }
}
