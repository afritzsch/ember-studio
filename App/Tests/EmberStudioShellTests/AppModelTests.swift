import DAWControl
import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// UI-001 (window management and File commands, without AppKit), the Dispatcher binding of attach
// mode (CTL-002 in the app), the event pump (UI-004) and DW-144 (recovery, clean quit).

@MainActor
@Suite("App model (UI-001, UI-003, UI-004, DW-144)")
struct AppModelTests {
    @Test("UI-001: File > New opens one window per project; the main window is the one the Dispatcher controls")
    func windowsAndBinding() async throws {
        let t = TestApp()
        let first = t.app.newProject()
        #expect(t.app.mainWindowID == first.id && t.app.dispatcher.store === first.store)
        #expect(first.engine != nil && first.project.name == "Untitled")
        let second = t.app.newProject()
        #expect(second.project.name == "Untitled 2" && t.app.windows.count == 2)
        #expect(t.app.dispatcher.store === second.store)

        t.app.becameMain(first.id)
        #expect(t.app.dispatcher.store === first.store)
        _ = try await t.app.dispatcher.call(.commandApply, ["command": ["type": "AddTrack", "name": "via socket", "kind": "audio"]])
        #expect(first.project.tracks.map(\.name) == ["via socket"] && second.project.tracks.isEmpty)

        await t.app.closeWindow(first.id)
        #expect(t.app.windows.map(\.id) == [second.id] && t.app.mainWindowID == second.id)
        #expect(t.app.dispatcher.store === second.store, "the next window takes over")
        #expect(first.store.engineSync == nil, "the closed project's engine is released")
        await t.app.closeWindow(second.id)
        #expect(t.app.dispatcher.store == nil && t.app.mainWindow == nil)
    }

    @Test("CTL-002 in the app: project.new through the Dispatcher replaces the main window's document, or opens a window")
    func dispatcherReplacesDocument() async throws {
        let t = TestApp()
        let window = t.app.newProject()
        let old = window.store
        window.selectedTracks = [5]
        _ = try await t.app.dispatcher.call(.projectNew, ["name": "from agent"])
        #expect(t.app.windows.count == 1 && window.project.name == "from agent" && window.store !== old)
        #expect(window.selectedTracks.isEmpty && old.engineSync == nil && old.autosavePolicy == nil)
        let id = try await t.app.dispatcher.call(.projectNew, ["name": "x"])["projectID"]?.stringValue
        #expect(id != "00000000-0000-0000-0000-000000000002", "attach mode: random IDs")

        await t.app.closeWindow(window.id)
        _ = try await t.app.dispatcher.call(.projectNew, ["name": "no window"])
        #expect(t.app.windows.count == 1 && t.app.mainWindow?.project.name == "no window")
    }

    @Test("UI-004: the pump drains the bound window through the Dispatcher (engine.events sees it) and other windows directly")
    func eventPump() async throws {
        let t = TestApp()
        let a = t.app.newProject()
        let engineA = t.engines.last!
        let b = t.app.newProject()
        let engineB = t.engines.last!
        #expect(t.app.dispatcher.store === b.store)

        engineA.post(EngineEvent(kind: .pluginCrashed, subject: 1))
        engineB.post(EngineEvent(kind: .overload, count: 2))
        t.app.pump()
        #expect(a.toasts.toasts.map(\.kind) == [.pluginCrashed])
        #expect(b.toasts.toasts.map(\.kind) == [.overload])
        let events = try await t.app.dispatcher.call(.engineEvents)["events"]?.arrayValue ?? []
        #expect(events.map { $0["event"]?["kind"] } == ["overload"], "one drain: the Dispatcher's log has the bound engine's event")

        engineB.play()
        t.app.pump()
        #expect(b.transport.playing)
        t.clock.advance(60)
        t.app.pump()
        #expect(b.toasts.toasts.isEmpty && a.toasts.toasts.count == 1, "warnings expire, errors stay")
    }

    @Test("UI-001, DW-144: save, reopen with recovery offered, recover through the toast, and a clean quit drops the autosave")
    func openSaveRecover() async throws {
        let dir = try TempDir()
        let t = TestApp()
        let window = t.app.newProject()
        window.perform(AddTrack(name: "Saved", kind: .audio))
        let folder = dir.file("Song.dawproject")
        try await t.app.save(window, to: folder)
        #expect(!window.store.isDirty && window.store.folderURL == folder)
        // A crash after an unsaved edit: only the autosave has it.
        window.perform(AddTrack(name: "Unsaved", kind: .audio))
        try await window.store.autosave()
        await t.app.closeWindow(window.id) // a close without close(): simulate the crash by restoring the autosave
        let crashed = ProjectStore(project: window.project)
        crashed.autosavePolicy = nil
        try await crashed.save(to: dir.file("Crash.dawproject"))
        try crashed.perform(AddTrack(name: "Lost", kind: .audio))
        try await crashed.autosave()

        let opened = try await t.app.open(dir.file("Crash.dawproject"))
        #expect(opened.project.tracks.map(\.name) == ["Saved", "Unsaved"])
        let recovery = try #require(opened.toasts.toasts.first { $0.kind == .recoveryAvailable })
        #expect(recovery.action?.label == "Recover")
        let again = try await t.app.open(dir.file("Crash.dawproject"))
        #expect(again === opened && t.app.windows.count == 1, "one window per project")

        opened.toasts.performAction(recovery.id)
        for _ in 0..<200 where opened.project.tracks.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(opened.project.tracks.map(\.name) == ["Saved", "Unsaved", "Lost"])
        #expect(opened.store.loadReport.recovered && opened.store.isDirty)
        #expect(t.app.dispatcher.store === opened.store, "the Dispatcher follows the recovered document")

        try await t.app.save(opened, to: nil)
        try await opened.store.autosave()
        await t.app.quit()
        #expect(!FileManager.default.fileExists(atPath: dir.file("Crash.dawproject/autosave").path), "MODEL-045 clean quit")
    }

