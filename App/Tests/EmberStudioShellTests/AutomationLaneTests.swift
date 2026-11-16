import AppKit
import DAWControl
import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// UI-015 (lanes under tracks, point editing, mode selector, ui.state/ui.perform), AUTO-006
// (mixer gestures record through the window's recorder), AUTO-007 (stopped controls show and edit
// the lane), DW-236 (only automatable params offered). T-075.

@MainActor
private func transport(_ engine: FakeEngine, _ window: ProjectWindowModel, tick: Int64, playing: Bool) {
    if playing { engine.play() } else { engine.stop() }
    engine.setPlayhead(Tick(tick))
    window.pollTransport()
}

@MainActor
@Suite("Automation lanes UI (UI-015, AUTO-006/007, T-075)")
struct AutomationLaneTests {
    @Test("UI-015: expanding a track shows its lanes as rows under it; clips of later tracks move down; hit tests skip lane rows")
    func layoutAndGeometry() throws {
        let (window, _) = try makeWindow(tracks: ["A"])
        window.perform(AddTrack(name: "B", kind: .midi))
        let a = window.project.tracks[0].id, b = window.project.tracks[1].id
        window.perform(AddClip(trackID: b, start: 0, length: 960))
        try #require(window.project.tracks[1].clips.count == 1)
        #expect(window.arrange.geometry.trackRows.isEmpty, "no lanes: track index = row")
        try window.control("track.\(a).automation").action()
        #expect(window.automation.expanded == [a])
        #expect(window.arrange.geometry.trackRows.isEmpty, "expanded without lanes: no rows yet")
        try window.control("track.\(a).automation.add.gain").action()
        try window.control("track.\(a).automation.add.pan").action()
        #expect(window.project.track(a)?.automation.map(\.target) == [.strip(channel: a, param: .gain), .strip(channel: a, param: .pan)])
        #expect(window.store.undoLabel == "Set Automation Mode")
        let g = window.arrange.geometry
        #expect(g.trackRows == [0, 3] && g.rowTotal == 4)
        let lanes = window.automation.layout.lanes
        #expect(lanes.map(\.row) == [1, 2] && lanes.map(\.name) == ["Volume", "Pan"])
        // B's clip is drawn on row 3, and a press there selects it; a press on a lane row doesn't.
        let clip = window.project.tracks[1].clips[0].id
        let rect = g.rect(start: 0, length: 960, row: 1)
        #expect(Double(rect.minY) == g.rowY(3) + 1.0)
        #expect(window.arrange.hitTest(CGPoint(x: rect.midX, y: rect.midY))?.clipID == clip)
        #expect(window.arrange.hitTest(CGPoint(x: 10, y: g.rowY(1) + 30)) == nil)
        #expect(window.arrange.visibleClips.map(\.id) == [clip])
        // Collapsing hides the lanes, the clip goes back to row 1.
        try window.control("track.\(a).automation").action()
        #expect(window.arrange.geometry.trackRows.isEmpty && window.automation.layout.lanes.isEmpty)
    }

    @Test("UI-015: a click on a lane adds a point (snapped, value from height), a drag moves it, ⌥-click deletes; each one undo entry")
    func pointEditing() throws {
        let (window, _) = try makeWindow(tracks: ["A"])
        let a = window.project.tracks[0].id
        let target = ParamTarget.strip(channel: a, param: .gain)
        window.automation.expanded = [a]
        window.automation.addLane(target, on: a)
        let g = window.arrange.geometry
        let rect = window.automation.valueRect(row: 1, geometry: g)
        // Beat 2 at 32 points per beat is x = 32; snapping (beat) takes x = 35 there.
        window.arrange.mouseDown(at: CGPoint(x: 35, y: rect.midY))
        window.arrange.mouseUp(at: CGPoint(x: 35, y: rect.midY))
        var lane = try #require(window.project.automationLane(for: target)?.lane)
        #expect(lane.points.count == 1 && lane.points[0].tick == 960 && abs(lane.points[0].value - 0.5) < 0.01)
        #expect(window.store.undoLabel == "Add Automation Point")
        // Drag it a beat right and to the top: one "Move Automation Point" entry.
        let p = CGPoint(x: 32, y: window.automation.y(of: lane.points[0].value, row: 1, geometry: g))
        window.arrange.mouseDown(at: p)
        #expect(window.automation.isDragging)
        window.arrange.mouseDragged(to: CGPoint(x: 50, y: p.y - 10))
        window.arrange.mouseDragged(to: CGPoint(x: 64, y: rect.minY - 20))
        #expect(window.automation.activeGesture == "Move Automation Point")
        window.arrange.mouseUp(at: CGPoint(x: 64, y: rect.minY - 20))
        lane = try #require(window.project.automationLane(for: target)?.lane)
        #expect(lane.points == [AutomationPoint(tick: 1920, value: 1)])
        #expect(window.store.undoLabel == "Move Automation Point")
        window.store.undo()
        #expect(window.project.automationLane(for: target)?.lane.points.map(\.tick) == [960])
        window.store.redo()
        // ⌥-click deletes.
        window.arrange.mouseDown(at: CGPoint(x: 64, y: rect.minY), modifiers: .option)
        window.arrange.mouseUp(at: CGPoint(x: 64, y: rect.minY))
        #expect(window.project.automationLane(for: target)?.lane.points.isEmpty == true)
        #expect(window.store.undoLabel == "Delete Automation Point")
    }

