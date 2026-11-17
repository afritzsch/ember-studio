import AppKit
import DAWControl
import DAWModel
import Darwin
import Foundation
import Testing

@testable import EmberStudioShell

// PLUG-017 (T-063): plugin editors in floating panels, opened from the mixer's inserts and
// instrument ("Open Editor", UI-032), reported by ui.state, driven by ui.perform and captured by
// ui.snapshot {pluginEditor}. The model rules run on a FakeEngine with a stand-in view; the
// attach-mode test runs the real engine with EmberTest's own editor (DW-208).

private enum EditorTestVST3 {
    static var root: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var effect: String {
        root.appending(path: ".build/test-plugins/EmberTest.vst3").path + "#E4B3E71A000000000000000000000001"
    }

    static func build() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [root.appending(path: "scripts/build-test-vst3.sh").path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "scripts/build-test-vst3.sh failed")
    }

    static func symbol<T>(_ name: String, as type: T.Type) throws -> T {
        let path = root.appending(path: ".build/test-plugins/EmberTest.vst3/Contents/MacOS/EmberTest").path
        let image = try #require(dlopen(path, RTLD_NOW))
        return unsafeBitCast(try #require(dlsym(image, name)), to: type)
    }
}

@MainActor
@Suite("Plugin editors (PLUG-017)", .serialized)
struct PluginEditorTests {
    /// A FakeEngine window with an audio track (a VST3 insert, a built-in EQ) and a MIDI track with
    /// an AU instrument; editors get a stand-in view.
    private func makeEditorWindow() throws -> (ProjectWindowModel, FakeEngine, track: NodeIDValue, vst3: NodeIDValue,
                                               eq: NodeIDValue, midi: NodeIDValue, au: NodeIDValue) {
        let (window, engine) = try makeWindow(tracks: ["Fx"])
        let track = window.project.tracks[0].id
        window.perform(InsertDevice(channel: track, device: .vst3(VST3Descriptor(identifier: "/x.vst3#01", name: "X Comp"))))
        window.perform(InsertDevice(channel: track, device: .builtin(.eq)))
        window.perform(AddTrack(name: "Keys", kind: .midi))
        let midi = window.project.tracks[1].id
        window.perform(SetInstrument(trackID: midi, device: .au(AUDescriptor(identifier: "aumu:samp:appl", name: "AUSampler"))))
        window.pluginEditors.panels = nil
        window.pluginEditors.makeView = { _ in NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200)) }
        let inserts = window.project.tracks[0].inserts
        return (window, engine, track, inserts[0].id, inserts[1].id, midi, try #require(window.project.tracks[1].instrument?.id))
    }

    @Test("PLUG-017, UI-032: plugin inserts and instruments have editor toggles (not built-ins); opening shows on the strip; closing ends a plugin gesture")
    func mixerToggles() throws {
        let (window, engine, track, vst3, eq, midi, au) = try makeEditorWindow()
        let insertID = "mixer.track.\(track).insert.\(vst3).editor"
        let toggle = try window.control(insertID)
        #expect(toggle.kind == .toggle && toggle.isOn == false && toggle.isEnabled && toggle.label == "X Comp Editor")
        #expect(window.controls.contains { $0.id == "mixer.track.\(track).insert.\(eq).editor" } == false)
        #expect(window.controls.contains { $0.id == "mixer.track.\(midi).instrument.editor" })
        toggle.action()
        let opened = try window.control(insertID)
        #expect(window.pluginEditors.isOpen(vst3) && opened.isOn == true)
        #expect(window.mixer.strips[0].inserts[0].editorOpen)
        #expect(window.pluginEditors.editors[vst3]?.width == 300 && window.pluginEditors.editors[vst3]?.title == "X Comp")
        try window.control("mixer.track.\(midi).instrument.editor").action()
        #expect(window.pluginEditors.openSlots == [vst3, au].sorted())

        // A plugin gesture still open when the editor closes ends with it (one undo entry).
        engine.post(EngineEvent(pluginEdit: PluginParamEdit(index: 0, value: .nan, phase: .begin), slot: vst3))
        engine.post(EngineEvent(pluginEdit: PluginParamEdit(index: 0, value: 0.5, phase: .value), slot: vst3))
        window.engineEventsArrived(window.store.engineSync?.pollEvents() ?? [])
        #expect(window.store.isGestureActive)
        try window.control(insertID).action()
        #expect(!window.pluginEditors.isOpen(vst3) && !window.store.isGestureActive && window.store.undoLabel == "Set Parameter")
        // The tab closed: the toggles leave the controls with the rest of the mixer's.
        window.bottomPane = nil
        #expect(window.controls.contains { $0.id == insertID } == false)
    }

    @Test("PLUG-017: an editor closes when its slot is removed, its plugin crashes, safe mode is on, the document is replaced or the window closes")
    func editorsClose() async throws {
        let (window, engine, _, vst3, _, midi, au) = try makeEditorWindow()
        window.pluginEditors.open(vst3)
        window.pluginEditors.open(au)
        window.perform(RemoveInstrument(trackID: midi))
        window.pollTransport()
        #expect(window.pluginEditors.openSlots == [vst3])
        window.store.undo()  // the instrument is back; its editor stays closed
        window.pollTransport()
        #expect(window.pluginEditors.openSlots == [vst3])

        engine.post(EngineEvent(kind: .pluginCrashed, subject: vst3, error: .engine(code: .notFound, detail: "gone")))
        window.engineEventsArrived(window.store.engineSync?.pollEvents() ?? [])
        #expect(window.pluginEditors.openSlots.isEmpty)

        window.pluginEditors.open(vst3)
        window.store.isSafeMode = true  // PLUG-021: plugins are bypassed; their editors close
        window.pollTransport()
        #expect(window.pluginEditors.openSlots.isEmpty && !window.pluginEditors.canOpen(vst3))
        window.pluginEditors.open(vst3)
        #expect(window.pluginEditors.openSlots.isEmpty)
        window.store.isSafeMode = false

        window.pluginEditors.open(vst3)
        window.replace(store: ProjectStore(project: Project(name: "Other")))
        #expect(window.pluginEditors.openSlots.isEmpty)
    }

    @Test("PLUG-017: an editor the engine can't make (no plugin loaded, no editor) is an error toast, not an open editor")
    func noEditor() throws {
        let (window, _, _, vst3, _, _, _) = try makeEditorWindow()
        window.pluginEditors.makeView = nil  // the FakeEngine has no plugin views
        window.pluginEditors.open(vst3)
        #expect(window.pluginEditors.openSlots.isEmpty)
        #expect(window.toasts.toasts.last?.title == "No editor for X Comp")
    }

    @Test("PLUG-017, DW-208 (attach mode, real engine): ui.perform opens EmberTest's editor in a panel; ui.state lists it; ui.snapshot {pluginEditor} captures it; resizeView resizes the panel; removing the insert closes it")
    func attachRealEditor() async throws {
        try EditorTestVST3.build()
        let dir = try TempDir()
        let app = AppModel(engine: .offline, makeEngine: { rate throws(DAWError) in try EngineClient(.offline(sampleRate: rate)) },
                           workingDirectory: dir.url)
        let manager = realWindowManager(for: app)
        let window = app.newProject()
        defer { manager.close(window) }
        window.store.autosavePolicy = nil
        let d = app.dispatcher
        _ = try await d.call(.commandApply, ["command": ["type": "AddTrack", "name": "Fx", "kind": "audio"]])
        let track = window.project.tracks[0].id
        let device: JSONValue = ["format": "vst3", "identifier": .string(EditorTestVST3.effect), "name": "Ember", "vendor": "Ember", "version": "1"]
        _ = try await d.call(.commandApply, ["command": ["type": "InsertDevice", "channel": .int(Int64(track)), "device": device]])
        let slot = try #require(window.project.tracks[0].inserts.first?.id)
        _ = try await d.call(.renderOffline, ["from": 0, "to": 96, "path": "x.wav", "tail": false])  // the plugin is in the graph

        let id = "mixer.track.\(track).insert.\(slot).editor"
        let opened = try await d.call(.uiPerform, ["accessibilityId": .string(id), "action": "on"])
        #expect(opened["isOn"] == true)
        var state = try await d.call(.uiState)
        var editor = try #require(state["windows"]?[0]?["pluginEditors"]?[0])
        #expect(editor["slot"] == .int(Int64(slot)) && editor["title"] == "Ember Test Effect" && editor["kind"] == "vst3")
        #expect(editor["width"]?.doubleValue == 400 && editor["height"]?.doubleValue == 300 && editor["ready"] == true)
        #expect(editor["control"] == .string(id))
        let panel = try #require(window.pluginEditors.panels?.panel(for: slot))
        #expect(panel.contentLayoutRect.size == NSSize(width: 400, height: 300) && panel.isFloatingPanel)

        // The editor's pixels: EmberTest draws an orange bar as wide as its gain (1.0) on dark grey
        // (calibrated RGB, so compared loosely after conversion to sRGB).
        let shot = try await d.call(.uiSnapshot, ["path": .string(dir.file("editor.png").path), "pluginEditor": .int(Int64(slot))])
        #expect(shot["pluginEditor"] == .int(Int64(slot)))
        let image = try #require(NSBitmapImageRep(data: try Data(contentsOf: dir.file("editor.png"))))
        #expect(image.pixelsWide >= 400 && image.pixelsHigh >= 300)
        let scale = Double(image.pixelsWide) / 400
        let bar = try #require(image.colorAt(x: Int(200 * scale), y: Int(40 * scale))?.usingColorSpace(.sRGB))
        #expect(bar.redComponent > 0.8 && bar.blueComponent < 0.45 && bar.redComponent - bar.blueComponent > 0.4, "\(bar)")

        // The plugin asks for a new size: the panel follows; ui.state reports it.
        typealias Resize = @convention(c) (Int32, Int32) -> Int32
        let resize = try EditorTestVST3.symbol("ember_test_view_request_resize", as: Resize.self)
        #expect(resize(520, 360) == 0)
        try await Task.sleep(for: .milliseconds(50))  // the frame notification is delivered on the main queue
        #expect(panel.contentLayoutRect.size == NSSize(width: 520, height: 360))
        window.pollTransport()
        state = try await d.call(.uiState)
        editor = try #require(state["windows"]?[0]?["pluginEditors"]?[0])
        #expect(editor["width"]?.doubleValue == 520 && editor["height"]?.doubleValue == 360)

        // Removing the insert closes its editor (and the engine lets go of the view).
        _ = try await d.call(.commandApply, ["command": ["type": "RemoveDevice", "slotID": .int(Int64(slot))]])
        window.pollTransport()
        state = try await d.call(.uiState)
        #expect(state["windows"]?[0]?["pluginEditors"] == [])
        #expect(window.pluginEditors.panels?.panel(for: slot) == nil)
        #expect(window.engine?.pluginViewJSON(slot: slot) == "{\"slot\":\(slot),\"open\":false}")
    }
}
