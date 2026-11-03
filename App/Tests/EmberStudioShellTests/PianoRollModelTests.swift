import AppKit
import CoreGraphics
import DAWControl
import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// UI-020: the piano roll's view model: open from a MIDI clip, draw/select/move/resize/delete notes,
// velocity lane, quantize (grid, strength), transpose (↑/↓, ⇧ octave); every gesture and action is
// one undo entry. UI-021: auditions go to the engine as previewNote on the clip's track, and every
// note-on gets its note-off. Plus the canvas view (layer-backed tiles, snapshot) and ui.state.
//
// Geometry used throughout: 96 px per beat (1 px = 10 ticks), 12 px keys, an 800 × 330 view: the
// keyboard is x 0…48, the ruler y 0…18, the grid y 18…258 (pitches 72 at the top down to 53 with
// scrollY = 660), the velocity lane y 258…330. The clip starts at bar 2 (tick 3840), scrolled to
// x = 48, so a note at clip tick t sits at x = 48 + t / 10.

private let clipStart: Int64 = 3840

@MainActor
private struct Roll {
    let window: ProjectWindowModel
    let engine: FakeEngine
    let track: ModelID
    let clip: ModelID
    var roll: PianoRollModel { window.pianoRoll }
    var store: ProjectStore { window.store }
    var notes: [Note] { roll.notes }

    func note(_ id: ModelID) -> Note? { notes.first { $0.id == id } }

    /// The view point of clip tick `t`, inside `pitch`'s row (6 px down).
    func point(_ t: Int64, _ pitch: Int, dy: Double = 6) -> CGPoint {
        let g = roll.geometry
        return CGPoint(x: g.x(clipStart + t), y: g.rowY(pitch) + dy)
    }

    /// Adds notes (start, length, pitch[, velocity]) in one command; returns their IDs in order.
    @discardableResult
    func add(_ specs: [(Int64, Int64, UInt8, UInt8)]) throws -> [ModelID] {
        let before = Set(notes.map(\.id))
        try store.perform(AddNotes(clipID: clip, notes: specs.map {
            AddNotes.NoteSpec(start: Tick($0.0), length: Tick($0.1), pitch: $0.2, velocity: $0.3)
        }))
        let added = notes.filter { !before.contains($0.id) }.sorted { $0.id < $1.id }
        return added.map(\.id)
    }

    /// The previewNote calls the engine got, in order.
    var previews: [FakeEngine.Call] {
        engine.calls.filter { if case .previewNote = $0 { true } else { false } }
    }

    func on(_ pitch: UInt8, _ velocity: UInt8 = 100, track: ModelID? = nil) -> FakeEngine.Call {
        .previewNote(track: track ?? self.track, pitch: pitch, velocity: velocity, on: true)
    }

    func off(_ pitch: UInt8, track: ModelID? = nil) -> FakeEngine.Call {
        .previewNote(track: track ?? self.track, pitch: pitch, velocity: 0, on: false)
    }
}

/// A window with a MIDI track "Keys" holding a 2-bar MIDI clip at bar 2, open in the piano roll.
@MainActor
private func makeRoll() throws -> Roll {
    let (window, engine) = try makeWindow()
    window.perform(AddTrack(name: "Keys", kind: .midi))
    let track = try #require(window.project.tracks.last?.id)
    try window.store.perform(AddClip(trackID: track, start: Tick(clipStart), length: Tick(2 * 3840)))
    let clip = try #require(window.project.track(track)?.clips.first?.id)
    window.pianoRoll.open(clip)
    window.pianoRoll.viewSize = CGSize(width: 800, height: 330)
    window.pianoRoll.pixelsPerBeat = 96
    window.pianoRoll.keyHeight = 12
    window.pianoRoll.scrollX = Double(clipStart) / 10
    window.pianoRoll.scrollY = Double(127 - 72) * 12
    window.pianoRoll.snap = .sixteenth
    engine.clearCalls()
    return Roll(window: window, engine: engine, track: track, clip: clip)
}

/// UI-020: the last gesture is one undo entry named `label`: one undo restores `before`. Redoes it.
@MainActor
private func expectOneUndoEntry(_ r: Roll, _ label: String, restores before: Project,
                                sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(r.store.undoLabel == label, sourceLocation: sourceLocation)
    let after = r.store.project
    r.store.undo()
    #expect(r.store.project == before, "one undo takes the whole gesture back", sourceLocation: sourceLocation)
    r.store.redo()
    #expect(r.store.project == after, sourceLocation: sourceLocation)
}

