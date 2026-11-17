import AppKit
import DAWControl
import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// T-083: UI-043 (the crash-recovery dialog: MODEL-045 + PLUG-021), DW-144 (its recovery part),
// DW-224 (safe mode builds plugin slots without their plugin) and DW-226 (safe mode in the window
// and ui.state; a toast of its own for pluginMisbehaved). Crashed sessions are injected as
// `CrashMarker`s (or as marker files of a pid that is gone, read by `CrashMarkerSession.start`).

@MainActor
private let deadPID: Int32 = 99_999_999  // above macOS's pid range: never a live process

/// A saved project with an AU on its audio track and a VST3 on the master; optionally an autosave
/// newer than the save that adds a track "Unsaved".
@MainActor
private func savedProject(_ name: String, in dir: TempDir, autosave: Bool = false) async throws -> (url: URL, project: Project) {
    var project = Project(name: name)
    let track = project.ids.allocate()
    let au = project.ids.allocate()
    let vst3 = project.ids.allocate()
    project.tracks = [Track(id: track, name: "Guitar", kind: .audio,
                            inserts: [DeviceSlot(id: au, kind: .au(AUDescriptor(identifier: "aufx:dely:appl", name: "AUDelay")),
                                                 pluginState: Data([1, 2, 3]))])]
    project.master.inserts = [DeviceSlot(id: vst3, kind: .vst3(VST3Descriptor(
        identifier: "/nonexistent/Crashy.vst3#84E8DE5F92554F5396FAE4133C935A18", name: "Crashy")))]
    let url = dir.file("\(name).dawproject")
    let store = ProjectStore(project: project)
    store.autosavePolicy = nil
    try await store.save(to: url)
    if autosave {
        try store.perform(AddTrack(name: "Unsaved", kind: .audio))
        try await Task.sleep(for: .milliseconds(20))  // a later modification time than the save
        try await store.autosave()
    }
    return (url, project)
}