    @Test("UI-015, UI-052: ui.state lists lanes and recording passes; ui.perform expands, sets the mode, adds a point, removes the lane")
    func uiStateAndPerform() async throws {
        let t = TestApp()
        let window = t.app.newProject()
        window.perform(AddTrack(name: "Gtr", kind: .audio))
        window.perform(AddBus(name: "Verb"))
        let track = window.project.tracks[0].id
        window.perform(AddSend(channelID: track, busID: window.project.buses[0].id))
        let send = window.project.tracks[0].sends[0].id
        let d = t.app.dispatcher
        _ = try await d.call(.uiPerform, ["accessibilityId": .string("track.\(track).automation"), "action": "on"])
        _ = try await d.call(.uiPerform, ["accessibilityId": .string("track.\(track).automation.add.send.\(send)"), "action": "click"])
        var state = try await d.call(.uiState)
        var automation = try #require(state["windows"]?[0]?["automation"])
        #expect(automation["expandedTracks"] == [.int(Int64(track))])
        let lane = try #require(automation["lanes"]?[0])
        let laneID = try #require(lane["id"]?.int64Value)
        #expect(lane["name"] == "Send → Verb" && lane["mode"] == "read" && lane["row"] == 1)
        #expect(lane["target"] == ["kind": "sendLevel", "send": .int(Int64(send))])
        #expect(lane["controls"]?.arrayValue?.contains(.string("automation.lane.\(laneID).mode.touch")) == true)
        _ = try await d.call(.uiPerform, ["accessibilityId": .string("automation.lane.\(laneID).mode.latch"), "action": "on"])
        _ = try await d.call(.uiPerform, ["accessibilityId": .string("automation.lane.\(laneID).addPoint"), "action": "click"])
        state = try await d.call(.uiState)
        automation = try #require(state["windows"]?[0]?["automation"])
        #expect(automation["lanes"]?[0]?["mode"] == "latch")
        #expect(automation["lanes"]?[0]?["points"]?.arrayValue?.count == 1)
        // The point holds the send's own level (1 = 0 dB → 5/6) at the playhead (0).
        #expect((automation["lanes"]?[0]?["points"]?[0]?["value"]?.doubleValue).map { abs($0 - 5.0 / 6) < 1e-5 } == true)
        #expect(automation["allLanes"]?.arrayValue?.count == 1 && automation["recording"] == [])
        _ = try await d.call(.uiPerform, ["accessibilityId": .string("automation.lane.\(laneID).remove"), "action": "click"])
        #expect(window.project.track(track)?.automation.isEmpty == true)
    }