@MainActor
@Suite("Piano roll view model (UI-020, UI-021)")
struct PianoRollModelTests {
    // MARK: Opening

    @Test("UI-020: a double-click on a MIDI clip, P, the open control or the context action opens it; audio clips don't")
    func opensFromAMidiClip() throws {
        let (window, _) = try makeWindow(tracks: ["Audio"])
        window.perform(AddTrack(name: "Keys", kind: .midi))
        let midiTrack = try #require(window.project.tracks.last?.id)
        try window.store.perform(AddClip(trackID: midiTrack, start: 0, length: 3840))
        let clip = try #require(window.project.track(midiTrack)?.clips.first?.id)
        let arrange = window.arrange
        arrange.viewSize = CGSize(width: 1000, height: 22 + 2 * 64)
        #expect(!window.pianoRoll.isOpen)
        #expect(try window.control("pianoRoll.open").isEnabled == false, "nothing selected")

        // A double-click on the MIDI clip (row 1).
        #expect(arrange.doubleClick(at: CGPoint(x: 40, y: 22 + 64 + 30)))
        #expect(window.pianoRoll.clipID == clip && window.bottomPane == .pianoRoll && window.selectedClips == [clip])
        #expect(window.pianoRoll.track?.name == "Keys")
        // Not on empty space.
        #expect(!arrange.doubleClick(at: CGPoint(x: 400, y: 22 + 30)))

        window.pianoRoll.close()
        window.bottomPane = .mixer
        #expect(!window.pianoRoll.isOpen)
        // P (UI-002 key table) runs pianoRoll.open on the selected MIDI clip.
        #expect(window.handleKey(KeyChord("p")))
        #expect(window.pianoRoll.clipID == clip && window.bottomPane == .pianoRoll)
        try window.control("pianoRoll.close").action()
        #expect(!window.pianoRoll.isOpen && window.controls.first { $0.id == "pianoRoll.close" } == nil)
        try window.control("pianoRoll.open").action()
        #expect(window.pianoRoll.clipID == clip)

        // An audio clip doesn't open.
        let asset = window.project.ids.next
        try window.store.perform(ImportAsset(asset: AssetRef(id: asset, path: "/tmp/a.wav", channels: 2, originalSampleRate: 48_000,
                                                             frames: 48_000)))
        try window.store.perform(AddClip(trackID: window.project.tracks[0].id, start: 0, length: 960, assetID: asset))
        let audio = try #require(window.project.tracks[0].clips.first?.id)
        window.pianoRoll.open(audio)
        #expect(window.pianoRoll.clipID == clip)
        window.selectedClips = [audio]
        #expect(try window.control("pianoRoll.open").isEnabled == false)
    }

    @Test("UI-020: opening scrolls to the clip and its notes; a removed clip closes the editor's content")
    func revealsNotes() throws {
        let r = try makeRoll()
        try r.add([(0, 480, 96, 100), (960, 480, 100, 100)])
        r.roll.open(r.clip)
        let g = r.roll.geometry
        let pitches = try #require(g.visiblePitches)
        #expect(pitches.contains(96) && pitches.contains(100))
        #expect(g.x(clipStart) >= PianoRollGeometry.keyboardWidth && g.x(clipStart) < 80)
        try r.store.perform(RemoveClip(clipID: r.clip))
        #expect(!r.roll.isOpen && r.roll.notes.isEmpty)
        r.store.undo()
        #expect(r.roll.isOpen)
    }

    // MARK: Draw, select, move, resize, delete

