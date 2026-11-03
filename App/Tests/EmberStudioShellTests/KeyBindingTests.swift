import DAWControl
import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// UI-002: the keyboard shortcuts, tested through the view model (12's acceptance: "Keybinding test
// via view model"). `ProjectWindowModel.handleKey` is what `KeyMonitor` calls for a key event in a
// project window; each chord runs the window control (UI-052) its button and `ui.perform` run.

@MainActor
private func press(_ model: ProjectWindowModel, _ chord: KeyChord, repeat isRepeat: Bool = false) -> Bool {
    model.handleKey(chord, isRepeat: isRepeat)
}

/// The transport state a stand-in realtime engine has applied so far.
@MainActor
private final class AppliedTransport {
    var state = TransportState()
}

@MainActor
@Suite("Keyboard shortcuts (UI-002)")
struct KeyBindingTests {
    @Test("UI-002: Space plays and stops; R arms the transport's record state; held keys don't repeat them")
    func transportKeys() throws {
        let (model, engine) = try makeWindow()
        #expect(press(model, KeyChord(.space)))
        #expect(model.transport.playing && engine.transport().playing)
        #expect(try model.control("transport.playStop").label == "Stop")
        #expect(!press(model, KeyChord(.space), repeat: true), "a held Space doesn't toggle again")
        #expect(engine.transport().playing)
        #expect(press(model, KeyChord(.space)))
        #expect(!model.transport.playing && !engine.transport().playing)

        #expect(press(model, KeyChord("r")))
        #expect(engine.transport().recording && model.transport.recording)
        #expect(try model.control("transport.record").isOn == true)
        #expect(press(model, KeyChord("r")))
        #expect(!engine.transport().recording)
        #expect(engine.calls.filter { if case .setRecording = $0 { true } else { false } }.count == 2)
        #expect(!model.store.canUndo, "arming record isn't a document edit")
    }