@MainActor
private func marker(_ projects: [(name: String, url: URL?, project: Project?)], pid: Int32 = deadPID,
                    launched: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> CrashMarker {
    CrashMarker(processID: pid, launched: launched, projects: projects.map { p in
        if let project = p.project { return CrashMarker.OpenProject(project: project, folder: p.url) }
        return CrashMarker.OpenProject(name: p.name, path: p.url?.path, plugins: [])
    })
}

@Suite("Crash recovery dialog (UI-043, PLUG-021, MODEL-045)", .serialized)
@MainActor
struct CrashRecoveryTests {
    @Test("UI-043: --crash-marker-dir names the marker directory and lets an automated launch show the dialog")
    func launchOptions() {
        let user = CrashRecoveryLaunch(arguments: ["Ember Studio"], isAutomated: false)
        #expect(user.directory == CrashMarker.defaultDirectory && user.showsDialog)
        let automated = CrashRecoveryLaunch(arguments: ["app", "--control-socket", "/tmp/s"], isAutomated: true)
        #expect(automated.directory.lastPathComponent == "EmberStudio-Sessions" && !automated.showsDialog)
        let injected = CrashRecoveryLaunch(arguments: ["app", "--engine", "fake", "--crash-marker-dir", "/tmp/x y"], isAutomated: true)
        #expect(injected.directory.path == "/tmp/x y" && injected.showsDialog)
        // AppOptions leaves the argument alone.
        #expect(AppOptions(arguments: ["app", "--crash-marker-dir", "/tmp/x", "--engine", "offline"]).engine == .offline)
    }

    @Test("UI-043: entries list each crashed project once with its plugins; unsaved ones can't open; recovery offered where the autosave is newer")
    func entries() throws {
        var a = Project(name: "A")
        let slot = a.ids.allocate()
        a.master.inserts = [DeviceSlot(id: slot, kind: .au(AUDescriptor(identifier: "aufx:dely:appl", name: "AUDelay")))]
        let urlA = URL(fileURLWithPath: "/tmp/A.dawproject")
        let urlB = URL(fileURLWithPath: "/tmp/B.dawproject")
        let sessions = [
            marker([("A", urlA, a), ("Untitled", nil, nil)], pid: deadPID, launched: Date(timeIntervalSince1970: 1)),
            marker([("A", urlA, a), ("B", urlB, nil)], pid: deadPID - 1, launched: Date(timeIntervalSince1970: 2)),
        ]
        let model = CrashRecoveryModel(sessions: sessions) { $0.lastPathComponent == "B.dawproject" }
        #expect(model.entries.map(\.name) == ["A", "Untitled", "B"])
        #expect(model.entries.map(\.canOpen) == [true, false, true])
        #expect(model.entries[0].plugins.map(\.name) == ["AUDelay"] && model.entries[0].launched == Date(timeIntervalSince1970: 2))
        #expect(model.entries.map(\.recoveryAvailable) == [false, false, true] && model.entries[2].recover)
        #expect(model.title == "Ember Studio quit unexpectedly 2 times")
        #expect(model.message.hasPrefix("2 projects were open.") && model.message.contains("plugins disabled"))
        #expect(model.controls.map(\.id) == ["crashRecovery.openSafe", "crashRecovery.openNormally", "crashRecovery.dontOpen",
                                             "crashRecovery.project.3.recover"])
        model.setRecover(3, false)
        #expect(!model.entries[2].recover)
        model.setRecover(1, true)  // no autosave: stays off
        #expect(!model.entries[0].recover)
    }

    @Test("UI-043, DW-224, DW-144: Open with Plugins Disabled through ui.perform opens every project in safe mode (the first in the untouched window), recovers autosaves, and shows safe mode in ui.state")
    func openSafeThroughUIPerform() async throws {
        let dir = try TempDir()
        let (urlA, projectA) = try await savedProject("Alpha", in: dir)
        let (urlB, projectB) = try await savedProject("Beta", in: dir, autosave: true)
        let t = TestApp()
        let untitled = t.app.newProject()
        let crash = try #require(t.app.presentCrashRecovery([marker([("Alpha", urlA, projectA), ("Beta", urlB, projectB)])]))
        #expect(untitled.crashRecovery === crash)

        let d = t.app.dispatcher
        let state = try await d.call(.uiState)
        let dialog = try #require(state["crashRecovery"])
        #expect(dialog["presented"] == true)
        #expect(dialog["projects"]?[0]?["name"] == "Alpha" && dialog["projects"]?[0]?["recoveryAvailable"] == false)
        #expect(dialog["projects"]?[0]?["plugins"]?[0]?["name"] == "AUDelay")
        #expect(dialog["projects"]?[0]?["plugins"]?[1]?["format"] == "vst3")
        #expect(dialog["projects"]?[1]?["recoveryAvailable"] == true && dialog["projects"]?[1]?["recover"] == true)
        #expect(dialog["sessions"]?[0]?["pid"] == .int(Int64(deadPID)))
        let ids = (state["windows"]?[0]?["controls"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
        #expect(ids.contains("crashRecovery.openSafe") && ids.contains("crashRecovery.project.2.recover"))

        _ = try await d.call(.uiPerform, ["accessibilityId": "crashRecovery.openSafe", "action": "click"])
        await crash.pending?.value
        #expect(crash.choice == .openSafe && !crash.isPresented && crash.failures.isEmpty)
        #expect(t.app.crashRecovery == nil && untitled.crashRecovery == nil)

        // Alpha replaced the untouched Untitled window; Beta opened in a window of its own.
        #expect(t.app.windows.count == 2)
        #expect(untitled.store.folderURL?.path == urlA.path && untitled.store.isSafeMode)
        let beta = try #require(t.app.windows.first { $0.store.folderURL?.path == urlB.path })
        #expect(beta.store.isSafeMode)
        #expect(beta.project.tracks.map(\.name) == ["Guitar", "Unsaved"] && beta.store.loadReport.recovered)
        #expect(!beta.toasts.toasts.contains { $0.kind == .recoveryAvailable }, "DW-144: the dialog asked already")
        // Nothing reached the documents: the slots, params and states are as saved.
        #expect(untitled.project == projectA && !untitled.store.isDirty)

        // DW-224: the engine got plugin slots that build without their plugin.
        let engine = try #require(untitled.engine as? FakeEngine)
        let graph = try #require(engine.appliedGraphs.last)
        let pluginNodes = graph.nodes.filter { $0.kind == .auPlugin || $0.kind == .vst3Plugin }
        #expect(pluginNodes.count == 2 && pluginNodes.allSatisfy { $0.configJSON.contains(#""disabled":true"#) })

        // DW-226: ui.state shows safe mode and the plugins it keeps from loading.
        let after = try await d.call(.uiState)
        #expect(after["crashRecovery"] == .null)
        let windows = after["windows"]?.arrayValue ?? []
        #expect(windows.allSatisfy { $0["safeMode"]?["on"] == true })
        #expect(windows.first { $0["id"] == .int(Int64(untitled.id)) }?["safeMode"]?["plugins"]?[1]?["name"] == "Crashy")
        #expect(untitled.safeModeMessage.contains("2 plugins are disabled") && untitled.safeModeMessage.contains("AUDelay, Crashy"))
        #expect(untitled.controls.contains { $0.id == "safeMode.enablePlugins" })
        // PLUG-017: no plugin editor in safe mode.
        #expect(!untitled.pluginEditors.canOpen(projectA.tracks[0].inserts[0].id))
        await t.app.quit()
    }

    @Test("UI-043: Open Normally opens without safe mode and without recovery when it is unticked; Don't Open opens nothing")
    func openNormallyAndDontOpen() async throws {
        let dir = try TempDir()
        let (url, project) = try await savedProject("Gamma", in: dir, autosave: true)
        let t = TestApp()
        let window = t.app.newProject()
        window.perform(AddTrack(name: "Mine", kind: .audio))  // touched: the project opens next to it
        let crash = try #require(t.app.presentCrashRecovery([marker([("Gamma", url, project)])]))
        try window.control("crashRecovery.project.1.recover").action()
        #expect(crash.entries[0].recover == false)
        try window.control("crashRecovery.openNormally").action()
        await crash.pending?.value
        #expect(t.app.windows.count == 2)
        let gamma = try #require(t.app.windows.first { $0.store.folderURL?.path == url.path })
        #expect(!gamma.store.isSafeMode && !gamma.store.loadReport.recovered && gamma.project.tracks.map(\.name) == ["Guitar"])
        #expect(!gamma.toasts.toasts.contains { $0.kind == .recoveryAvailable }, "declined in the dialog")
        #expect(!gamma.controls.contains { $0.id == "safeMode.enablePlugins" })
        let graph = try #require((gamma.engine as? FakeEngine)?.appliedGraphs.last)
        #expect(!graph.nodes.contains { $0.configJSON.contains("disabled") })
        await t.app.quit()

        let t2 = TestApp()
        let only = t2.app.newProject()
        let crash2 = try #require(t2.app.presentCrashRecovery([marker([("Gamma", url, project)])]))
        try only.control("crashRecovery.dontOpen").action()
        await crash2.pending?.value
        #expect(crash2.choice == .dontOpen && t2.app.windows.count == 1 && only.store.folderURL == nil)
        #expect(!only.controls.contains { $0.id.hasPrefix("crashRecovery.") })
        await t2.app.quit()
    }

    @Test("UI-043: markers of a crashed process reach the dialog through CrashMarkerSession; a project that can't open gets an error toast")
    func markerFilesAndFailures() async throws {
        let dir = try TempDir()
        let markers = dir.url.appending(path: "markers")
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        let missing = dir.file("Gone.dawproject")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601  // as CrashMarkerSession writes it
        let data = try encoder.encode(marker([("Gone", missing, nil)]))
        try data.write(to: CrashMarker.fileURL(processID: deadPID, in: markers))
        let session = CrashMarkerSession.start(directory: markers) { [] }
        defer { session.end() }
        #expect(session.crashedSessions.map(\.processID) == [deadPID])

        let t = TestApp()
        let window = t.app.newProject()
        let crash = try #require(t.app.presentCrashRecovery(session.crashedSessions))
        #expect(crash.entries.map(\.name) == ["Gone"] && crash.entries[0].canOpen)
        try window.control("crashRecovery.openSafe").action()
        await crash.pending?.value
        #expect(crash.failures.map(\.name) == ["Gone"])
        #expect(window.toasts.toasts.contains { $0.title == "Couldn't open Gone" && $0.severity == .error })
        #expect(t.app.presentCrashRecovery([]) == nil, "no crashed sessions, no dialog")
        await t.app.quit()
    }

    @Test("PLUG-021, DW-224: Enable Plugins leaves safe mode: the plugin slots are rebuilt with their plugins; the document is unchanged")
    func enablePlugins() async throws {
        let dir = try TempDir()
        let (url, project) = try await savedProject("Delta", in: dir)
        let t = TestApp()
        let window = try await t.app.open(url, safeMode: true)
        let engine = try #require(window.engine as? FakeEngine)
        let before = engine.appliedGraphs.count
        try window.control("safeMode.enablePlugins").action()
        window.store.engineSync?.flush()  // the re-apply is debounced
        #expect(!window.store.isSafeMode && engine.appliedGraphs.count == before + 1)
        #expect(!(engine.appliedGraphs.last?.nodes.contains { $0.configJSON.contains("disabled") } ?? true))
        #expect(window.toasts.toasts.contains { $0.title == "Plugins enabled" })
        #expect(window.project == project && !window.store.isDirty && !window.store.canUndo)
        #expect(window.safeModePlugins.isEmpty && !window.controls.contains { $0.id == "safeMode.enablePlugins" })
        await t.app.quit()
    }

    @Test("DW-226: pluginMisbehaved has its own warning toast naming the slot; pluginCrashed keeps its error")
    func misbehavedToast() async throws {
        let dir = try TempDir()
        let (url, project) = try await savedProject("Epsilon", in: dir)
        let t = TestApp()
        let window = try await t.app.open(url)
        let au = try #require(project.tracks[0].inserts.first?.id)
        window.toasts.handle([EngineEvent(kind: .pluginMisbehaved, subject: au)])
        let toast = try #require(window.toasts.toasts.last)
        #expect(toast.kind == .pluginMisbehaved && toast.severity == .warning)
        #expect(toast.title == "A plugin output invalid audio" && toast.message.hasPrefix("AUDelay on Guitar produced NaN"))
        #expect(toast.expiresAt != nil, "a warning expires")
        window.toasts.handle([EngineEvent(kind: .pluginCrashed, subject: au, error: .invalidArgument("boom"))])
        #expect(window.toasts.toasts.last?.kind == .pluginCrashed && window.toasts.toasts.last?.severity == .error)
        // A slot the project doesn't have still gets a toast.
        window.toasts.handle([EngineEvent(kind: .pluginMisbehaved, subject: 424_242)])
        #expect(window.toasts.toasts.last?.message.hasPrefix("Device 424242") == true)
        await t.app.quit()
    }

    @Test("UI-043, UI-051: the dialog and the safe-mode banner are in the window's layout, so ui.snapshot captures them")
    func snapshot() async throws {
        let dir = try TempDir()
        let (url, project) = try await savedProject("Zeta", in: dir)
        let t = TestApp(workingDirectory: dir.url)
        let manager = realWindowManager(for: t.app)
        let window = t.app.newProject()
        defer { for w in t.app.windows { manager.close(w) } }
        let crash = try #require(t.app.presentCrashRecovery([marker([("Zeta", url, project)])]))
        let withDialog = try await t.app.dispatcher.call(.uiSnapshot, ["path": .string(dir.file("dialog.png").path)])
        let dialogImage = try #require(NSBitmapImageRep(data: try Data(contentsOf: dir.file("dialog.png"))))
        #expect(withDialog["width"] == .int(Int64(dialogImage.pixelsWide)))
        try window.control("crashRecovery.openSafe").action()
        await crash.pending?.value
        #expect(window.store.isSafeMode)
        _ = try await t.app.dispatcher.call(.uiSnapshot, ["path": .string(dir.file("banner.png").path)])
        let bannerImage = try #require(NSBitmapImageRep(data: try Data(contentsOf: dir.file("banner.png"))))
        // The dialog is taller than the banner: the arrange area starts lower with it. Compare the
        // rows tinted by each strip's background under the toolbar.
        #expect(tintedRows(dialogImage) > tintedRows(bannerImage) && tintedRows(bannerImage) > 0)
        await t.app.quit()
    }

    /// Rows (at the image's horizontal middle) whose colour leans warm (orange/yellow tint: red
    /// clearly above blue), the strips' backgrounds.
    private func tintedRows(_ image: NSBitmapImageRep) -> Int {
        var rows = 0
        let x = image.pixelsWide / 2
        for y in 0..<min(image.pixelsHigh, 400) {
            guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if c.redComponent - c.blueComponent > 0.04 { rows += 1 }
        }
        return rows
    }
}