    @Test("UI-020: drawing a note snaps to the cell's grid line, auditions it, and its drag sets the length; one undo entry")
    func drawsNotes() throws {
        let r = try makeRoll()
        let before = r.store.project
        // Clip tick 1000 (between the 4th and 5th sixteenth), pitch 64: starts at 960, a sixteenth long.
        r.roll.mouseDown(at: r.point(1000, 64))
        let drawn = try #require(r.notes.first)
        #expect(drawn.start == 960 && drawn.length == 240 && drawn.pitch == 64 && drawn.velocity == 100)
        #expect(r.roll.selection == [drawn.id] && r.roll.activeGesture == "Add Note")
        #expect(r.previews == [r.on(64)], "UI-021: the drawn note sounds")
        // Dragging to clip tick 1680 snaps the end to 1680 (a 1/16 line): 720 long.
        for t in stride(from: 1100, through: 1690, by: 30) { r.roll.mouseDragged(to: r.point(Int64(t), 64)) }
        r.roll.mouseUp(at: r.point(1690, 64))
        #expect(r.note(drawn.id)?.length == 720)
        #expect(r.previews == [r.on(64), r.off(64)])
        expectOneUndoEntry(r, "Add Note", restores: before)

        // The next note gets the last length; ⌘ draws off the grid.
        let free = CGPoint(x: r.point(2005, 60).x + 0.05, y: r.point(2005, 60).y)
        r.roll.mouseDown(at: free, modifiers: .command)
        r.roll.mouseUp(at: free)
        let second = try #require(r.notes.first { $0.pitch == 60 })
        #expect(second.start == 2000 && second.length == 720)
        // The select tool drags a marquee instead; a double-click there still draws.
        r.roll.tool = .select
        let count = r.notes.count
        r.roll.mouseDown(at: r.point(3000, 55))
        r.roll.mouseUp(at: r.point(3000, 55))
        #expect(r.notes.count == count)
        r.roll.mouseDown(at: r.point(3000, 55), clickCount: 2)
        r.roll.mouseUp(at: r.point(3000, 55))
        #expect(r.notes.count == count + 1)
    }

    @Test("UI-020: click selects, ⇧-click toggles, a marquee selects what it touches, select all/none")
    func selects() throws {
        let r = try makeRoll()
        let ids = try r.add([(0, 480, 60, 100), (960, 480, 62, 100), (1920, 480, 64, 100)])
        r.roll.tool = .select
        r.roll.mouseDown(at: r.point(100, 60))
        r.roll.mouseUp(at: r.point(100, 60))
        #expect(r.roll.selection == [ids[0]])
        r.roll.mouseDown(at: r.point(1000, 62), modifiers: .shift)
        r.roll.mouseUp(at: r.point(1000, 62), modifiers: .shift)
        #expect(r.roll.selection == [ids[0], ids[1]])
        r.roll.mouseDown(at: r.point(100, 60), modifiers: .shift)
        r.roll.mouseUp(at: r.point(100, 60), modifiers: .shift)
        #expect(r.roll.selection == [ids[1]])
        // A click in empty space clears; a marquee over the 2nd and 3rd notes selects them.
        r.roll.mouseDown(at: r.point(3500, 70))
        #expect(r.roll.selection.isEmpty)
        r.roll.mouseDragged(to: r.point(1500, 63))
        r.roll.mouseDragged(to: r.point(1000, 61))
        #expect(r.roll.marquee != nil && r.roll.activeGesture == "Marquee")
        #expect(r.roll.selection == [ids[1], ids[2]])
        r.roll.mouseUp(at: r.point(1000, 61))
        #expect(r.roll.marquee == nil && r.store.undoLabel == "Add Notes", "a marquee edits nothing")
        try r.window.control("pianoRoll.selectAll").action()
        #expect(r.roll.selection == Set(ids))
        try r.window.control("pianoRoll.deselectAll").action()
        #expect(r.roll.selection.isEmpty)
        try r.window.control("pianoRoll.note.\(ids[2]).select").action()
        #expect(r.roll.selection == [ids[2]])
    }