    @Test("UI-002: a quick second Space/R acts on what was asked, not on a realtime transport that hasn't applied it yet")
    func pendingTransport() throws {
        let (model, engine) = try makeWindow()
        // A realtime engine applies transport commands at its next block; until then it reads as before.
        let applied = AppliedTransport()
        model.readTransport = { _ in applied.state }
        #expect(press(model, KeyChord("r")))
        #expect(engine.transport().recording && !model.transport.recording, "asked, not applied yet")
        #expect(model.isRecording && model.requestedRecording == true)
        #expect(try model.control("transport.record").isOn == true)
        #expect(press(model, KeyChord("r")), "the second R disarms instead of arming again")
        #expect(!model.isRecording && engine.calls.last == .setRecording(false))

        #expect(press(model, KeyChord(.space)))
        #expect(model.isPlaying && !model.transport.playing)
        #expect(try model.control("transport.playStop").label == "Stop" && !model.control("transport.play").isEnabled)
        applied.state.playing = true  // the block arrives
        model.pollTransport()
        #expect(model.requestedPlaying == nil && model.isPlaying)

        #expect(press(model, KeyChord(.space)))
        for _ in 0...ProjectWindowModel.pendingPollLimit { model.pollTransport() }
        #expect(model.requestedPlaying == nil && model.isPlaying,
                "an engine that never applies a request doesn't pin it: the engine's state wins again")
    }

    @Test("UI-002: L makes a loop (4 bars from the playhead's bar, or around the selected clips) and toggles it through SetLoop")
    func loopKey() throws {
        let (model, engine) = try makeWindow(tracks: ["A"])
        engine.locate(Tick(2 * 3840 + 100))  // inside bar 3 at 4/4
        model.pollTransport()
        engine.clearCalls()
        #expect(press(model, KeyChord("l")))
        #expect(model.project.loop == LoopRange(start: Tick(2 * 3840), end: Tick(6 * 3840), isEnabled: true))
        #expect(model.store.undoLabel == "Set Loop" && model.loopEnabled)
        #expect(try model.control("transport.loop").isOn == true)
        #expect(engine.calls.contains(.setLoop(enabled: true, start: Tick(2 * 3840), end: Tick(6 * 3840))),
                "engine sync gives the transport the project's loop (DW-123)")

        #expect(press(model, KeyChord("l")))
        #expect(model.project.loop == LoopRange(start: Tick(2 * 3840), end: Tick(6 * 3840), isEnabled: false),
                "turning it off keeps the region")
        #expect(engine.calls.contains(.setLoop(enabled: false, start: Tick(2 * 3840), end: Tick(6 * 3840))))
        #expect(press(model, KeyChord("l")))
        #expect(model.loopEnabled)

        // With clips selected and no loop yet, the loop spans them.
        let (other, _) = try makeWindow()
        try other.store.perform(AddTrack(name: "M", kind: .midi))
        let track = other.project.tracks[0].id
        try other.store.perform(AddClip(trackID: track, start: Tick(960), length: Tick(1920)))
        try other.store.perform(AddClip(trackID: track, start: Tick(7680), length: Tick(960)))
        other.selectedClips = Set(other.project.tracks[0].clips.map(\.id))
        #expect(press(other, KeyChord("l")))
        #expect(other.project.loop == LoopRange(start: Tick(960), end: Tick(8640), isEnabled: true))
    }

    @Test("UI-002: ⌘Z / ⇧⌘Z undo and redo; ⌘T / ⇧⌘T add an audio / MIDI track and select it")
    func editAndTrackKeys() throws {
        let (model, _) = try makeWindow(tracks: ["A"])
        #expect(press(model, KeyChord("t", .command)))
        #expect(model.project.tracks.map(\.name) == ["A", "Audio 2"])
        #expect(model.project.tracks[1].kind == .audio && model.selectedTracks == [model.project.tracks[1].id])
        #expect(press(model, KeyChord("t", [.command, .shift])))
        #expect(model.project.tracks.map(\.name) == ["A", "Audio 2", "MIDI 1"] && model.project.tracks[2].kind == .midi)
        #expect(model.selectedTracks == [model.project.tracks[2].id])

        #expect(press(model, KeyChord("z", .command)))
        #expect(model.project.tracks.map(\.name) == ["A", "Audio 2"])
        #expect(press(model, KeyChord("z", [.command, .shift])))
        #expect(model.project.tracks.map(\.name) == ["A", "Audio 2", "MIDI 1"])
        #expect(!press(model, KeyChord("z", [.command, .shift])), "nothing to redo: the disabled control doesn't run")
    }

    @Test("UI-002, DW-165: ⌘E splits the selected clips at the playhead; ⌫ deletes the selection; each one undo entry")
    func splitAndDeleteKeys() throws {
        let (model, engine, asset) = try makeArrange()
        let clip = try model.addAudioClip(track: 0, start: 0, asset: asset)
        #expect(!press(model, KeyChord("e", .command)), "nothing selected: edit.split is disabled")
        model.selectedClips = [clip]
        engine.locate(1920)
        #expect(press(model, KeyChord("e", .command)))
        #expect(model.project.tracks[0].clips.map(\.length.raw) == [1920, 1920])
        #expect(model.store.undoLabel == "Split" && model.selectedClips.count == 2)

        #expect(press(model, KeyChord(.delete)))
        #expect(model.project.tracks[0].clips.isEmpty && model.selectedClips.isEmpty)
        #expect(model.store.undoLabel == "Delete Clips")
        #expect(!press(model, KeyChord(.delete)), "nothing left to delete")
        model.store.undo()
        #expect(model.project.tracks[0].clips.count == 2)

        model.selectedClips = [model.project.tracks[0].clips[0].id]
        #expect(press(model, KeyChord("d", .command)), "UI-013's ⌘D goes through the same table")
        #expect(model.project.tracks[0].clips.count == 3)
    }

    @Test("UI-002: ⌘+ (also ⌘= and the keypad) zooms in, ⌘− zooms out; zoom keys repeat while held")
    func zoomKeys() throws {
        let (model, _) = try makeWindow()
        let start = model.pixelsPerBeat
        #expect(press(model, try #require(KeyChord(characters: "+", modifiers: [.command, .shift]))))
        #expect(model.pixelsPerBeat == start * ProjectWindowModel.zoomStep)
        #expect(press(model, try #require(KeyChord(characters: "=", modifiers: .command)), repeat: true))
        #expect(model.pixelsPerBeat == start * ProjectWindowModel.zoomStep * ProjectWindowModel.zoomStep)
        #expect(press(model, try #require(KeyChord(characters: "-", modifiers: .command))))
        #expect(press(model, try #require(KeyChord(characters: "-", modifiers: .command))))
        #expect(abs(model.pixelsPerBeat - start) < 1e-9)
    }

    @Test("UI-002: unbound chords and stray modifiers aren't handled, so the event goes on")
    func unbound() throws {
        let (model, _) = try makeWindow(tracks: ["A"])
        #expect(!press(model, KeyChord("q")))
        #expect(!press(model, KeyChord("r", .command)), "⌘R isn't R")
        #expect(!press(model, KeyChord(.space, .option)))
        #expect(!model.transport.playing && !model.transport.recording && model.project.tracks.count == 1)
    }

    @Test("UI-002: key events normalize to chords (letters keep ⇧, symbols carry it, both deletes, no function keys)")
    func chordNormalization() {
        #expect(KeyChord(characters: "T", modifiers: [.command, .shift]) == KeyChord("t", [.command, .shift]))
        #expect(KeyChord(characters: "+", modifiers: [.command, .shift]) == KeyChord("+", .command))
        #expect(KeyChord(characters: " ", modifiers: []) == KeyChord(.space))
        #expect(KeyChord(characters: "\u{7F}", modifiers: []) == KeyChord(.delete))
        #expect(KeyChord(characters: "\u{F728}", modifiers: []) == KeyChord(.delete), "forward delete")
        #expect(KeyChord(characters: "\u{F702}", modifiers: []) == nil, "← is a function key")
        #expect(KeyChord(characters: "", modifiers: []) == nil)
        #expect(KeyChord("t", [.command, .shift]).description == "⇧⌘T")
        #expect(KeyChord(.space).description == "Space" && KeyChord(.delete).description == "⌫")
    }

    @Test("UI-002, UI-052: every binding names a control the window has; chords are unique")
    func tableMatchesControls() throws {
        let (model, _, asset) = try makeArrange()
        model.selectedClips = [try model.addAudioClip(track: 0, start: 0, asset: asset)]
        let ids = Set(model.controls.map(\.id))
        for binding in KeyBindings.all {
            #expect(ids.contains(binding.controlID), "\(binding.chord) → \(binding.controlID)")
        }
        #expect(Set(KeyBindings.all.map(\.chord)).count == KeyBindings.all.count)
        for required in ["transport.playStop", "transport.record", "transport.loop", "edit.undo", "edit.redo", "track.add.audio",
                         "track.add.midi", "edit.split", "edit.delete", "zoom.in", "zoom.out"] {
            #expect(KeyBindings.chord(for: required) != nil, "\(required) has a shortcut")
        }
    }
}