    @Test("DW-155, UI-004: project.open over the app's socket posts File > Open's load-report toasts (offline audio, recovery with Recover) in the window that shows it")
    func socketOpenToasts() async throws {
        let dir = try TempDir()
        // A saved project with a missing audio file and an unsaved edit only in its autosave.
        let saved = ProjectStore(project: Project(name: "Remote"))
        saved.autosavePolicy = nil
        try saved.perform(AddTrack(name: "Saved", kind: .audio))
        try saved.perform(ImportAsset(asset: AssetRef(id: saved.project.ids.next, path: dir.file("gone.wav").path, channels: 1,
                                                      originalSampleRate: 48_000, frames: 48_000)))
        let folder = dir.file("Remote.dawproject")
        try await saved.save(to: folder)
        try saved.perform(AddTrack(name: "Unsaved", kind: .audio))
        try await saved.autosave()

        let t = TestApp()
        let window = t.app.newProject()
        let line = #"{"jsonrpc":"2.0","id":1,"method":"project.open","params":{"path":"\#(folder.path)"}}"#
        let response = try #require(await t.app.handleControl(line: line) { _ in })
        #expect(response.contains("loadReport") && !response.contains("\"error\""))
        #expect(window.store === t.app.dispatcher.store && window.project.name == "Remote")
        #expect(window.toasts.toasts.map(\.kind) == [.offlineAssets, .recoveryAvailable])
        let recovery = try #require(window.toasts.toasts.first { $0.kind == .recoveryAvailable })
        #expect(recovery.action?.label == "Recover")
        window.toasts.performAction(recovery.id)
        for _ in 0..<200 where window.project.tracks.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(window.project.tracks.map(\.name) == ["Saved", "Unsaved"] && window.store.loadReport.recovered)

        // Other requests (and a failed open) post nothing.
        let count = window.toasts.toasts.count
        _ = await t.app.handleControl(line: #"{"jsonrpc":"2.0","id":2,"method":"project.get","params":{}}"#) { _ in }
        _ = await t.app.handleControl(line: #"{"jsonrpc":"2.0","id":3,"method":"project.open","params":{"path":"/nope.dawproject"}}"#) { _ in }
        #expect(window.toasts.toasts.count == count)
        await t.app.quit()
    }

    @Test("UI-001, DW-221: File > Export… opens the export dialog, whose Export renders the project to the end of its last clip (at least a bar) on the window's engine")
    func export() async throws {
        let dir = try TempDir()
        let t = TestApp()
        let window = t.app.newProject()
        // File > Export… (AppDelegate.exportAudio) opens the main window's dialog: the only export path.
        window.exportDialog.isOpen = true
        window.exportDialog.setDestination(dir.file("out.wav"))
        let start = try #require(window.controls.first { $0.id == "export.start" })
        start.action()
        for _ in 0..<1000 where window.exportDialog.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(window.exportDialog.lastError == nil)
        let render = t.engines.last!.calls.compactMap { call -> (Tick, Tick, String)? in
            if case .renderOffline(let from, let to, let path) = call { (from, to, path) } else { nil }
        }
        #expect(render.count == 1 && render[0].0 == Tick(0) && render[0].1 == Tick(3840) && render[0].2 == dir.file("out.wav").path)
    }

    @Test("MODEL-043, DW-143 (T-061): app saves capture a hosted plugin's live state from the window's engine")
    func savesCapturePluginState() async throws {
        let dir = try TempDir()
        let t = TestApp()
        let window = t.app.newProject()
        window.store.autosavePolicy = nil
        #expect(window.store.pluginStateProvider is EnginePluginStates)
        window.perform(AddTrack(name: "Keys", kind: .midi))
        let track = try #require(window.project.tracks.first?.id)
        window.perform(SetInstrument(trackID: track, device: .au(AUDescriptor(identifier: "aumu:samp:appl", name: "AUSampler"))))
        let slot = try #require(window.project.tracks.first?.instrument?.id)
        // What the AU holds now, as the engine reports it (FakeEngine keeps what it's given).
        let live = Data("bplist00 live".utf8)
        try #require(t.engines.last).setPluginState(slot: slot, live)

        let folder = dir.file("AU.dawproject")
        try await t.app.save(window, to: folder)
        #expect(try Data(contentsOf: folder.appending(path: "Plugins/\(slot).state")) == live)
        #expect(window.project.tracks.first?.instrument?.pluginState == nil, "the save doesn't edit the project")

        // Reopened, the stored state is in the slot, so the engine gets it in the node's configJSON.
        await t.app.closeWindow(window.id)
        let opened = try await t.app.open(folder)
        #expect(opened.project.tracks.first?.instrument?.pluginState == live)
        #expect(opened.store.pluginStateProvider is EnginePluginStates)
    }
}