    @Test("UI-020: a body drag moves the selection in time (snapped, ⌘ free) and pitch; 100 steps are one undo entry")
    func movesNotes() throws {
        let r = try makeRoll()
        let ids = try r.add([(0, 480, 60, 100), (960, 480, 64, 90)])
        r.roll.selection = Set(ids)
        let before = r.store.project
        // Grab the first note's body, drag 1 beat + a bit right and 2 rows up in 100 steps.
        let down = r.point(200, 60)
        r.roll.mouseDown(at: down)
        #expect(r.roll.selection == Set(ids), "pressing a selected note keeps the selection")
        for i in 1...100 {
            let f = Double(i) / 100
            r.roll.mouseDragged(to: CGPoint(x: down.x + f * 100, y: down.y - f * 24))
        }
        #expect(r.roll.activeGesture == "Move Notes")
        r.roll.mouseUp(at: CGPoint(x: down.x + 100, y: down.y - 24))
        // 1000 ticks snaps to 960 (the 1/16 grid at bar 2 + 1000 → 4840 → 4800).
        #expect(r.note(ids[0])?.start == 960 && r.note(ids[0])?.pitch == 62)
        #expect(r.note(ids[1])?.start == 1920 && r.note(ids[1])?.pitch == 66)
        expectOneUndoEntry(r, "Move Notes", restores: before)
        // UI-021: the pressed note sounded, then at each new pitch, and ended at mouse up.
        let previews = r.previews
        #expect(previews.first == r.on(60) && previews.last == r.off(62))
        #expect(previews.contains(r.on(61, 100)) && previews.contains(r.on(62, 100)))

        // ⌘: no snap. Clicking one note of a multi-selection (no drag) selects just it.
        let mid = r.point(1100, 62)
        r.roll.mouseDown(at: mid, modifiers: .command)
        r.roll.mouseDragged(to: CGPoint(x: mid.x + 3.3, y: mid.y), modifiers: .command)
        r.roll.mouseUp(at: CGPoint(x: mid.x + 3.3, y: mid.y), modifiers: .command)
        #expect(r.note(ids[0])?.start == 993 && r.note(ids[1])?.start == 1953)
        r.roll.mouseDown(at: r.point(1100, 62))
        r.roll.mouseUp(at: r.point(1100, 62))
        #expect(r.roll.selection == [ids[0]])
    }

    @Test("UI-020: a move stops at the pitch range and the timeline start")
    func moveClamps() throws {
        let r = try makeRoll()
        let ids = try r.add([(0, 480, 70, 100), (480, 480, 126, 100)])
        r.roll.selection = Set(ids)
        let down = r.point(100, 70)
        r.roll.mouseDown(at: down, modifiers: .command)
        r.roll.mouseDragged(to: CGPoint(x: down.x - 1000, y: down.y - 5 * 12), modifiers: .command)
        r.roll.mouseUp(at: CGPoint(x: down.x - 1000, y: down.y - 5 * 12), modifiers: .command)
        #expect(r.note(ids[1])?.pitch == 127 && r.note(ids[0])?.pitch == 71, "the highest note stops at 127")
        #expect(r.note(ids[0])?.start == -clipStart, "no earlier than the timeline start (before the clip is allowed, DW-127)")
    }

    @Test("UI-020: dragging a note's end or start resizes the selection (snapped, end or start kept); one undo entry each")
    func resizesNotes() throws {
        let r = try makeRoll()
        let ids = try r.add([(0, 480, 60, 100), (960, 240, 62, 100)])
        r.roll.selection = Set(ids)
        var before = r.store.project
        // The first note's right edge (x of tick 480, minus 2 px) dragged 26 px right: 480 + 260 → 720.
        let edge = CGPoint(x: r.point(480, 60).x - 2, y: r.point(480, 60).y)
        #expect(r.roll.hitTest(edge) == .note(id: ids[0], zone: .end))
        r.roll.mouseDown(at: edge)
        r.roll.mouseDragged(to: CGPoint(x: edge.x + 26, y: edge.y))
        r.roll.mouseUp(at: CGPoint(x: edge.x + 26, y: edge.y))
        #expect(r.note(ids[0])?.length == 720 && r.note(ids[1])?.length == 480, "both grow by 240")
        expectOneUndoEntry(r, "Resize Notes", restores: before)
        // Dragged far left, a snapped end keeps one grid step.
        r.roll.selection = [ids[0]]
        r.roll.mouseDown(at: CGPoint(x: r.point(720, 60).x - 2, y: edge.y))
        r.roll.mouseDragged(to: CGPoint(x: edge.x - 300, y: edge.y))
        r.roll.mouseUp(at: CGPoint(x: edge.x - 300, y: edge.y))
        #expect(r.note(ids[0])?.length == 240)

        // The second note's left edge, dragged 24 px left with ⌘ off: the start moves to 720, its end stays.
        r.roll.selection = [ids[1]]
        before = r.store.project
        let start = CGPoint(x: r.point(960, 62).x + 2, y: r.point(960, 62).y)
        #expect(r.roll.hitTest(start) == .note(id: ids[1], zone: .start))
        r.roll.mouseDown(at: start)
        r.roll.mouseDragged(to: CGPoint(x: start.x - 24, y: start.y))
        r.roll.mouseUp(at: CGPoint(x: start.x - 24, y: start.y))
        let resized = try #require(r.note(ids[1]))
        #expect(resized.start == 720 && resized.start.raw + resized.length.raw == 960 + 480)
        expectOneUndoEntry(r, "Resize Note", restores: before)
    }