@MainActor
@Suite("Toolbar (12 Layout, UI-002)")
struct ToolbarTests {
    @Test("Position (bars and time), tempo and signature follow the playhead and the tempo map")
    func readouts() throws {
        let (model, engine) = try makeWindow()
        #expect(model.positionBBT == "1.1.000" && model.positionTime == "0:00.000")
        #expect(model.tempo == 120 && model.signature == "4/4")

        engine.locate(Tick(3840 + 960 + 120))  // bar 2, beat 2, tick 120 at 4/4; 2.5625 beats … at 120 bpm
        model.pollTransport()
        #expect(model.positionBBT == "2.2.120")
        #expect(model.positionTime == "0:02.562")

        try model.store.perform(SetTimeSignature(tick: Tick(0), numerator: 3, denominator: 4))
        try model.store.perform(SetTempoEvent(tick: Tick(0), bpm: 60))
        #expect(model.signature == "3/4" && model.tempo == 60)
        #expect(model.positionBBT == "2.3.120", "3/4: bar 2 starts at beat 3")
        #expect(model.positionTime == "0:05.125")
    }

    @Test("ui.state carries the toolbar readouts, the loop and the key bindings")
    func uiState() throws {
        let (model, _) = try makeWindow()
        model.toggleLoop()
        let json = UIStateDumper.dump(model, isMain: true)
        let data = try JSONEncoder().encode(json)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let toolbar = try #require(object["toolbar"] as? [String: Any])
        #expect(toolbar["position"] as? String == "1.1.000" && toolbar["signature"] as? String == "4/4")
        #expect(toolbar["tempo"] as? Double == 120)
        let loop = try #require(toolbar["loop"] as? [String: Any])
        #expect(loop["enabled"] as? Bool == true && loop["start"] as? Int == 0 && loop["end"] as? Int == 4 * 3840)
        let bindings = try #require(object["keyBindings"] as? [[String: String]])
        #expect(bindings.contains(["keys": "⌘E", "control": "edit.split"]))
        #expect(bindings.contains(["keys": "Space", "control": "transport.playStop"]))
    }

    @Test("TIME-010: the metronome button toggles project.metronome through SetMetronome: dirty, no undo entry, no rebuild")
    func metronome() throws {
        let (model, engine) = try makeWindow()
        #expect(!model.store.isDirty && !model.store.canUndo)
        #expect(try model.control("transport.metronome").isOn == false)
        let graphs = engine.appliedGraphs.count
        engine.clearCalls()

        try model.control("transport.metronome").action()
        #expect(model.project.metronome.enabled && model.metronomeEnabled)
        #expect(try model.control("transport.metronome").isOn == true)
        #expect(model.store.isDirty, "persisted, so the project is edited")
        #expect(!model.store.canUndo, "SetMetronome stays out of undo history: ⌘Z never toggles the click")
        #expect(engine.appliedGraphs.count == graphs, "a slot write, not a rebuild (MODEL-021)")
        #expect(engine.calls.contains { if case .setParam = $0 { true } else { false } })

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(UIStateDumper.dump(model, isMain: true))) as? [String: Any]
        #expect((json?["toolbar"] as? [String: Any])?["metronome"] as? Bool == true)

        try model.control("transport.metronome").action()
        #expect(!model.project.metronome.enabled && !model.store.canUndo)
        #expect(KeyBindings.chord(for: "transport.metronome") == nil, "12 names no shortcut for it")
    }

    @Test("Without an engine the transport controls are disabled and the keys fall through")
    func noEngine() throws {
        let store = ProjectStore(project: Project(name: "No engine"))
        store.autosavePolicy = nil
        let model = ProjectWindowModel(id: 1, store: store)
        #expect(try !model.control("transport.playStop").isEnabled && !model.control("transport.record").isEnabled)
        #expect(!model.handleKey(KeyChord(.space)) && !model.handleKey(KeyChord("r")))
        #expect(model.handleKey(KeyChord("l")), "the loop is the project's; it doesn't need an engine")
    }
}
