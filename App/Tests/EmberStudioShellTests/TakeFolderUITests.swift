import AppKit
import DAWControl
import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// UI-016 (T-081): take folders in the arrange view. Collapsed, a folder shows as its comp with a
// disclosure; expanded, one row per take (pass) with the comp's parts highlighted; swiping a range
// on a take row comps it (REC-033 `SetCompSelection`, one undo entry per swipe); a click uses the
// take for the whole folder; a folder can be deleted (`RemoveTakeFolder`). Take rows live next to
// T-075's lane rows (UI-015).
//
// Geometry: 32 px per beat (30 ticks per px), ruler 22 px, rows 64 px. A bar is 3840 ticks = 128 px.

/// Tracks A (audio), B (audio); an 8 s asset; on A a folder of three takes over bar 1: takes 1 and
/// 2 cover the bar, take 3 (a partial last pass) its first half. Default comp (REC-031): take 3 on
/// [0, 1920), take 2 on [1920, 3840).
@MainActor
private func makeFolder(_ window: ProjectWindowModel, engine: FakeEngine? = nil) throws -> (folder: ModelID, takes: [ModelID]) {
    let asset = window.project.ids.next
    if let engine { _ = engine.loadAsset(asset, path: "/tmp/takes.caf") }
    window.perform(ImportAsset(asset: AssetRef(id: asset, path: "/tmp/takes.caf", channels: 1, originalSampleRate: 48_000,
                                               frames: 8 * 48_000)))
    if let engine { window.engineEventsArrived(engine.pollEvents()) }
    let a = window.project.tracks[0].id
    try window.store.perform(CreateTakeFolder(trackID: a, takes: [
        .init(start: 0, length: 3840, assetID: asset, sourceOffsetSamples: 0),
        .init(start: 0, length: 3840, assetID: asset, sourceOffsetSamples: 96_000),
        .init(start: 0, length: 1920, assetID: asset, sourceOffsetSamples: 192_000),
    ]))
    let folder = try #require(window.project.tracks[0].takeFolders.first)
    return (folder.id, folder.takes.map(\.id))
}

@MainActor
private func comp(_ window: ProjectWindowModel, _ folder: ModelID) -> [[Int64]] {
    (window.project.takeFolder(folder)?.comp ?? []).map { [$0.start.raw, $0.end.raw, Int64($0.take)] }
}

@MainActor
@Suite("Take folders UI (UI-016, REC-033, T-081)")
struct TakeFolderUITests {
    @Test("DW-270: ui.state visibleTracks/visibleRowCount count the rows shown: track rows, expanded automation lanes and take rows")
    func visibleTracksCountLaneAndTakeRows() throws {
        let (window, _) = try makeWindow(tracks: ["A", "B", "C"])
        window.arrange.viewSize = CGSize(width: 1000, height: 22 + 3 * 64)  // viewport: three rows
        let ids = window.project.tracks.map(\.id)
        #expect(window.visibleTracks == ids && window.visibleRowCount == 3)
        let (folder, _) = try makeFolder(window)
        // A's three take rows push B and C out of view.
        try window.control("takeFolder.\(folder).expand").action()
        #expect(window.visibleTracks == [ids[0]] && window.visibleRowCount == 3)
        window.scrollY = 3 * 64  // past A and its first two take rows: take 3, B, C
        #expect(window.visibleTracks == [ids[0], ids[1], ids[2]])
        try window.control("takeFolder.\(folder).expand").action()  // collapse
        window.scrollY = 0
        // Two automation lanes under B (track row 1): C is pushed to row 4, out of a three-row view.
        try window.control("track.\(ids[1]).automation").action()
        try window.control("track.\(ids[1]).automation.add.gain").action()
        try window.control("track.\(ids[1]).automation.add.pan").action()
        #expect(window.automation.layout.rowTotal == 5)
        #expect(window.visibleTracks == [ids[0], ids[1]] && window.visibleRowCount == 3)
        window.scrollY = 2 * 64  // B's two lanes and C
        #expect(window.visibleTracks == [ids[1], ids[2]] && window.visibleRowCount == 3)
        let state = UIStateDumper.dump(window, isMain: true)
        #expect(state["visibleTracks"]?.arrayValue?.count == 2 && state["visibleRowCount"]?.int64Value == 3)
        window.scrollY = 10_000
        #expect(window.visibleTracks.isEmpty && window.visibleRowCount == 0)
    }