    @Test("UI-020: ⌫ (focused), the delete control and a double-click delete notes; each one undo entry")
    func deletesNotes() throws {
        let r = try makeRoll()
        let ids = try r.add([(0, 480, 60, 100), (960, 480, 62, 100), (1920, 480, 64, 100), (2880, 480, 66, 100)])
        var before = r.store.project
        r.roll.selection = [ids[0], ids[1]]
        // Unfocused, ⌫ is the arrange view's (no clip selected: nothing happens to notes).
        #expect(!r.window.handleKey(KeyChord(.delete)))
        #expect(r.notes.count == 4)
        r.roll.hasKeyFocus = true
        #expect(r.window.handleKey(KeyChord(.delete)))
        #expect(r.notes.map(\.id) == [ids[2], ids[3]] && r.roll.selection.isEmpty)
        expectOneUndoEntry(r, "Delete Notes", restores: before)
        // A double-click on a note deletes it.
        before = r.store.project
        r.roll.mouseDown(at: r.point(2000, 64))
        r.roll.mouseUp(at: r.point(2000, 64))
        r.roll.mouseDown(at: r.point(2000, 64), clickCount: 2)
        r.roll.mouseUp(at: r.point(2000, 64))
        #expect(r.note(ids[2]) == nil)
        expectOneUndoEntry(r, "Delete Note", restores: before)
        // ⌘A selects every note while focused.
        #expect(r.window.handleKey(KeyChord("a", .command)))
        #expect(r.roll.selection == [ids[3]])
        try r.window.control("pianoRoll.delete").action()
        #expect(r.notes.isEmpty)
    }

    @Test("UI-020: dragging a velocity stem changes the selected notes' velocities (clamped); ± controls; one undo entry")
    func editsVelocity() throws {
        let r = try makeRoll()
        let ids = try r.add([(0, 480, 60, 64), (960, 480, 62, 100), (960, 480, 64, 120)])
        r.roll.selection = [ids[1], ids[2]]
        let before = r.store.project
        let g = r.roll.geometry
        let stem = CGPoint(x: g.x(clipStart + 960), y: g.velocityY(100))
        #expect(r.roll.hitTest(stem) == .velocity(id: ids[1]), "the chord's stem nearest the pointer's height")
        r.roll.mouseDown(at: stem)
        // Up by 10 velocity steps.
        r.roll.mouseDragged(to: CGPoint(x: stem.x, y: stem.y - 10 * g.velocityPointsPerStep))
        r.roll.mouseUp(at: CGPoint(x: stem.x, y: stem.y - 10 * g.velocityPointsPerStep))
        #expect(r.note(ids[1])?.velocity == 110 && r.note(ids[2])?.velocity == 127 && r.note(ids[0])?.velocity == 64)
        expectOneUndoEntry(r, "Note Velocity", restores: before)
        try r.window.control("pianoRoll.velocity.down").action()
        #expect(r.note(ids[1])?.velocity == 100 && r.note(ids[2])?.velocity == 117)
        r.roll.selection = [ids[0]]
        for _ in 0..<10 { try r.window.control("pianoRoll.velocity.down").action() }
        #expect(r.note(ids[0])?.velocity == 1)
        // A press in the lane away from any stem does nothing.
        r.roll.mouseDown(at: CGPoint(x: g.x(clipStart + 3000), y: g.velocityY(64)))
        #expect(r.roll.selection == [ids[0]])
    }

    // MARK: Quantize and transpose