    @Test("DW-236: the + Lane menu offers strip, sends and only the automatable params of built-in devices")
    func onlyAutomatable() throws {
        ParamCatalog.registerBuiltin(ParamCatalog(engine: try EngineClient(.offline())))
        let (window, _) = try makeWindow(tracks: ["A"])
        let a = window.project.tracks[0].id
        window.perform(InsertDevice(channel: a, device: .builtin(.eq)))
        let eq = try #require(window.project.tracks[0].inserts.first?.id)
        window.automation.expanded = [a]
        let keys = Set(window.automation.choices(for: window.project.tracks[0]).map(\.key))
        #expect(keys.isSuperset(of: ["gain", "pan", "mute", "device.\(eq).1", "device.\(eq).5"]))
        for off in [0, 3, 7, 11, 15, 19] { #expect(!keys.contains("device.\(eq).\(off)"), "EQ band switch \(off)") }
        #expect(window.automation.name(of: .device(slot: eq, index: 1)) == "Eq HP Freq")
    }

    @Test("AUTO-006: a mixer fader drag while playing on a touch lane records one RecordAutomation at release; static gain unchanged")
    func mixerTouchRecords() throws {
        let (window, engine) = try makeWindow(tracks: ["A"])
        let a = window.project.tracks[0].id
        let target = ParamTarget.strip(channel: a, param: .gain)
        window.perform(AddAutomationPoints(target: target, points: [AutomationPoint(tick: 0, value: 5.0 / 6)]))
        window.perform(SetAutomationMode(target: target, mode: .touch))
        window.bottomPane = .mixer
        transport(engine, window, tick: 960, playing: true)
        window.mixer.beginDrag(.gain(a))
        window.mixer.updateDrag(.gain(a), position: 0.5)  // −12 dB
        #expect(window.automation.recorder?.isRecording(target) == true)
        #expect(engine.suspendedLanes.count == 1)
        let shown = try #require(window.mixer.strips.first { $0.id == a })
        #expect(abs(shown.gain - FaderTaper.gain(position: 0.5)) < 1e-4, "the strip shows the gesture")
        engine.setPlayhead(1440)
        window.mixer.updateDrag(.gain(a), position: 0.25)  // −30 dB
        engine.setPlayhead(1920)
        window.mixer.endDrag()
        #expect(engine.suspendedLanes.isEmpty)
        #expect(window.store.undoLabel == "Record Automation")
        #expect(window.project.track(a)?.strip.gain == 1, "the document's own gain doesn't move")
        let lane = try #require(window.project.automationLane(for: target)?.lane)
        let m = window.project.automationMapping(for: target)
        #expect(abs(lane.value(at: 960)! - m.normalize(FaderTaper.gain(position: 0.5))) < 1e-4)
        #expect(abs(lane.value(at: 1920)! - m.normalize(FaderTaper.gain(position: 0.25))) < 1e-4)
        #expect(abs(lane.value(at: 2400)! - 5.0 / 6) < 1e-6, "touch: back to the lane after release")
        window.store.undo()
        #expect(window.project.automationLane(for: target)?.lane.points.count == 1)
    }

    @Test("AUTO-007: stopped, the fader shows the lane at the playhead; a drag edits the point under the playhead, else SetParam holds until the playhead moves")
    func mixerStopped() throws {
        let (window, engine) = try makeWindow(tracks: ["A"])
        let a = window.project.tracks[0].id
        let target = ParamTarget.strip(channel: a, param: .gain)
        let m = window.project.automationMapping(for: target)
        window.perform(AddAutomationPoints(target: target, points: [AutomationPoint(tick: 0, value: 0.5), AutomationPoint(tick: 960, value: 0.75)]))
        window.bottomPane = .mixer
        transport(engine, window, tick: 960, playing: false)
        #expect(abs(try #require(window.mixer.strips.first { $0.id == a }).gain - m.denormalize(0.75)) < 1e-5)
        // A point at the playhead: the drag moves its value, one undo entry; the document's gain stays.
        window.mixer.beginDrag(.gain(a))
        window.mixer.updateDrag(.gain(a), position: 0.75)
        window.mixer.updateDrag(.gain(a), position: 0.8)
        window.mixer.endDrag()
        let lane = try #require(window.project.automationLane(for: target)?.lane)
        #expect(abs(lane.points[1].value - m.normalize(FaderTaper.gain(position: 0.8))) < 1e-5)
        #expect(window.project.track(a)?.strip.gain == 1)
        window.store.undo()
        #expect(window.project.automationLane(for: target)?.lane.points[1].value == 0.75)
        // No point at the playhead: a plain SetParam, shown until the playhead moves.
        transport(engine, window, tick: 480, playing: false)
        window.mixer.beginDrag(.gain(a))
        window.mixer.updateDrag(.gain(a), position: 0.9)
        window.mixer.endDrag()
        let set = FaderTaper.gain(position: 0.9)
        #expect(window.project.track(a)?.strip.gain == set && window.store.undoLabel == "Set Gain")
        #expect(abs(try #require(window.mixer.strips.first { $0.id == a }).gain - set) < 1e-6)
        transport(engine, window, tick: 600, playing: false)
        #expect(abs(try #require(window.mixer.strips.first { $0.id == a }).gain - m.denormalize(window.project.automationLane(for: target)!.lane.value(at: 600)!)) < 1e-5)
    }

    @Test("UI-015: the canvas draws lane rows (curve and points) in its tiles and the snapshot")
    func canvasDrawsLanes() throws {
        let t = TestApp()
        let manager = realWindowManager(for: t.app)
        let window = t.app.newProject()
        defer { manager.close(window) }
        window.perform(AddTrack(name: "A", kind: .audio))
        let a = window.project.tracks[0].id
        let target = ParamTarget.strip(channel: a, param: .gain)
        window.perform(AddAutomationPoints(target: target, points: [AutomationPoint(tick: 0, value: 0), AutomationPoint(tick: 3840, value: 1)]))
        window.automation.expanded = [a]
        let content = try #require(manager.nsWindow(for: window)?.contentView)
        content.layoutSubtreeIfNeeded()
        let view = try #require(findCanvas(content))
        view.displayNow()
        let image = try #require(view.snapshotImage(scale: 1))
        let g = window.arrange.geometry
        // The curve rises across the lane row: orange near the bottom at the start, near the top a bar later.
        let x1 = Int(g.x(Tick(3840 / 8))), x2 = Int(g.x(Tick(3840 * 7 / 8)))
        func orangeRow(_ x: Int) -> Int? {
            let rep = NSBitmapImageRep(cgImage: image)
            for y in Int(g.rowY(1))..<Int(g.rowY(2)) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.8 && c.greenComponent > 0.4 && c.greenComponent < 0.8 && c.blueComponent < 0.3 { return y }
            }
            return nil
        }
        let y1 = try #require(orangeRow(x1)), y2 = try #require(orangeRow(x2))
        #expect(y1 > y2, "the curve rises: \(y1) → \(y2)")
    }

    private func findCanvas(_ root: NSView) -> TimelineCanvasView? {
        if let canvas = root as? TimelineCanvasView { return canvas }
        for view in root.subviews { if let found = findCanvas(view) { return found } }
        return nil
    }
}