    @Test("UI-016: collapsed a folder is its comp on the track row; expanding adds one row per take under the track; later tracks move down")
    func layoutAndGeometry() throws {
        let (window, _) = try makeWindow(tracks: ["A", "B"])
        window.arrange.viewSize = CGSize(width: 1000, height: 22 + 6 * 64)
        let (folder, takes) = try makeFolder(window)
        let b = window.project.tracks[1].id
        try window.store.perform(AddClip(trackID: b, start: 0, length: 960, assetID: window.project.assets[0].id))
        let clip = try #require(window.project.tracks[1].clips.first).id
        #expect(comp(window, folder) == [[0, 1920, Int64(takes[2])], [1920, 3840, Int64(takes[1])]], "default comp (REC-031)")

        // Collapsed: no take rows; the folder sits on A's row with its disclosure.
        var g = window.arrange.geometry
        #expect(g.takeBands.isEmpty && window.takes.rows(geometry: g).isEmpty)
        let placement = try #require(window.takes.placements(geometry: g).first)
        #expect(placement.row == 0 && window.takes.folderRect(placement, geometry: g) == g.rect(start: 0, length: 3840, row: 0))
        #expect(window.controls.contains { $0.id == "takeFolder.\(folder).expand" && $0.isOn == false })
        #expect(window.controls.contains { $0.id == "takeFolder.\(folder).remove" })
        #expect(!window.controls.contains { $0.id.hasPrefix("takeFolder.\(folder).take.") }, "take controls only while expanded")
        // The comp is what the folder flattens to (no crossfade overlaps drawn).
        #expect(placement.folder.flattened(tempo: window.project.tempoMap).map(\.start) == [0, 1920])

        // Expanding: three take rows under A; B's clip moves down three rows and still hit-tests.
        try window.control("takeFolder.\(folder).expand").action()
        g = window.arrange.geometry
        #expect(g.takeBands == [.init(row: 0, count: 3)])
        let rows = window.takes.rows(geometry: g)
        #expect(rows.map(\.take.id) == takes && rows.map(\.band) == [1, 2, 3] && rows.map(\.number) == [1, 2, 3])
        #expect(g.rowY(1) == g.slotY(4) && g.slotCount(tracks: 2) == 5)
        let rect = g.rect(start: 0, length: 960, row: 1)
        #expect(Double(rect.minY) == 22 + 4 * 64 + 1)
        #expect(window.arrange.hitTest(CGPoint(x: rect.midX, y: rect.midY))?.clipID == clip)
        #expect(window.arrange.visibleClips.map(\.id) == [clip])
        // A take row isn't a clip; it is a take row.
        let take2Y = g.takeRowY(row: 0, take: 2) + 30
        #expect(window.arrange.hitTest(CGPoint(x: 40, y: take2Y)) == nil)
        #expect(window.takes.takeRowHit(CGPoint(x: 40, y: take2Y), geometry: g)?.take.id == takes[1])
        #expect(g.row(atY: take2Y) == 0 && g.rowAndTake(ofSlot: g.slot(atY: take2Y)) == (0, 2))
        // The content scrolls over the take rows too.
        window.arrange.viewSize = CGSize(width: 1000, height: 22 + 2 * 64)
        window.arrange.scroll(dx: 0, dy: 10_000)
        #expect(window.scrollY == 3 * 64)
        window.scrollY = 0
        // ui-visible take rows and the take controls.
        #expect(window.controls.contains { $0.id == "takeFolder.\(folder).take.\(takes[0]).select" })
        #expect(window.takes.rows(of: window.project.tracks[0].id).count == 3)

        // Collapsing by the canvas triangle.
        let box = window.takes.disclosureRect(placement, geometry: g)
        let label = window.store.undoLabel
        window.arrange.mouseDown(at: CGPoint(x: box.midX, y: box.midY))
        window.arrange.mouseUp(at: CGPoint(x: box.midX, y: box.midY))
        #expect(window.takes.expanded.isEmpty && window.arrange.geometry.takeBands.isEmpty)
        #expect(window.store.undoLabel == label, "expanding is view state, not an edit")
    }