    @Test("UI-020: quantize moves starts toward the grid by the strength, selection or all, lengths kept; one undo entry")
    func quantizes() throws {
        let r = try makeRoll()
        // Off the 1/16 grid (240): +40, −70, +100 (nearest line above).
        let ids = try r.add([(40, 200, 60, 100), (890, 300, 62, 100), (1300, 100, 64, 100)])
        let before = r.store.project
        r.roll.quantizeGrid = .sixteenth
        r.roll.quantizeStrength = 1
        try r.window.control("pianoRoll.quantize").action()
        #expect(r.notes.map(\.start.raw) == [0, 960, 1200])
        #expect(r.notes.map(\.length.raw) == [200, 300, 100])
        expectOneUndoEntry(r, "Quantize", restores: before)
        r.store.undo()

        // 50 % halfway; only the selection.
        try r.window.control("pianoRoll.quantize.strength.50").action()
        #expect(r.roll.quantizeStrength == 0.5)
        r.roll.selection = [ids[1]]
        r.roll.quantize()
        #expect(r.note(ids[1])?.start == 925 && r.note(ids[0])?.start == 40)
        r.store.undo()

        // A coarser grid (beat), all notes.
        r.roll.selection = []
        r.roll.quantizeStrength = 1
        try r.window.control("pianoRoll.quantize.grid.beat").action()
        r.roll.quantize()
        #expect(r.notes.map(\.start.raw).sorted() == [0, 960, 960])
        // Nothing left to move: no undo entry.
        r.roll.quantize()
        #expect(r.store.undoLabel == "Quantize")
        r.store.undo()
        #expect(r.store.undoLabel == "Add Notes")
        // The quantize grid offers no "off".
        #expect(r.window.controls.first { $0.id == "pianoRoll.quantize.grid.off" } == nil)
    }

    @Test("UI-020: ↑/↓ transpose a semitone, ⇧ an octave, as far as the range allows; one undo entry each")
    func transposes() throws {
        let r = try makeRoll()
        let ids = try r.add([(0, 480, 60, 100), (480, 480, 118, 100)])
        #expect(!r.roll.handleArrow(up: true, shift: false), "nothing selected: the arrow goes on")
        r.roll.selection = Set(ids)
        let before = r.store.project
        #expect(r.roll.handleArrow(up: true, shift: false))
        #expect(r.note(ids[0])?.pitch == 61 && r.note(ids[1])?.pitch == 119)
        expectOneUndoEntry(r, "Transpose", restores: before)
        #expect(r.roll.handleArrow(up: false, shift: true))
        #expect(r.note(ids[0])?.pitch == 49 && r.note(ids[1])?.pitch == 107)
        // An octave up from 107 would pass 127 at 119 + 12: it goes as far as it can (+8 from 119).
        try r.window.control("pianoRoll.transpose.octaveUp").action()
        try r.window.control("pianoRoll.transpose.octaveUp").action()
        #expect(r.note(ids[1])?.pitch == 127 && r.note(ids[0])?.pitch == 69)
        let atTop = r.store.project
        try r.window.control("pianoRoll.transpose.up").action()
        #expect(r.store.project == atTop, "already at the top: nothing")
        try r.window.control("pianoRoll.transpose.down").action()
        #expect(r.note(ids[0])?.pitch == 68)
    }

    // MARK: Audition (UI-021)

    @Test("UI-021: keys sound while held and follow a drag; notes sound on click unless audition is off; every on gets its off")
    func auditionsKeysAndNotes() throws {
        let r = try makeRoll()
        let g = r.roll.geometry
        let key = CGPoint(x: 20, y: g.rowY(60) + 6)
        #expect(r.roll.hitTest(key) == .key(pitch: 60))
        r.roll.mouseDown(at: key)
        #expect(r.roll.sounding == [60] && r.roll.auditionTrack == r.track)
        r.roll.mouseDragged(to: CGPoint(x: 20, y: g.rowY(62) + 6))
        r.roll.mouseDragged(to: CGPoint(x: 20, y: g.rowY(62) + 8))  // same key: nothing new
        r.roll.mouseUp(at: CGPoint(x: 20, y: g.rowY(62) + 6))
        #expect(r.previews == [r.on(60), r.off(60), r.on(62), r.off(62)])
        #expect(r.roll.sounding.isEmpty)
        #expect(r.store.undoLabel == "Add Clip", "auditioning edits nothing")

        let id = try #require(try r.add([(0, 480, 65, 77)]).first)
        r.engine.clearCalls()
        r.roll.mouseDown(at: r.point(100, 65))
        r.roll.mouseUp(at: r.point(100, 65))
        #expect(r.previews == [r.on(65, 77), r.off(65)])
        #expect(r.roll.selection == [id])
        // Audition off: a note click is silent (keys still sound).
        try r.window.control("pianoRoll.audition").action()
        r.engine.clearCalls()
        r.roll.mouseDown(at: r.point(100, 65))
        r.roll.mouseUp(at: r.point(100, 65))
        #expect(r.previews.isEmpty)
        r.roll.mouseDown(at: key)
        r.roll.mouseUp(at: key)
        #expect(r.previews == [r.on(60), r.off(60)])
    }

