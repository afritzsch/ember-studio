import DAWControl
import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// T-093 (DW-216): the MIDI input picker in a MIDI track's header (and so on its mixer strip,
// DW-202), `ui.state` tracks' `midiInput`, and picking through `ui.perform`.

@MainActor
@Suite("MIDI input picker (T-093, DW-216)", .serialized)
struct TrackMidiInputUITests {
    private func midiWindow() throws -> (ProjectWindowModel, FakeEngine, NodeIDValue, NodeIDValue) {
        let (window, engine) = try makeWindow(tracks: ["Gtr"])
        window.perform(AddTrack(name: "Keys", kind: .midi))
        engine.setMidiInputs([
            MidiInputInfo(uniqueID: 7, name: "Keystation", connected: true),
            MidiInputInfo(uniqueID: 8, name: "Pads", connected: false),
        ])
        window.refreshMidiInputs(force: true)
        return (window, engine, window.project.tracks[0].id, window.project.tracks[1].id)
    }

    @Test("DW-216: a MIDI track lists All Inputs, the engine's sources and channels Omni…16; audio tracks have no picker")
    func lists() throws {
        let (window, _, gtr, keys) = try midiWindow()
        #expect(window.trackHeaders[0].midiInputMenu == nil)
        #expect(!window.controls.contains { $0.id.hasPrefix("track.\(gtr).midiInput") })
        let menu = try #require(window.trackHeaders[1].midiInputMenu)
        #expect(menu.sourceControls.map(\.id) == ["track.\(keys).midiInput.source.all", "track.\(keys).midiInput.source.7",
                                                  "track.\(keys).midiInput.source.8"])
        #expect(menu.sourceControls.map(\.label) == ["MIDI Input All Inputs", "MIDI Input Keystation",
                                                     "MIDI Input Pads (not connected)"])
        #expect(menu.channelControls.map(\.id) == (0...16).map { "track.\(keys).midiInput.channel.\($0)" })
        #expect(menu.channelControls[0].label == "MIDI Channel Omni" && menu.channelControls[16].label == "MIDI Channel 16")
        #expect(try window.control("track.\(keys).midiInput.source.all").isOn == true)
        #expect(try window.control("track.\(keys).midiInput.channel.0").isOn == true)
        #expect(menu.title == "All" && menu.fullTitle == "All Inputs · Omni" && menu.connected)
    }

    @Test("DW-298: compact picker titles (All, Ch 3, Keystation, Keystation · Ch 3, ⚠ for not connected); the full name is the tooltip")
    func compactTitles() throws {
        let (window, _, _, keys) = try midiWindow()
        func menu() throws -> TrackMidiInputMenu { try #require(window.trackHeaders[1].midiInputMenu) }
        window.perform(SetTrackMidiInput(trackID: keys, source: .all, channel: 3))
        #expect(try menu().title == "Ch 3" && menu().fullTitle == "All Inputs · Ch 3")
        window.perform(SetTrackMidiInput(trackID: keys, source: .device(7), channel: 0))
        #expect(try menu().title == "Keystation" && menu().fullTitle == "Keystation · Omni")
        window.perform(SetTrackMidiInput(trackID: keys, source: .device(7), channel: 16))
        #expect(try menu().title == "Keystation · Ch 16")
        window.perform(SetTrackMidiInput(trackID: keys, source: .device(8), channel: 0))
        #expect(try menu().title == "⚠ Pads" && menu().fullTitle == "Pads · Omni (not connected)")
    }

    @Test("DW-216, MODEL-005: picking a source and a channel performs SetTrackMidiInput (undoable) and reaches the engine")
    func picking() throws {
        let (window, engine, _, keys) = try midiWindow()
        try window.control("track.\(keys).midiInput.source.7").action()
        #expect(window.project.tracks[1].midiInput == Track.MidiInput(source: .device(7), channel: 0))
        #expect(window.store.undoLabel == "Set MIDI Input")
        try window.control("track.\(keys).midiInput.channel.3").action()
        #expect(window.project.tracks[1].midiInput == Track.MidiInput(source: .device(7), channel: 3), "the source stays")
        #expect(engine.midiInputFilters[keys] == Track.MidiInput(source: .device(7), channel: 3))
        #expect(try window.control("track.\(keys).midiInput.source.7").isOn == true)
        #expect(try window.control("track.\(keys).midiInput.channel.3").isOn == true)
        #expect(try window.control("track.\(keys).midiInput.channel.0").isOn == false)
        #expect(window.trackHeaders[1].midiInputMenu?.title == "Keystation · Ch 3")

        // Picking the current entry again is no edit.
        let undo = window.store.undoLabel
        window.store.undo()
        #expect(window.project.tracks[1].midiInput.channel == 0)
        window.store.redo()
        try window.control("track.\(keys).midiInput.channel.3").action()
        #expect(window.store.canUndo && window.store.undoLabel == undo)

        // The mixer strip shows the header's controls (DW-202).
        let strip = try #require(window.mixer.strips.first { $0.id == keys })
        #expect(strip.allControlIDs.contains("track.\(keys).midiInput.channel.3"))
    }

    @Test("DW-216: a source that isn't connected keeps the selection and shows as not connected")
    func notConnected() throws {
        let (window, engine, _, keys) = try midiWindow()
        window.perform(SetTrackMidiInput(trackID: keys, source: .device(99), channel: 2))
        var menu = try #require(window.trackHeaders[1].midiInputMenu)
        #expect(!menu.connected && menu.sourceName == "Source 99")
        #expect(menu.title == "⚠ Source 99 · Ch 2")
        #expect(try window.control("track.\(keys).midiInput.source.99").label == "MIDI Input Source 99 (not connected)")
        #expect(try window.control("track.\(keys).midiInput.source.99").isOn == true)

        // A listed but disconnected source (Pads) keeps its name.
        try window.control("track.\(keys).midiInput.source.8").action()
        menu = try #require(window.trackHeaders[1].midiInputMenu)
        #expect(!menu.connected && menu.title == "⚠ Pads · Ch 2")
        // It comes back: connected, nothing to pick again.
        engine.setMidiInputs([MidiInputInfo(uniqueID: 8, name: "Pads", connected: true)])
        window.refreshMidiInputs(force: true)
        #expect(window.trackHeaders[1].midiInputMenu?.connected == true)
        #expect(window.project.tracks[1].midiInput == Track.MidiInput(source: .device(8), channel: 2))
    }

    @Test("UI-050: ui.state tracks and mixer strips carry midiInput {source, channel, name, connected} (null for audio)")
    func uiState() throws {
        let (window, _, _, keys) = try midiWindow()
        window.perform(SetTrackMidiInput(trackID: keys, source: .device(7), channel: 10))
        let tracks = UIStateDumper.dump(window, isMain: true)["tracks"]
        #expect(tracks?[0]?["midiInput"] == .null)
        #expect(tracks?[1]?["midiInput"] == ["source": "7", "channel": 10, "name": "Keystation", "connected": true])
        window.bottomPane = .mixer
        let strips = UIStateDumper.dump(window, isMain: true)["mixer"]?["strips"]?.arrayValue ?? []
        let strip = strips.first { $0["id"] == .int(Int64(keys)) }
        #expect(strip?["midiInput"]?["channel"] == 10)
    }

    @Test("UI-052: ui.perform picks a MIDI track's source and channel by id; ui.state reports it")
    func uiPerform() async throws {
        let t = TestApp()
        let window = t.app.newProject()
        window.perform(AddTrack(name: "Keys", kind: .midi))
        let keys = window.project.tracks[0].id
        let d = t.app.dispatcher
        #expect(try await d.call(.uiPerform, ["accessibilityId": .string("track.\(keys).midiInput.channel.5"), "action": "on"])["isOn"] == true)
        #expect(window.project.tracks[0].midiInput == Track.MidiInput(source: .all, channel: 5))
        let state = try await d.call(.uiState)
        #expect(state["windows"]?[0]?["tracks"]?[0]?["midiInput"]?["channel"] == 5)
        #expect(state["windows"]?[0]?["tracks"]?[0]?["midiInput"]?["source"] == "all")
        _ = try await d.call(.uiPerform, ["accessibilityId": "edit.undo", "action": "click"])
        #expect(window.project.tracks[0].midiInput == .default)
        await t.app.quit()
    }
}