    @Test("UI-016, UI-015: take rows and automation lane rows under one track, and lanes of later tracks, keep working together")
    func withAutomationLanes() throws {
        let (window, _) = try makeWindow(tracks: ["A", "B"])
        window.arrange.viewSize = CGSize(width: 1000, height: 22 + 8 * 64)
        let (folder, takes) = try makeFolder(window)
        let a = window.project.tracks[0].id, b = window.project.tracks[1].id
        let gainA = ParamTarget.strip(channel: a, param: .gain), panB = ParamTarget.strip(channel: b, param: .pan)
        window.automation.addLane(gainA, on: a)
        window.automation.addLane(panB, on: b)
        window.takes.expanded = [folder]
        let g = window.arrange.geometry
        // Rows: A 0, A's lane 1, B 2, B's lane 3. Slots: A 0, takes 1…3, A's lane 4, B 5, B's lane 6.
        #expect(g.trackRows == [0, 2] && g.rowTotal == 4)
        #expect(g.takeBands == [.init(row: 0, count: 3)])
        #expect(g.rowY(1) == g.slotY(4) && g.rowY(2) == g.slotY(5) && g.rowY(3) == g.slotY(6))
        // A press on A's lane adds a point there; a press on take row 1 swipes, not a lane edit.
        let laneY = window.automation.valueRect(row: 1, geometry: g).midY
        #expect(window.automation.laneHit(CGPoint(x: 35, y: laneY), geometry: g)?.lane.target == gainA)
        window.arrange.mouseDown(at: CGPoint(x: 35, y: laneY))
        window.arrange.mouseUp(at: CGPoint(x: 35, y: laneY))
        #expect(window.project.automationLane(for: gainA)?.lane.points.map(\.tick) == [960])
        let takeY = g.takeRowY(row: 0, take: 1) + 32
        #expect(window.automation.laneHit(CGPoint(x: 35, y: takeY), geometry: g) == nil)
        window.arrange.mouseDown(at: CGPoint(x: 35, y: takeY))
        #expect(window.takes.isDragging && !window.automation.isDragging)
        window.arrange.mouseUp(at: CGPoint(x: 35, y: takeY))
        #expect(comp(window, folder) == [[0, 3840, Int64(takes[0])]], "a click uses the take for the whole folder")
        // B's lane, below everything, still takes its presses.
        let laneB = window.automation.valueRect(row: 3, geometry: g).midY
        #expect(window.automation.laneHit(CGPoint(x: 64, y: laneB), geometry: g)?.lane.target == panB)
        // The ui.state lane rects follow the slots.
        let state = UIStateDumper.dump(window.automation)
        #expect(state["lanes"]?[1]?["rect"]?["y"]?.doubleValue == g.slotY(6))
    }