    @Test("UI-021: key toggles hold a note for ui.perform; closing the pane or the clip, another track, a new document end it")
    func auditionAlwaysEnds() throws {
        let r = try makeRoll()
        let keyControl = try r.window.control("pianoRoll.key.64")
        #expect(keyControl.kind == .toggle && keyControl.isOn == false && keyControl.isEnabled)
        keyControl.action()
        #expect(try r.window.control("pianoRoll.key.64").isOn == true && r.previews == [r.on(64)])
        try r.window.control("pianoRoll.key.64").action()
        #expect(r.previews == [r.on(64), r.off(64)])

        // Hiding the pane.
        try r.window.control("pianoRoll.key.64").action()
        r.window.bottomPane = .mixer
        #expect(r.previews.last == r.off(64) && r.roll.sounding.isEmpty)
        r.window.bottomPane = .pianoRoll

        // Opening a clip on another track: the off goes to the track that got the on.
        r.window.perform(AddTrack(name: "Bass", kind: .midi))
        let other = try #require(r.window.project.tracks.last?.id)
        try r.store.perform(AddClip(trackID: other, start: 0, length: 3840))
        let otherClip = try #require(r.window.project.track(other)?.clips.first?.id)
        r.engine.clearCalls()
        try r.window.control("pianoRoll.key.64").action()
        r.roll.open(otherClip)
        #expect(r.previews == [r.on(64), r.off(64, track: r.track)])
        try r.window.control("pianoRoll.key.64").action()
        #expect(r.previews.last == r.on(64, track: other))
        // Closing the editor.
        try r.window.control("pianoRoll.close").action()
        #expect(r.previews.last == r.off(64, track: other))

        // A new document in the window: the off reaches the old engine before the swap.
        r.roll.open(r.clip)
        r.engine.clearCalls()
        try r.window.control("pianoRoll.key.60").action()
        let newStore = ProjectStore(project: Project(name: "Other"))
        newStore.autosavePolicy = nil
        r.window.replace(store: newStore)
        #expect(r.previews == [r.on(60), r.off(60)] && !r.roll.isOpen)
    }

