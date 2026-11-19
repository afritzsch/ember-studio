import AppKit
import DAWControl
import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// UI-017: the track list context menu (New Audio/MIDI Track below the clicked track or appended,
// Rename…, Delete; one undo entry each; control ids per UI-052). UI-018: Insert MIDI Clip (a
// double-click on an empty MIDI lane or the canvas menu item: snapped-down start, one bar of the
// signature in force, clipped to the next clip, nothing if less than a grid step fits, opens the
// piano roll, one undo entry).
//
// Geometry (as in ArrangeModelTests): 32 px per beat, so 1 px = 30 ticks and a 4/4 bar is 128 px.
// The ruler is 22 px; row 0 (A, audio) spans y 22…86, row 1 (B, audio) 86…150, row 2 (M, MIDI)
// 150…214; under it is the empty space under the tracks.

@MainActor
private func makeTracks() throws -> (ProjectWindowModel, FakeEngine, a: NodeIDValue, b: NodeIDValue, m: NodeIDValue) {
    let (window, engine, _) = try makeArrange()
    window.arrange.viewSize = CGSize(width: 1000, height: 400)
    let ids = window.project.tracks.map(\.id)
    return (window, engine, ids[0], ids[1], ids[2])
}

/// The y in the middle of row `row` (no lanes or take rows).
private func rowMid(_ row: Int) -> Double { 22 + Double(row) * 64 + 32 }

@MainActor
private func hostWindow(size: NSSize = NSSize(width: 220, height: 400)) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
    return window
}

/// A mouse event at view point `p` of a flipped view filling `window`'s content.
@MainActor
private func event(_ type: NSEvent.EventType, flippedPoint p: CGPoint, in window: NSWindow,
                   modifiers: NSEvent.ModifierFlags = [], clicks: Int = 1) throws -> NSEvent {
    let height = window.contentView?.bounds.height ?? 0
    return try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: height - p.y), modifierFlags: modifiers,
                                           timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: clicks, pressure: 1))
}

@MainActor
@Suite("Track list menu and Insert MIDI Clip (UI-017, UI-018)")
struct TrackListMenuTests {
    // MARK: UI-017