    @Test("UI-016, REC-033: a swipe on a take row comps that range (snapped, ⌘ off) as one undo entry; a click uses the take for the whole folder")
    func swipeComping() throws {
        let (window, _) = try makeWindow(tracks: ["A"])
        window.arrange.viewSize = CGSize(width: 1000, height: 22 + 5 * 64)
        window.arrange.snap = .beat
        let (folder, takes) = try makeFolder(window)
        let original = comp(window, folder)
        window.takes.expanded = [folder]
        let g = window.arrange.geometry
        let y1 = g.takeRowY(row: 0, take: 1) + 40
        // Take 1 from beat 2 (x 35 snaps to 960) to beat 4 (x 93 snaps to 2880).
        window.arrange.mouseDown(at: CGPoint(x: 35, y: y1))
        window.arrange.mouseDragged(to: CGPoint(x: 60, y: y1 + 3))
        #expect(window.takes.activeGesture == "Swipe Take")
        window.arrange.mouseDragged(to: CGPoint(x: 93, y: y1 + 40))
        #expect(window.takes.swipe.map { [$0.range.start, $0.range.end] } == [960, 2880])
        #expect(comp(window, folder) == original, "the comp changes once, on mouse up")
        window.arrange.mouseUp(at: CGPoint(x: 93, y: y1 + 40))
        #expect(comp(window, folder) == [[0, 960, Int64(takes[2])], [960, 2880, Int64(takes[0])], [2880, 3840, Int64(takes[1])]])
        #expect(window.store.undoLabel == "Select Take" && window.takes.swipe == nil && window.takes.activeGesture == nil)
        window.store.undo()
        #expect(comp(window, folder) == original, "one undo entry per swipe")
        window.store.redo()

        // A right-to-left swipe with ⌘ (no snap): ticks from the x positions, kept inside take 3 (to 1920).
        let y3 = g.takeRowY(row: 0, take: 3) + 40
        window.arrange.mouseDown(at: CGPoint(x: 100, y: y3), modifiers: .command)
        window.arrange.mouseDragged(to: CGPoint(x: 10, y: y3), modifiers: .command)
        window.arrange.mouseUp(at: CGPoint(x: 10, y: y3), modifiers: .command)
        #expect(comp(window, folder) == [[0, 1920, Int64(takes[2])], [1920, 2880, Int64(takes[0])], [2880, 3840, Int64(takes[1])]])

        // A click (no drag) on take 2 uses it for the whole folder; again changes nothing (no entry).
        let y2 = g.takeRowY(row: 0, take: 2) + 40
        window.arrange.mouseDown(at: CGPoint(x: 50, y: y2))
        window.arrange.mouseUp(at: CGPoint(x: 50, y: y2))
        #expect(comp(window, folder) == [[0, 3840, Int64(takes[1])]])
        window.arrange.mouseDown(at: CGPoint(x: 50, y: y2))
        window.arrange.mouseUp(at: CGPoint(x: 50, y: y2))
        window.store.undo()
        #expect(comp(window, folder) == [[0, 1920, Int64(takes[2])], [1920, 2880, Int64(takes[0])], [2880, 3840, Int64(takes[1])]],
                "the repeated click added no undo entry")
        window.store.redo()
        // A click past a partial take uses it where it exists.
        window.arrange.mouseDown(at: CGPoint(x: 20, y: y3))
        window.arrange.mouseUp(at: CGPoint(x: 20, y: y3))
        #expect(comp(window, folder) == [[0, 1920, Int64(takes[2])], [1920, 3840, Int64(takes[1])]])
        // A double-click on a take row doesn't open anything or select clips.
        #expect(window.arrange.doubleClick(at: CGPoint(x: 20, y: y3)))
        #expect(window.selectedClips.isEmpty)
    }

    @Test("UI-016: the take controls use a take for the whole folder and delete the folder (RemoveTakeFolder, undoable)")
    func controlsAndDelete() throws {
        let (window, _) = try makeWindow(tracks: ["A"])
        let (folder, takes) = try makeFolder(window)
        try window.control("takeFolder.\(folder).expand").action()
        try window.control("takeFolder.\(folder).take.\(takes[0]).select").action()
        #expect(comp(window, folder) == [[0, 3840, Int64(takes[0])]])
        #expect(window.store.undoLabel == "Select Take")
        try window.control("takeFolder.\(folder).remove").action()
        #expect(window.project.tracks[0].takeFolders.isEmpty && window.arrange.geometry.takeBands.isEmpty)
        #expect(window.store.undoLabel == "Remove Take Folder")
        #expect(!window.controls.contains { $0.id.hasPrefix("takeFolder.") })
        window.store.undo()
        #expect(window.project.takeFolder(folder) != nil && comp(window, folder) == [[0, 3840, Int64(takes[0])]])
        #expect(window.arrange.geometry.takeBands == [.init(row: 0, count: 3)], "the restored folder (same ID) is still expanded")
    }

    @Test("UI-016: a MIDI folder expands and comps the same way; its comp keeps each segment's notes")
    func midiFolder() throws {
        let (window, _) = try makeWindow()
        window.perform(AddTrack(name: "Keys", kind: .midi))
        let m = window.project.tracks[0].id
        let note = { (start: Int64, pitch: UInt8) in AddNotes.NoteSpec(start: Tick(start), length: 480, pitch: pitch, velocity: 100) }
        try window.store.perform(CreateTakeFolder(trackID: m, takes: [
            .init(start: 0, length: 3840, notes: [note(0, 60), note(1920, 62)]),
            .init(start: 0, length: 3840, notes: [note(960, 64), note(2880, 65)]),
        ]))
        let folder = try #require(window.project.tracks[0].takeFolders.first)
        window.takes.expanded = [folder.id]
        let g = window.arrange.geometry
        let y = g.takeRowY(row: 0, take: 1) + 40
        window.arrange.mouseDown(at: CGPoint(x: 0, y: y))
        window.arrange.mouseDragged(to: CGPoint(x: 64, y: y))
        window.arrange.mouseUp(at: CGPoint(x: 64, y: y))
        let comped = try #require(window.project.takeFolder(folder.id))
        #expect(comped.comp.map(\.take) == [folder.takes[0].id, folder.takes[1].id] && comped.comp[0].end == 1920)
        let pitches = comped.flattened(tempo: window.project.tempoMap).flatMap { clip -> [UInt8] in
            if case .midi(let midi) = clip { return midi.notes.filter { $0.start.raw >= 0 && $0.start < midi.length }.map(\.pitch) }
            return []
        }
        #expect(pitches == [60, 65])
    }

    @Test("UI-016, UI-050, UI-052: ui.state lists folders, takes and comp; ui.perform expands, swipes a take range, uses a take, deletes the folder")
    func uiStateAndPerform() async throws {
        let t = TestApp()
        let window = t.app.newProject()
        window.perform(AddTrack(name: "Gtr", kind: .audio))
        let (folder, takes) = try makeFolder(window)
        let d = t.app.dispatcher
        var state = try await d.call(.uiState)
        var folders = try #require(state["windows"]?[0]?["takes"]?["folders"])
        #expect(folders[0]?["id"] == .int(Int64(folder)) && folders[0]?["expanded"] == false && folders[0]?["trackName"] == "Gtr")
        #expect(folders[0]?["takes"]?[2]?["rect"] == .null && folders[0]?["takes"]?[2]?["end"] == 1920)
        #expect(folders[0]?["comp"]?[0]?["take"] == .int(Int64(takes[2])))

        _ = try await d.call(.uiPerform, ["accessibilityId": .string("takeFolder.\(folder).expand"), "action": "on"])
        state = try await d.call(.uiState)
        let takesState = try #require(state["windows"]?[0]?["takes"])
        #expect(takesState["expandedFolders"] == [.int(Int64(folder))])
        folders = try #require(takesState["folders"])
        let take1 = try #require(folders[0]?["takes"]?[0])
        #expect(take1["band"] == 1 && take1["rect"]?["y"]?.doubleValue == 22 + 64 + 1)
        let swipeID = try #require(take1["swipe"]?.stringValue)
        #expect(swipeID == "takeFolder.\(folder).take.\(takes[0]).swipe")
        #expect(take1["inComp"] == false && folders[0]?["takes"]?[1]?["inComp"] == true)

        // The swipe: take 1 on [960, 2880); the result carries the new comp; one undo entry.
        let result = try await d.call(.uiPerform, ["accessibilityId": .string(swipeID), "action": "swipe", "start": 960, "end": 2880])
        #expect(result["kind"] == "takeRow" && result["comp"]?.arrayValue?.count == 3)
        #expect(comp(window, folder) == [[0, 960, Int64(takes[2])], [960, 2880, Int64(takes[0])], [2880, 3840, Int64(takes[1])]])
        #expect(window.store.undoLabel == "Select Take")
        _ = try await d.call(.undo)
        #expect(comp(window, folder) == [[0, 1920, Int64(takes[2])], [1920, 3840, Int64(takes[1])]])
        // Clamped to the take (take 3 ends at 1920); out of it, an empty range or a bad id is refused.
        _ = try await d.call(.uiPerform, ["accessibilityId": .string("takeFolder.\(folder).take.\(takes[2]).swipe"), "action": "swipe",
                                          "start": 0, "end": 3840])
        #expect(comp(window, folder) == [[0, 1920, Int64(takes[2])], [1920, 3840, Int64(takes[1])]])
        await #expect(throws: (any Error).self) {
            _ = try await d.call(.uiPerform, ["accessibilityId": .string("takeFolder.\(folder).take.\(takes[2]).swipe"),
                                              "action": "swipe", "start": 2000, "end": 3000])
        }
        await #expect(throws: (any Error).self) {
            _ = try await d.call(.uiPerform, ["accessibilityId": .string(swipeID), "action": "swipe"])
        }
        await #expect(throws: (any Error).self) {
            _ = try await d.call(.uiPerform, ["accessibilityId": "track.1.mute", "action": "swipe", "start": 0, "end": 960])
        }
        // A take for the whole folder, then delete the folder.
        _ = try await d.call(.uiPerform, ["accessibilityId": .string("takeFolder.\(folder).take.\(takes[0]).select"), "action": "click"])
        #expect(comp(window, folder) == [[0, 3840, Int64(takes[0])]])
        _ = try await d.call(.uiPerform, ["accessibilityId": .string("takeFolder.\(folder).remove"), "action": "click"])
        state = try await d.call(.uiState)
        #expect(state["windows"]?[0]?["takes"]?["folders"] == [])
        #expect(window.project.tracks[0].takeFolders.isEmpty)
    }

    @Test("UI-016: the canvas draws the folder band on the track row and the take rows with the comp's parts bright, the rest dimmed")
    func canvasDrawsTakes() throws {
        let t = TestApp()
        let manager = realWindowManager(for: t.app)
        let window = t.app.newProject()
        defer { manager.close(window) }
        window.perform(AddTrack(name: "A", kind: .audio))
        // DW-300 (T-101): unwrapped on its own, so #require checks a FakeEngine rather than the
        // FakeEngine? parameter type (a redundant-#require warning).
        let engine = try #require(t.engines.last)
        let (folder, _) = try makeFolder(window, engine: engine)
        let content = try #require(manager.nsWindow(for: window)?.contentView)
        content.layoutSubtreeIfNeeded()
        let view = try #require(findCanvas(content))
        func snapshot() throws -> NSBitmapImageRep {
            view.displayNow()
            return NSBitmapImageRep(cgImage: try #require(view.snapshotImage(scale: 1)))
        }
        func rgb(_ rep: NSBitmapImageRep, _ x: Double, _ y: Double) -> (r: Double, g: Double, b: Double) {
            let c = rep.colorAt(x: Int(x), y: Int(y))?.usingColorSpace(.sRGB) ?? .magenta
            return (c.redComponent, c.greenComponent, c.blueComponent)
        }
        var rep = try snapshot()
        var g = window.arrange.geometry
        // The folder band (brown) across the folder's top, the outline orange.
        let band = rgb(rep, g.x(Tick(2400)), g.rowY(0) + 6)
        #expect(band.r > band.b + 0.1 && band.r > 0.2, "folder band: \(band)")
        let below = rgb(rep, g.x(Tick(2400)), g.rowY(1) + 30)
        #expect(abs(below.r - below.b) < 0.03, "no take rows while collapsed: \(below)")

        window.takes.expanded = [folder]
        rep = try snapshot()
        g = window.arrange.geometry
        // Take 1 isn't in the comp: dimmed. Take 2 plays [1920, 3840): bright there, dimmed before.
        let y1 = g.takeRowY(row: 0, take: 1) + 50, y2 = g.takeRowY(row: 0, take: 2) + 50
        let dim1 = rgb(rep, g.x(Tick(2400)), y1), bright2 = rgb(rep, g.x(Tick(2400)), y2), dim2 = rgb(rep, g.x(Tick(600)), y2)
        #expect(bright2.b > dim1.b + 0.1 && bright2.b > dim2.b + 0.1, "comp part \(bright2) vs dimmed \(dim1), \(dim2)")
        // The comp part is outlined in the folder colour.
        let edge = rgb(rep, g.x(Tick(2400)), g.takeRowY(row: 0, take: 2) + 2)
        #expect(edge.r > 0.8 && edge.g > 0.5 && edge.b < 0.4, "outline: \(edge)")
    }

    private func findCanvas(_ root: NSView) -> TimelineCanvasView? {
        if let canvas = root as? TimelineCanvasView { return canvas }
        for view in root.subviews { if let found = findCanvas(view) { return found } }
        return nil
    }
}