    @Test("UI-021: a drag that ends in a refused step, or a view leaving its window, still ends the audition")
    func auditionEndsWithTheView() throws {
        let r = try makeRoll()
        _ = try r.add([(0, 480, 60, 100)])
        let view = PianoRollView(model: r.roll)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 330), styleMask: [.titled], backing: .buffered,
                              defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        r.roll.mouseDown(at: r.point(100, 60))
        #expect(r.roll.sounding == [60])
        view.removeFromSuperview()
        #expect(r.roll.sounding.isEmpty && r.previews.last == r.off(60))
        window.close()
    }

    // MARK: Controls and ui.state

    @Test("UI-050, UI-052: ui.state reports the piano roll; its controls are unique and listed in the window's")
    func uiState() throws {
        let r = try makeRoll()
        let ids = try r.add([(0, 480, 60, 100), (960, 480, 64, 90)])
        r.roll.selection = [ids[1]]
        try r.window.control("pianoRoll.key.62").action()
        let state = UIStateDumper.dump(r.window, isMain: true)
        guard case .object(let window) = state, case .object(let roll)? = window["pianoRoll"] else {
            Issue.record("no pianoRoll in ui.state")
            return
        }
        #expect(roll["open"] == .bool(true))
        #expect(roll["clip"] == .int(Int64(r.clip)) && roll["track"] == .int(Int64(r.track)))
        #expect(roll["trackName"] == .string("Keys") && roll["noteCount"] == .int(2))
        #expect(roll["snap"] == .string("16") && roll["tool"] == .string("draw"))
        #expect(roll["selection"] == .array([.int(Int64(ids[1]))]))
        #expect(roll["sounding"] == .array([.int(62)]))
        #expect(roll["visiblePitches"] == .object(["low": .int(53), "high": .int(72)]))
        guard case .array(let notes)? = roll["visibleNotes"], notes.count == 2, case .object(let first) = notes[0] else {
            Issue.record("visibleNotes")
            return
        }
        #expect(first["pitch"] == .int(60) && first["start"] == .int(0) && first["velocity"] == .int(100))
        #expect(first["rect"] == .object(["x": .double(48), "y": .double(18 + 12 * 12 + 0.5), "width": .double(48), "height": .double(11)]))
        #expect(roll["trackMeter"] == .null, "the FakeEngine has no meters")
        let controls = r.window.controls.map(\.id)
        #expect(Set(controls).count == controls.count, "control ids are unique")
        for id in ["pianoRoll.open", "pianoRoll.close", "pianoRoll.tool.draw", "pianoRoll.snap.16", "pianoRoll.quantize",
                   "pianoRoll.quantize.grid.8", "pianoRoll.quantize.strength.75", "pianoRoll.transpose.octaveDown",
                   "pianoRoll.audition", "pianoRoll.note.\(ids[0]).select", "pianoRoll.key.53", "pianoRoll.key.72"] {
            #expect(controls.contains(id), "\(id)")
        }
        #expect(!controls.contains("pianoRoll.key.73"), "only visible keys")
        try r.window.control("pianoRoll.key.62").action()
    }

    @Test("UI-020: the key table: P opens; ⌫, ⌘A and Q go to the piano roll only while it has focus")
    func keyBindings() throws {
        let r = try makeRoll()
        _ = try r.add([(40, 200, 60, 100)])
        #expect(KeyBindings.pianoRoll.allSatisfy { binding in r.window.controls.contains { $0.id == binding.controlID } })
        #expect(KeyBindings.binding(for: KeyChord("p"))?.controlID == "pianoRoll.open")
        #expect(!r.window.handleKey(KeyChord("q")))
        r.roll.hasKeyFocus = true
        #expect(r.window.handleKey(KeyChord("q")))
        #expect(r.notes.first?.start == 0 && r.store.undoLabel == "Quantize")
        // Space still plays (the window's table) with the piano roll focused.
        #expect(r.window.handleKey(KeyChord(.space)))
    }
}

// MARK: The canvas view

@MainActor
@Suite("Piano roll view (UI-020)", .serialized)
struct PianoRollViewTests {
    @Test("UI-020: a layer-backed view draws the grid in tiles; scrolling inside drawn tiles draws none; the snapshot shows notes")
    func drawsTilesAndSnapshot() throws {
        let r = try makeRoll()
        let id = try #require(try r.add([(0, 960, 60, 127)]).first)
        let view = PianoRollView(model: r.roll)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 330)
        view.layout()
        #expect(view.wantsLayer && view.wantsUpdateLayer)
        #expect(r.roll.viewSize == CGSize(width: 800, height: 330))
        view.displayNow()
        #expect(view.tileCount >= 1 && view.tilesDrawn >= 1)
        let drawn = view.tilesDrawn
        view.displayNow()
        #expect(view.tilesDrawn == drawn, "nothing changed: nothing redrawn")
        // Scrolling within the drawn tiles (a 768 × 256 tile holds the 752 × 240 grid) draws none.
        r.roll.scroll(dx: 4, dy: 4)
        view.displayNow()
        #expect(view.tilesDrawn == drawn)
        r.roll.scroll(dx: -4, dy: -4)
        // A content change redraws the visible tiles only.
        r.roll.selection = [id]
        view.displayNow()
        #expect(view.tilesDrawn == drawn + view.tileCount)

        let image = try #require(view.snapshotImage(scale: 1))
        let rep = NSBitmapImageRep(cgImage: image)
        let center = r.roll.geometry.rect(r.notes[0])
        let note = try #require(rep.colorAt(x: Int(center.midX), y: Int(center.midY))?.usingColorSpace(.sRGB))
        #expect(note.redComponent > 0.8 && note.greenComponent > 0.5, "a selected note is orange: \(note)")
        let key = try #require(rep.colorAt(x: 10, y: Int(r.roll.geometry.rowY(60) + 6))?.usingColorSpace(.sRGB))
        #expect(key.redComponent > 0.85, "C4 is a white key")
        let empty = try #require(rep.colorAt(x: 700, y: Int(r.roll.geometry.rowY(61) + 6))?.usingColorSpace(.sRGB))
        #expect(empty.redComponent < 0.3, "a black-key row: dark")
    }
}
