import DAWControl
import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// UI-067 (T-124, 13 "Contract delta (T-124)"): the browser through attach mode: `ui.state`
// windows carry `browser`; `ui.perform` selects, expands, searches, loads and drops items.

@MainActor
@Suite("Browser in attach mode (UI-067)", .serialized)
struct BrowserAttachTests {
    let temp: TempDir
    let root: URL

    init() throws {
        temp = try TempDir()
        root = temp.url.appending(path: "Sounds", directoryHint: .isDirectory)
        for file in ["Drums/kick.wav", "Drums/snare.wav", "pad.aif", "riff.mid"] {
            let url = root.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        }
    }

    private func app() -> TestApp {
        let t = TestApp()
        t.app.browserLibrary = BrowserLibrary(settingsURL: temp.file("Browser.json"), watchesFileSystem: false)
        return t
    }

    private func browserState(_ d: Dispatcher) async throws -> JSONValue {
        let state = try await d.call(.uiState)
        return try #require(state["windows"]?[0]?["browser"])
    }

    private func perform(_ d: Dispatcher, _ params: JSONValue) async throws -> JSONValue {
        try await d.call(.uiPerform, params)
    }

    @Test("UI-067: ui.state browser {open, sidebar, selection, query, items (stable ids), searching, places, controls}; ui.perform adds a place, selects, expands, searches")
    func stateAndPerform() async throws {
        let t = app()
        let window = t.app.newProject()
        let d = t.app.dispatcher
        var state = try await browserState(d)
        #expect(state["open"] == true && state["sidebar"] == "currentProject" && state["selection"] == .null)
        #expect(state["items"] == [] && state["places"] == [] && state["searching"] == false && state["moreResults"] == false)
        #expect(state["sidebarItems"]?.arrayValue?.map { $0["key"] } == ["samples", "midiFiles", "currentProject"])

        // Add Folder… with a path: no open panel.
        let add = try await perform(d, ["accessibilityId": "browser.places.add", "action": "click", "text": .string(root.path)])
        #expect(add["kind"] == "button")
        state = try await browserState(d)
        let placeID = BrowserItem.id(forPath: root.standardizedFileURL.path)
        #expect(state["places"] == [["id": .string(placeID), "name": "Sounds", "path": .string(root.standardizedFileURL.path), "missing": false]])
        #expect(state["sidebar"] == .string("place.\(placeID)"))
        #expect(state["items"]?.arrayValue?.map { $0["name"] } == ["Drums", "pad.aif", "riff.mid"], "read before ui.perform returned")
        let drums = try #require(state["items"]?[0])
        let drumsID = try #require(drums["id"]?.stringValue)
        #expect(drumsID == BrowserItem.id(forPath: BrowserItem.canonical(root.appending(path: "Drums")).path), "from the path")
        #expect(drums["kind"] == "folder" && drums["expanded"] == false && drums["control"] == .string("browser.item.\(drumsID)"))
        let controls = (state["controls"]?.arrayValue ?? []).compactMap { $0.stringValue }
        #expect(!controls.isEmpty)
        #expect(controls.contains("browser.search") && controls.contains("browser.sidebar.samples"))
        #expect(controls.contains("browser.item.\(drumsID).expand") && controls.contains("browser.place.\(placeID).remove"))
        for id in controls {
            #expect(id.wholeMatch(of: /browser(\.[A-Za-z0-9]+)+/) != nil, "\(id)")
        }

        #expect(try await perform(d, ["accessibilityId": .string("browser.item.\(drumsID).expand"), "action": "on"])["isOn"] == true)
        _ = try await perform(d, ["accessibilityId": .string("browser.item.\(drumsID)"), "action": "click"])
        state = try await browserState(d)
        #expect(state["items"]?.arrayValue?.map { $0["name"] } == ["Drums", "kick.wav", "snare.wav", "pad.aif", "riff.mid"])
        #expect(state["items"]?[1]?["depth"] == 1 && state["selection"] == .string(drumsID) && state["items"]?[0]?["selected"] == true)
        #expect(window.browser.selection == drumsID)

        let search = try await perform(d, ["accessibilityId": "browser.search", "action": "setText", "text": "SN"])
        #expect(search["results"] == 1 && search["text"] == "SN" && search["moreResults"] == false)
        state = try await browserState(d)
        #expect(state["query"] == "SN" && state["searching"] == false && state["items"]?.arrayValue?.map { $0["name"] } == ["snare.wav"])
        _ = try await perform(d, ["accessibilityId": "browser.search", "action": "setText", "text": ""])
        #expect(try await browserState(d)["itemCount"] == 5, "the tree again, still expanded")

        _ = try await perform(d, ["accessibilityId": "browser.sidebar.midiFiles", "action": "click"])
        state = try await browserState(d)
        #expect(state["sidebar"] == "midiFiles" && state["items"]?.arrayValue?.map { $0["name"] } == ["riff.mid"])

        // Errors: an unknown browser id, a bad action, drop without a tick.
        await #expect(throws: (any Error).self) { try await perform(d, ["accessibilityId": "browser.item.nope", "action": "click"]) }
        await #expect(throws: (any Error).self) { try await perform(d, ["accessibilityId": "browser.search", "action": "click"]) }
        await #expect(throws: (any Error).self) {
            try await perform(d, ["accessibilityId": .string("browser.item.\(drumsID)"), "action": "drop"])
        }
        // The place persisted.
        #expect(BrowserLibrary(settingsURL: temp.file("Browser.json"), watchesFileSystem: false).places.map(\.id) == [placeID])
    }

    @Test("UI-067: ui.perform drop puts an item on a track or the empty area at a snapped tick (one undo entry); load = double-click; refusals are invalidArgument")
    func dropAndLoad() async throws {
        let t = app()
        let window = t.app.newProject()
        window.perform(AddTrack(name: "Gtr", kind: .audio))
        window.perform(AddTrack(name: "Keys", kind: .midi))
        let gtr = window.project.tracks[0].id
        let keys = window.project.tracks[1].id
        let d = t.app.dispatcher
        _ = try await perform(d, ["accessibilityId": "browser.places.add", "action": "click", "text": .string(root.path)])
        let pad = BrowserItem.id(forPath: BrowserItem.canonical(root.appending(path: "pad.aif")).path)
        let riff = BrowserItem.id(forPath: BrowserItem.canonical(root.appending(path: "riff.mid")).path)

        let onTrack = try await perform(d, ["accessibilityId": .string("browser.item.\(pad)"), "action": "drop",
                                            "track": .int(Int64(gtr)), "tick": 1000])
        #expect(onTrack["kind"] == "browserItem" && onTrack["action"] == "drop")
        #expect(onTrack["track"] == .int(Int64(gtr)) && onTrack["newTrack"] == false && onTrack["tick"] == 960, "snapped to the beat")
        let clipID = try #require(onTrack["clips"]?[0]?.int64Value)
        #expect(window.project.clip(ModelID(clipID))?.start == Tick(960))
        #expect(window.store.undoLabel == "Load pad.aif")

        let empty = try await perform(d, ["accessibilityId": .string("browser.item.\(pad)"), "action": "drop", "tick": 3840])
        #expect(empty["newTrack"] == true && empty["imported"] == [], "a new track; the project's asset reused")
        #expect(window.project.tracks.count == 3 && window.project.tracks[2].name == "pad")
        _ = try await perform(d, ["accessibilityId": "edit.undo", "action": "click"])
        #expect(window.project.tracks.count == 2, "the drop was one undo entry")

        await #expect(throws: (any Error).self) {
            try await perform(d, ["accessibilityId": .string("browser.item.\(pad)"), "action": "drop", "track": .int(Int64(keys)), "tick": 0])
        }
        #expect(window.toasts.toasts.last?.severity == .error, "the refusal toasts too")
        await #expect(throws: (any Error).self) {
            try await perform(d, ["accessibilityId": .string("browser.item.\(riff)"), "action": "drop", "tick": 0])
        }

        // load = the double-click: the selected track, at the playhead.
        window.selectedTracks = [gtr]
        let load = try await perform(d, ["accessibilityId": .string("browser.item.\(pad).load"), "action": "click"])
        #expect(load["load"]?["track"] == .int(Int64(gtr)) && load["load"]?["tick"] == 0)
        #expect(window.project.tracks[0].clips.count == 2)
    }
}
