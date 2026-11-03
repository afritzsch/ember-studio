import DAWControl
import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// UI-003: view models are derived from ProjectStore and the engine, and testable without the app.

@MainActor
@Suite("Project window view model (UI-003)")
struct ViewModelTests {
    @Test("UI-003: track headers follow the project; mute/solo go through SetParam as undoable commands")
    func trackHeaders() throws {
        let (model, engine) = try makeWindow(tracks: ["Gtr", "Bass"])
        #expect(model.trackHeaders.map(\.name) == ["Gtr", "Bass"])
        let gtr = model.trackHeaders[0]
        #expect(!gtr.mute && !gtr.solo)

        engine.clearCalls()
        try model.control("track.\(gtr.id).mute").action()
        #expect(model.project.tracks[0].strip.mute)
        #expect(model.trackHeaders[0].mute && model.trackHeaders[0].muteControl.isOn == true)
        #expect(model.store.undoLabel == "Set Mute")
        #expect(engine.calls.contains { if case .setParam = $0 { true } else { false } }, "reaches the engine via engine sync")
        #expect(engine.appliedGraphs.count == 3, "a param change rebuilds nothing (MODEL-021)")

        try model.control("track.\(gtr.id).solo").action()
        #expect(model.project.tracks[0].strip.solo)
        model.store.undo()
        model.store.undo()
        #expect(!model.project.tracks[0].strip.mute && !model.project.tracks[0].strip.solo)

        try model.control("track.\(gtr.id).select").action()
        #expect(model.selectedTracks == [gtr.id] && model.trackHeaders[0].isSelected)
    }

    @Test("UI-003: panes, bottom tabs, zoom (clamped) and undo/redo enablement")
    func panesAndZoom() throws {
        let (model, _) = try makeWindow(tracks: ["A"])
        try model.control("pane.browser").action()
        #expect(!model.showsBrowser)
        try model.control("pane.bottom.pianoRoll").action()
        #expect(model.bottomPane == .pianoRoll)
        try model.control("pane.bottom.pianoRoll").action()
        #expect(model.bottomPane == nil, "the active tab closes the pane")

        let start = model.pixelsPerBeat
        try model.control("zoom.in").action()
        #expect(model.pixelsPerBeat == start * ProjectWindowModel.zoomStep)
        for _ in 0..<100 { model.zoom(by: 2) }
        #expect(model.pixelsPerBeat == ProjectWindowModel.zoomRange.upperBound)
        #expect(try !model.control("zoom.in").isEnabled)

        #expect(try model.control("edit.undo").isEnabled && model.control("edit.undo").label == "Undo Add Track")
        try model.control("edit.undo").action()
        #expect(model.project.tracks.isEmpty)
        #expect(try model.control("edit.redo").isEnabled)
    }

    @Test("UI-003: visible tracks follow scroll and viewport height")
    func visibleTracks() throws {
        let (model, _) = try makeWindow(tracks: (1...10).map { "T\($0)" })
        let ids = model.project.tracks.map(\.id)
        model.viewportHeight = ProjectWindowModel.trackHeight * 3
        #expect(model.visibleTracks == Array(ids[0..<3]))
        model.scrollY = ProjectWindowModel.trackHeight * 2.5
        #expect(model.visibleTracks == Array(ids[2..<6]))
        model.scrollY = 10_000
        #expect(model.visibleTracks.isEmpty)
    }

    @Test("UI-003: transport buttons drive the engine; the polled state follows")
    func transport() throws {
        let (model, engine) = try makeWindow()
        try model.control("transport.play").action()
        #expect(model.transport.playing && engine.transport().playing)
        #expect(try !model.control("transport.play").isEnabled)
        try model.control("transport.stop").action()
        #expect(!model.transport.playing)
    }

    @Test("UI-003: a refused command becomes an error toast, not a crash")
    func refusedCommand() throws {
        let (model, _) = try makeWindow()
        model.setStrip(999, .mute, on: true)
        #expect(model.toasts.toasts.map(\.kind) == [.error])
        #expect(model.toasts.toasts[0].title == "Set Mute failed")
    }

    @Test("UI-052: control ids are unique and follow the naming scheme")
    func controlIDs() throws {
        let (model, _) = try makeWindow(tracks: ["A", "B"])
        model.toasts.post(.info, .info, title: "hi")
        model.audioPrefs.isOpen = true  // UI-040 (T-055): its controls too
        let ids = model.controls.map(\.id)
        #expect(Set(ids).count == ids.count)
        for id in ids {
            #expect(id.wholeMatch(of: /(transport|edit|zoom|pane|track|toast|snap|clip|pianoRoll|prefs)(\.[A-Za-z0-9]+)+/) != nil, "\(id)")
        }
        let track = model.project.tracks[1].id
        #expect(ids.contains("track.\(track).mute") && ids.contains("track.\(track).solo"))
    }
}

@Suite("App options (CTL-030, CTL-023)")
struct AppOptionsTests {
    @Test("CTL-030/CTL-032: --control-socket, or a per-pid socket in Debug only; --engine, --parent-pid; unknown args ignored")
    func parse() {
        let given = AppOptions(arguments: ["app", "--control-socket", "/tmp/x.sock", "--engine", "fake", "--parent-pid", "42",
                                           "-ApplePersistenceIgnoreState", "YES"], isDebug: false)
        #expect(given.controlSocket == "/tmp/x.sock" && given.engine == .fake && given.parentPID == 42 && given.isAutomated)
        let debug = AppOptions(arguments: ["app"], isDebug: true, pid: 77)
        #expect(debug.controlSocket?.hasSuffix("/emberstudio-77.sock") == true && debug.engine == .coreAudio && !debug.isAutomated)
        #expect(AppOptions(arguments: ["app"], isDebug: false).controlSocket == nil, "Release: no socket unless asked")
        #expect(AppOptions(arguments: ["app", "--engine", "warp"], isDebug: false).engine == .coreAudio)
    }
}