    @Test("UI-017, UI-052: on a track header the menu is New Audio Track, New MIDI Track, separator, Rename…, Delete; on empty space the two New items")
    func menuItems() throws {
        let (window, _, a, b, m) = try makeTracks()
        let items = window.trackListMenu(for: b)
        #expect(items.map(\.control.id) == ["track.\(b).menu.addAudio", "track.\(b).menu.addMidi", "track.\(b).menu.rename",
                                             "track.\(b).menu.delete"])
        #expect(items.map(\.control.label) == ["New Audio Track", "New MIDI Track", "Rename…", "Delete"])
        #expect(items.map(\.separatorBefore) == [false, false, true, false])
        let empty = window.trackListMenu(for: nil)
        #expect(empty.map(\.control.id) == ["tracks.menu.addAudio", "tracks.menu.addMidi"])
        #expect(empty.map(\.control.label) == ["New Audio Track", "New MIDI Track"])
        // UI-052: every id is a window control (so ui.perform reaches it), and ids stay unique.
        let ids = window.controls.map(\.id)
        for track in [a, b, m] {
            for action in ["addAudio", "addMidi", "rename", "delete"] { #expect(ids.contains("track.\(track).menu.\(action)")) }
        }
        #expect(ids.contains("tracks.menu.addAudio") && ids.contains("tracks.menu.addMidi"))
        #expect(Set(ids).count == ids.count)
        // As an NSMenu (header column and canvas share it): the same titles, ids, separator.
        let menu = TimelineCanvasView.trackListMenu(window, for: b)
        #expect(menu.items.map(\.title) == ["New Audio Track", "New MIDI Track", "", "Rename…", "Delete"])
        #expect(menu.items[2].isSeparatorItem)
        #expect(menu.items[0].accessibilityIdentifier() == "track.\(b).menu.addAudio")
    }

    @Test("UI-017: New Audio/MIDI Track on a header inserts below that track (AddTrack index + 1), named as ⌘T/⇧⌘T name, selected; one undo entry")
    func insertBelow() throws {
        let (window, _, a, b, m) = try makeTracks()
        try window.control("track.\(a).menu.addMidi").action()
        #expect(window.project.tracks.map(\.name) == ["A", "MIDI 2", "B", "M"], "⇧⌘T's name: the second MIDI track")
        let added = window.project.tracks[1]
        #expect(added.kind == .midi && window.selectedTracks == [added.id])
        #expect(window.store.undoLabel == "Add Track")
        window.store.undo()
        #expect(window.project.tracks.map(\.id) == [a, b, m], "one undo entry removes it")
        // On the last track's header: inserted at the end, below it.
        try window.control("track.\(m).menu.addAudio").action()
        #expect(window.project.tracks.map(\.name) == ["A", "B", "M", "Audio 3"])
        #expect(window.project.tracks[3].kind == .audio && window.selectedTracks == [window.project.tracks[3].id])
        // The colour is the one AddTrack gives without one, as ⌘T: same as the shortcut's track would get.
        window.store.undo()
        try window.control("track.add.audio").action()
        let shortcutColor = window.project.tracks[3].color
        window.store.undo()
        try window.control("track.\(m).menu.addAudio").action()
        #expect(window.project.tracks[3].color == shortcutColor)
    }

    @Test("UI-017: on empty space New Audio/MIDI Track append (index nil) and select the new track; one undo entry")
    func appendOnEmptySpace() throws {
        let (window, _, a, b, m) = try makeTracks()
        try window.control("tracks.menu.addAudio").action()
        #expect(window.project.tracks.map(\.name) == ["A", "B", "M", "Audio 3"])
        #expect(window.selectedTracks == [window.project.tracks[3].id])
        try window.control("tracks.menu.addMidi").action()
        #expect(window.project.tracks.map(\.name) == ["A", "B", "M", "Audio 3", "MIDI 2"])
        window.store.undo()
        window.store.undo()
        #expect(window.project.tracks.map(\.id) == [a, b, m])
    }

    @Test("UI-017: a secondary click's target: the header under it (lane and take rows count as their track's), none in the ruler or under the last track; it selects the track")
    func target() throws {
        let (window, _, a, b, m) = try makeTracks()
        #expect(window.trackListTarget(atY: 10) == nil, "ruler")
        #expect(window.trackListTarget(atY: rowMid(0)) == a)
        #expect(window.trackListTarget(atY: rowMid(1)) == b)
        #expect(window.trackListTarget(atY: rowMid(2)) == m)
        #expect(window.trackListTarget(atY: rowMid(3)) == nil, "under the last header")
        // Scrolled by a row: row 0 is now B.
        window.scrollY = 64
        #expect(window.trackListTarget(atY: rowMid(0)) == b)
        window.scrollY = 0
        // An expanded automation lane under A: its header row belongs to A, and B moves down a row.
        window.automation.expanded = [a]
        window.automation.addLane(.strip(channel: a, param: .gain), on: a)
        #expect(window.trackListTarget(atY: rowMid(1)) == a)
        #expect(window.trackListTarget(atY: rowMid(2)) == b)
        #expect(window.trackListTarget(atY: rowMid(4)) == nil)
        window.trackListMenuOpened(on: b)
        #expect(window.selectedTracks == [b])
        window.trackListMenuOpened(on: nil)
        #expect(window.selectedTracks == [b], "empty space leaves the selection")
    }

    @Test("UI-017: the header column's AppKit view: a right-click (two-finger tap) shows the NSMenu for the header under it and selects that track; ⌃-click counts; other events pass through")
    func headerColumnView() throws {
        let (window, _, _, b, _) = try makeTracks()
        let host = hostWindow()
        defer { host.close() }
        let view = TrackListMenuView(model: window)
        view.frame = host.contentView!.bounds
        host.contentView!.addSubview(view)
        let right = try event(.rightMouseDown, flippedPoint: CGPoint(x: 50, y: rowMid(1)), in: host)
        #expect(TrackListMenuView.isSecondaryClick(right))
        let menu = try #require(view.menu(for: right))
        #expect(menu.items.map(\.title) == ["New Audio Track", "New MIDI Track", "", "Rename…", "Delete"])
        #expect(menu.items[0].accessibilityIdentifier() == "track.\(b).menu.addAudio")
        #expect(window.selectedTracks == [b], "the secondary click selects the clicked track")
        // A menu item runs the control's action: Delete removes B.
        let delete = try #require(menu.items.last)
        menu.performActionForItem(at: menu.index(of: delete))
        #expect(window.project.track(b) == nil)
        // Under the last header: the empty-space menu.
        let below = try #require(view.menu(for: try event(.rightMouseDown, flippedPoint: CGPoint(x: 50, y: 300), in: host)))
        #expect(below.items.map(\.title) == ["New Audio Track", "New MIDI Track"])
        #expect(below.items[0].accessibilityIdentifier() == "tracks.menu.addAudio")
        // ⌃-click is a secondary click; a plain click or a move isn't (the headers under it get those).
        #expect(TrackListMenuView.isSecondaryClick(try event(.leftMouseDown, flippedPoint: .zero, in: host, modifiers: .control)))
        #expect(!TrackListMenuView.isSecondaryClick(try event(.leftMouseDown, flippedPoint: .zero, in: host)))
        #expect(!TrackListMenuView.isSecondaryClick(try event(.mouseMoved, flippedPoint: .zero, in: host)))
    }

    @Test("UI-017, UI-052: Rename… puts the header's name field into editing (track.<id>.name); a commit is one RenameTrack, an empty or unchanged name none; Escape cancels")
    func rename() throws {
        let (window, _, a, b, _) = try makeTracks()
        #expect(window.renameControls.isEmpty)
        try window.control("track.\(b).menu.rename").action()
        #expect(window.renamingTrack == b && window.selectedTracks == [b])
        let field = try window.control("track.\(b).name")
        #expect(field.kind == .textField && field.text == "B")
        #expect(field.commitText?("  Bass  ") == true)
        #expect(window.project.track(b)?.name == "Bass" && window.renamingTrack == nil)
        #expect(window.store.undoLabel == "Rename Track")
        #expect(!window.controls.contains { $0.id == "track.\(b).name" }, "editing ended")
        window.store.undo()
        #expect(window.project.track(b)?.name == "B", "one undo entry")
        // Unchanged or empty: no entry.
        let undoBefore = window.store.undoLabel
        window.beginRenaming(a)
        #expect(window.commitRename(a, to: "A"))
        window.beginRenaming(a)
        #expect(!window.commitRename(a, to: "   "))
        #expect(window.project.track(a)?.name == "A" && window.store.undoLabel == undoBefore && window.renamingTrack == nil)
        // Escape, and a late commit from a field going away after it, change nothing.
        window.beginRenaming(a)
        window.cancelRenaming()
        #expect(window.renamingTrack == nil)
        #expect(!window.commitRename(a, to: "Late"))
        #expect(window.project.track(a)?.name == "A")
    }

    @Test("UI-017: Delete is one RemoveTrack (undo brings the track back); the track and its clips leave the selection")
    func delete() throws {
        let (window, _, a, b, m) = try makeTracks()
        window.perform(AddClip(trackID: m, start: 0, length: 3840))
        let clip = try #require(window.project.track(m)?.clips.first?.id)
        window.selectedTracks = [m]
        window.selectedClips = [clip]
        try window.control("track.\(m).menu.delete").action()
        #expect(window.project.tracks.map(\.id) == [a, b])
        #expect(window.selectedTracks.isEmpty && window.selectedClips.isEmpty)
        #expect(window.store.undoLabel == "Remove Track")
        window.store.undo()
        #expect(window.project.tracks.map(\.id) == [a, b, m] && window.project.track(m)?.clips.map(\.id) == [clip])
    }

    @Test("UI-017: the canvas's empty space under the last track gets the track list's empty-space menu")
    func canvasBelowTracks() throws {
        let (window, _, _, _, _) = try makeTracks()
        let host = hostWindow(size: NSSize(width: 1000, height: 400))
        defer { host.close() }
        let canvas = TimelineCanvasView(model: window.arrange)
        canvas.frame = host.contentView!.bounds
        host.contentView!.addSubview(canvas)
        #expect(window.arrange.isBelowTracks(CGPoint(x: 100, y: 300)))
        #expect(!window.arrange.isBelowTracks(CGPoint(x: 100, y: rowMid(2))))
        let menu = try #require(canvas.menu(for: try event(.rightMouseDown, flippedPoint: CGPoint(x: 100, y: 300), in: host)))
        #expect(menu.items.map(\.title) == ["New Audio Track", "New MIDI Track"])
        menu.performActionForItem(at: 1)
        #expect(window.project.tracks.last?.name == "MIDI 2")
        // An empty audio lane has no menu (as before).
        #expect(canvas.menu(for: try event(.rightMouseDown, flippedPoint: CGPoint(x: 100, y: rowMid(0)), in: host)) == nil)
    }

    // MARK: UI-018

    @Test("UI-018: a double-click on an empty MIDI lane inserts a 1-bar clip at the click snapped down, selects it and opens it in the piano roll; one undo entry")
    func doubleClickInserts() throws {
        let (window, _, _, _, m) = try makeTracks()
        window.bottomPane = .mixer
        // x = 200 → tick 6000 (beat 6.25); snapped down to the beat: 5760.
        #expect(window.arrange.doubleClick(at: CGPoint(x: 200, y: rowMid(2))))
        let clips = try #require(window.project.track(m)?.clips)
        try #require(clips.count == 1)
        guard case .midi(let clip) = clips[0] else { Issue.record("not MIDI"); return }
        #expect(clip.start == 5760 && clip.length == 3840 && clip.notes.isEmpty)
        #expect(window.selectedClips == [clip.id])
        #expect(window.bottomPane == .pianoRoll && window.pianoRoll.clipID == clip.id)
        #expect(window.store.undoLabel == "Add Clip")
        window.store.undo()
        #expect(window.project.track(m)?.clips.isEmpty == true, "one undo entry")
    }

    @Test("UI-018, UI-012: the start snaps down to the snap mode (bar, 1/16); snap off or ⌘ held: the exact tick")
    func snapping() throws {
        let (window, _, _, _, m) = try makeTracks()
        let a = window.arrange
        a.snap = .bar
        #expect(a.midiClipPlacement(on: m, at: 7000, snapping: true)! == (Tick(3840), Tick(3840)))
        a.snap = .sixteenth
        #expect(a.midiClipPlacement(on: m, at: 7000, snapping: true)! == (Tick(6960), Tick(3840)))
        #expect(a.midiClipPlacement(on: m, at: 7000, snapping: false)! == (Tick(7000), Tick(3840)))
        // ⌘ on the double-click turns snapping off: x = 200 → 6000 exactly.
        a.snap = .beat
        #expect(a.doubleClick(at: CGPoint(x: 200, y: rowMid(2)), modifiers: .command))
        #expect(window.project.track(m)?.clips.first?.start == 6000)
        a.snap = .off
        #expect(a.midiClipPlacement(on: m, at: 10_000, snapping: a.isSnapping([]))! == (Tick(10_000), Tick(3840)))
    }

    @Test("UI-018: the length is one bar of the time signature in force at the start (3/4: 2880, 7/8: 3360)")
    func barOfSignature() throws {
        let (window, _, _, _, m) = try makeTracks()
        window.perform(SetTimeSignature(tick: 3840, numerator: 3, denominator: 4))
        window.perform(SetTimeSignature(tick: Tick(3840 + 2880), numerator: 7, denominator: 8))
        let a = window.arrange
        #expect(a.midiClipPlacement(on: m, at: 100, snapping: true)! == (Tick(0), Tick(3840)))
        #expect(a.midiClipPlacement(on: m, at: 4000, snapping: true)! == (Tick(3840), Tick(2880)))
        #expect(a.midiClipPlacement(on: m, at: 7000, snapping: true)! == (Tick(6720), Tick(3360)))
    }

    @Test("UI-018: a clip that would overlap the next one ends where it starts; under one grid step (a beat with snap off) nothing is created; not before the previous clip's end")
    func neighbours() throws {
        let (window, _, _, _, m) = try makeTracks()
        let a = window.arrange
        window.perform(AddClip(trackID: m, start: 3840, length: 960))  // bar 2, beat 1
        // From 0, the bar would run into it: it ends at 3840 (a full bar anyway). From beat 3: ends at 3840.
        #expect(a.midiClipPlacement(on: m, at: 2000, snapping: true)! == (Tick(1920), Tick(1920)))
        // Half a beat left before it: less than a beat (the step) fits → nothing.
        #expect(a.midiClipPlacement(on: m, at: 3400, snapping: false) == nil)
        a.snap = .sixteenth
        #expect(a.midiClipPlacement(on: m, at: 3400, snapping: true)! == (Tick(3360), Tick(480)), "half a beat ≥ a 1/16 step")
        a.snap = .beat
        // Inside a clip: no empty space there.
        #expect(a.midiClipPlacement(on: m, at: 4000, snapping: true) == nil)
        // Right after the clip (it ends at 4800, beat 2 of bar 2): the start snaps down to 4800, a full bar.
        #expect(a.midiClipPlacement(on: m, at: 5000, snapping: true)! == (Tick(4800), Tick(3840)))
        // A clip ending off the grid: the start stays after its end (Clarification T-122).
        window.perform(AddClip(trackID: m, start: 9600, length: 700))  // ends at 10300
        #expect(a.midiClipPlacement(on: m, at: 10_500, snapping: true)! == (Tick(10_300), Tick(3840)))
        // Double-click where nothing fits (⌘: the exact tick 3400, under a beat before the clip)
        // creates nothing and reports no action (the click deselects as before).
        let before = window.project.track(m)?.clips.count
        #expect(!a.doubleClick(at: CGPoint(x: 3400.0 / 30, y: rowMid(2)), modifiers: .command))
        #expect(window.project.track(m)?.clips.count == before)
    }

    @Test("UI-018: a double-click on an audio track's empty space, an automation lane, or under the tracks creates nothing")
    func notOnOtherRows() throws {
        let (window, _, a, _, m) = try makeTracks()
        let arrange = window.arrange
        #expect(!arrange.doubleClick(at: CGPoint(x: 200, y: rowMid(0))), "audio track")
        #expect(!arrange.doubleClick(at: CGPoint(x: 200, y: 300)), "under the tracks")
        #expect(arrange.emptyMidiLane(at: CGPoint(x: 200, y: 10)) == nil, "ruler")
        #expect(window.project.tracks.allSatisfy { $0.clips.isEmpty })
        // An automation lane under the MIDI track: its row isn't the track's lane.
        window.automation.expanded = [m]
        window.automation.addLane(.strip(channel: m, param: .gain), on: m)
        #expect(arrange.emptyMidiLane(at: CGPoint(x: 200, y: rowMid(3))) == nil)
        _ = arrange.doubleClick(at: CGPoint(x: 200, y: rowMid(3)))
        #expect(window.project.track(m)?.clips.isEmpty == true)
        #expect(arrange.emptyMidiLane(at: CGPoint(x: 200, y: rowMid(2))) == m)
        _ = a
    }

    @Test("UI-018: the canvas menu on an empty MIDI lane has Insert MIDI Clip with the same rules at the clicked spot (disabled when nothing fits)")
    func canvasMenuItem() throws {
        let (window, _, _, _, m) = try makeTracks()
        let host = hostWindow(size: NSSize(width: 1000, height: 400))
        defer { host.close() }
        let canvas = TimelineCanvasView(model: window.arrange)
        canvas.frame = host.contentView!.bounds
        host.contentView!.addSubview(canvas)
        let menu = try #require(canvas.menu(for: try event(.rightMouseDown, flippedPoint: CGPoint(x: 200, y: rowMid(2)), in: host)))
        #expect(menu.items.map(\.title) == ["Insert MIDI Clip"])
        #expect(menu.items[0].isEnabled)
        menu.performActionForItem(at: 0)
        let clip = try #require(window.project.track(m)?.clips.first)
        #expect(clip.start == 5760 && clip.length == 3840)
        #expect(window.selectedClips == [clip.id] && window.pianoRoll.clipID == clip.id)
        // On the new clip: the clip menu, not Insert.
        let onClip = try #require(canvas.menu(for: try event(.rightMouseDown, flippedPoint: CGPoint(x: 200, y: rowMid(2)), in: host)))
        #expect(!onClip.items.map(\.title).contains("Insert MIDI Clip"))
        // Just before it with ⌘ (no snap), less than a beat free: the item is there but disabled.
        let tight = try #require(canvas.menu(for: try event(.rightMouseDown, flippedPoint: CGPoint(x: 5760.0 / 30 - 10, y: rowMid(2)),
                                                             in: host, modifiers: .command)))
        #expect(tight.items.map(\.title) == ["Insert MIDI Clip"] && !tight.items[0].isEnabled)
    }

    @Test("UI-018, UI-052: track.<id>.insertMidiClip (MIDI tracks only) inserts at the playhead with the same rules; disabled where nothing fits")
    func controlAtPlayhead() throws {
        let (window, engine, a, _, m) = try makeTracks()
        #expect(!window.controls.contains { $0.id == "track.\(a).insertMidiClip" }, "audio tracks have none")
        engine.locate(Tick(2000))
        window.pollTransport()
        try window.control("track.\(m).insertMidiClip").action()
        let clip = try #require(window.project.track(m)?.clips.first)
        #expect(clip.start == 1920 && clip.length == 3840)
        #expect(window.selectedClips == [clip.id] && window.pianoRoll.clipID == clip.id)
        #expect(window.store.undoLabel == "Add Clip")
        // The playhead is inside the new clip now: nothing fits, so the control is disabled.
        #expect(try window.control("track.\(m).insertMidiClip").isEnabled == false)
    }
}
