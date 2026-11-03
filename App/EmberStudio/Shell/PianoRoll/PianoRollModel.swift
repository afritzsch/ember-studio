import CoreGraphics
import DAWModel
import Foundation
import Observation

/// What a press in the empty note grid does (UI-020).
enum PianoRollTool: String, CaseIterable, Codable, Sendable {
    /// Draws a note (drag sets its length). Presses on notes select, move and resize them.
    case draw
    /// Drags a marquee; a double-click still draws.
    case select

    var title: String { self == .draw ? "Draw" : "Select" }
}

/// Where on a note a press landed.
enum NoteZone: String, Sendable {
    case body, start, end
}

/// What is under a point of the piano roll.
enum PianoRollHit: Equatable, Sendable {
    case key(pitch: Int)
    case note(id: ModelID, zone: NoteZone)
    /// An empty grid cell: absolute tick and pitch.
    case grid(tick: Int64, pitch: Int)
    /// The velocity lane, with the note whose stem is nearest (nil: none close enough).
    case velocity(id: ModelID?)
    case ruler
}

/// UI-020 / UI-021: the piano roll's view model. It edits one MIDI clip (`clipID`) of the window's
/// project, only through the note commands (`AddNotes`, `RemoveNotes`, `MoveNotes`,
/// `SetNoteProps`, MODEL-005); every gesture is one undo entry (`beginGesture`/`endGesture`, as in
/// the arrange canvas, UI-013), and so are quantize, transpose and delete. Clicking a key or a
/// note auditions it on the track's instrument through `EngineProtocol.previewNote` (UI-021):
/// every note-on gets its note-off, at mouse up, when the pane or clip closes, when the window's
/// document is replaced, and before a different pitch or track sounds.
///
/// The view (`PianoRollView`) is thin: it forwards events here and draws what this reports.
@Observable
@MainActor
final class PianoRollModel {
    static let dragThreshold = 3.0
    static let edgeWidth = 5.0
    static let zoomRange = 8.0...1024.0
    static let keyHeightRange = 6.0...32.0
    static let defaultVelocity: UInt8 = 100
    static let velocityStep = 10
    /// The quantize strengths offered as controls (percent).
    static let strengthPresets = [25, 50, 75, 100]

    @ObservationIgnored weak var window: ProjectWindowModel?

    /// The open MIDI clip, or nil (the pane shows a hint).
    private(set) var clipID: ModelID?
    /// Selected note IDs (notes of the open clip).
    var selection: Set<ModelID> = []
    var tool: PianoRollTool = .draw
    /// UI-012 snapping for drawing, moving and resizing; ⌘ disables it during a drag.
    var snap: SnapMode = .sixteenth
    /// Quantize grid (never `off`) and strength 0…1 (1 moves notes onto the grid, 0.5 halfway).
    var quantizeGrid: SnapMode = .sixteenth
    var quantizeStrength = 1.0
    /// UI-021: clicking a note auditions it (keys always do).
    var auditionNotes = true
    var pixelsPerBeat = 96.0
    var keyHeight = 12.0
    var scrollX = 0.0
    var scrollY = Double(127 - 84) * 12.0
    /// The view's size in points (set by the view).
    var viewSize = CGSize(width: 800, height: 320)
    /// The canvas has keyboard focus: ⌫, ⌘A, Q and the arrows act on notes (UI-020).
    var hasKeyFocus = false

    private(set) var marquee: CGRect?
    private(set) var activeGesture: String?
    /// UI-021: the pitches being auditioned now, on `auditionTrack`.
    private(set) var sounding: [UInt8] = []
    private(set) var auditionTrack: ModelID?
    /// The length a drawn note gets: the last one drawn or resized (default one snap step).
    private(set) var drawLength: Int64?

    @ObservationIgnored private var auditionEngine: (any EngineProtocol)?
    @ObservationIgnored private var drag: DragState?

    init() {}

    // MARK: Derived

    private var store: ProjectStore? { window?.store }
    private var engine: (any EngineProtocol)? { window?.engine }
    var project: Project { window?.project ?? Project() }
    var isOpen: Bool { clip != nil }

    /// The open clip, while it exists and is MIDI.
    var clip: MidiClip? {
        guard let clipID, case .midi(let midi) = project.clip(clipID) else { return nil }
        return midi
    }

    /// The track holding the open clip.
    var trackID: ModelID? { clipID.flatMap { project.clipLocation($0)?.track } }
    var track: Track? { trackID.flatMap { project.track($0) } }
    var notes: [Note] { clip?.notes ?? [] }

    var geometry: PianoRollGeometry {
        PianoRollGeometry(pixelsPerBeat: pixelsPerBeat, keyHeight: keyHeight, scrollX: scrollX, scrollY: scrollY,
                          size: viewSize, clipStart: clip?.start.raw ?? 0)
    }

    var grid: SnapGrid { SnapGrid(tempoMap: project.tempoMap) }

    /// The selection, restricted to notes that still exist (an undo may remove some).
    var selectedNotes: [Note] { notes.filter { selection.contains($0.id) } }

    func isSnapping(_ modifiers: CanvasModifiers) -> Bool { snap != .off && !modifiers.contains(.command) }

    /// UI-020: the notes inside the grid's viewport (time and pitch).
    var visibleNotes: [Note] {
        let g = geometry
        guard let pitches = g.visiblePitches else { return [] }
        let range = g.visibleTicks
        return notes.filter {
            let start = g.clipStart + $0.start.raw
            return pitches.contains(Int($0.pitch)) && start < range.to && start + $0.length.raw > range.from
        }
    }

    // MARK: Open and close

    /// Opens `clipID` (a MIDI clip) in the piano roll and shows the pane, scrolled to its notes.
    func open(_ clipID: ModelID) {
        guard case .midi(let midi) = project.clip(clipID) else { return }
        finishDrag()
        if self.clipID != clipID {
            stopAudition()
            selection = []
        }
        self.clipID = clipID
        window?.bottomPane = .pianoRoll
        reveal(midi)
    }

    /// Opens the first selected MIDI clip of the arrange view (the `pianoRoll.open` control, P).
    func openSelected() {
        if let id = selectedArrangeMidiClip { open(id) }
    }

    var selectedArrangeMidiClip: ModelID? {
        guard let window else { return nil }
        return window.selectedClips.sorted().first { if case .midi = project.clip($0) { true } else { false } }
    }

    func close() {
        finishDrag()
        stopAudition()
        clipID = nil
        selection = []
    }

    /// Scrolls so the clip's start and its notes (middle C when it has none) are in view.
    private func reveal(_ clip: MidiClip) {
        let g = geometry
        scrollX = max(Double(clip.start.raw) * g.pixelsPerTick - 24, 0)
        let pitches = clip.notes.map { Int($0.pitch) }
        let center = pitches.isEmpty ? 60.0 : Double(pitches.min()! + pitches.max()!) / 2
        let visible = g.gridRect.height
        scrollY = clampScrollY((127.5 - center) * keyHeight - visible / 2)
    }

    private func clampScrollY(_ y: Double) -> Double {
        min(max(y, 0), max(geometry.contentHeight - geometry.gridRect.height, 0))
    }

    // MARK: Hit testing

    func hitTest(_ p: CGPoint) -> PianoRollHit? {
        let g = geometry
        if g.rulerRect.contains(p) { return .ruler }
        if g.keyboardRect.contains(p) {
            let pitch = g.pitch(atY: p.y)
            return (0...127).contains(pitch) ? .key(pitch: pitch) : nil
        }
        if g.laneRect.contains(p) { return .velocity(id: velocityHit(p)) }
        guard g.gridRect.contains(p) else { return nil }
        // The latest note drawn on top wins where notes overlap.
        if let note = notes.last(where: { g.rect($0).contains(p) }) {
            let r = g.rect(note)
            let edge = min(Self.edgeWidth, r.width / 3)
            let zone: NoteZone = r.maxX - p.x <= edge ? .end : p.x - r.minX <= edge ? .start : .body
            return .note(id: note.id, zone: zone)
        }
        let pitch = g.pitch(atY: p.y)
        guard (0...127).contains(pitch) else { return nil }
        return .grid(tick: g.tick(atX: p.x), pitch: pitch)
    }

    /// The note whose velocity stem is nearest `p` (within 5 points), selected notes first; among
    /// stems at one x (a chord), the one whose top is nearest.
    private func velocityHit(_ p: CGPoint) -> ModelID? {
        let g = geometry
        let candidates = notes.compactMap { note -> (Note, Double)? in
            let dx = abs(g.x(g.clipStart + note.start.raw) - p.x)
            return dx <= 5 ? (note, dx) : nil
        }
        return candidates.min { a, b in
            let sa = selection.contains(a.0.id) ? 0 : 1, sb = selection.contains(b.0.id) ? 0 : 1
            if sa != sb { return sa < sb }
            if a.1 != b.1 { return a.1 < b.1 }
            return abs(g.velocityY(a.0.velocity) - p.y) < abs(g.velocityY(b.0.velocity) - p.y)
        }?.0.id
    }

    // MARK: Gestures (UI-020)

    private struct DragState {
        enum Kind {
            case keys(pitch: Int)
            case note(id: ModelID, zone: NoteZone)
            /// A note drawn at mouse down; the drag sets its length.
            case draw(id: ModelID)
            case velocity(id: ModelID)
            case marquee(base: Set<ModelID>)
        }

        var down: CGPoint
        var kind: Kind
        var started = false
        /// The notes the gesture edits, as they were when it started.
        var originals: [Note] = []
        /// What a move has applied so far (MoveNotes is relative).
        var movedTicks: Int64 = 0
        var movedSemitones = 0
    }

    func mouseDown(at p: CGPoint, modifiers: CanvasModifiers = [], clickCount: Int = 1) {
        finishDrag()
        guard isOpen, let hit = hitTest(p) else { return }
        switch hit {
        case .key(let pitch):
            // UI-021: a key sounds while it is held; dragging over the keys plays the ones passed.
            audition(UInt8(pitch), velocity: Self.defaultVelocity)
            drag = DragState(down: p, kind: .keys(pitch: pitch))
        case .note(let id, let zone):
            if clickCount >= 2 && zone == .body {
                deleteNotes([id], label: "Delete Note")
                return
            }
            if modifiers.contains(.shift) {
                if selection.contains(id) {
                    selection.remove(id)
                    return
                }
                selection.insert(id)
            } else if !selection.contains(id) {
                selection = [id]
            }
            if auditionNotes, let note = notes.first(where: { $0.id == id }) { audition(note.pitch, velocity: note.velocity) }
            drag = DragState(down: p, kind: .note(id: id, zone: zone))
        case .grid(let tick, let pitch):
            if tool == .draw || clickCount >= 2 {
                draw(at: p, tick: tick, pitch: pitch, modifiers: modifiers)
            } else {
                let base = modifiers.contains(.shift) ? selection : []
                if !modifiers.contains(.shift) { selection = [] }
                drag = DragState(down: p, kind: .marquee(base: base))
            }
        case .velocity(let id):
            guard let id else { return }
            if !selection.contains(id) { selection = modifiers.contains(.shift) ? selection.union([id]) : [id] }
            drag = DragState(down: p, kind: .velocity(id: id))
        case .ruler:
            return
        }
    }

    /// Draws a note in the grid cell under the press (one undo entry with the drag that sizes it).
    private func draw(at p: CGPoint, tick: Int64, pitch: Int, modifiers: CanvasModifiers) {
        guard let clip, let store, let clipID else { return }
        let g = geometry
        let raw = g.tickFloor(atX: p.x)
        let start = isSnapping(modifiers) ? grid.floor(Tick(raw), snap).raw : max(raw, 0)
        let length = drawLength ?? grid.step(snap, at: Tick(start))
        let before = Set(clip.notes.map(\.id))
        store.beginGesture("Add Note")
        activeGesture = "Add Note"
        do {
            try store.perform(AddNotes(clipID: clipID, notes: [
                AddNotes.NoteSpec(start: Tick(start - g.clipStart), length: Tick(length), pitch: UInt8(pitch),
                                  velocity: Self.defaultVelocity),
            ]))
        } catch {
            store.endGesture()
            activeGesture = nil
            window?.toasts.post(.error, .error, title: "Add Note failed", message: error.description)
            return
        }
        guard let added = notes.first(where: { !before.contains($0.id) }) else { return }
        selection = [added.id]
        audition(added.pitch, velocity: added.velocity)
        var state = DragState(down: p, kind: .draw(id: added.id), started: true)
        state.originals = [added]
        drag = state
    }

    func mouseDragged(to p: CGPoint, modifiers: CanvasModifiers = []) {
        guard var drag else { return }
        if case .keys(let last) = drag.kind {
            let pitch = min(max(geometry.pitch(atY: p.y), 0), 127)
            if pitch != last {
                audition(UInt8(pitch), velocity: Self.defaultVelocity)
                drag.kind = .keys(pitch: pitch)
                self.drag = drag
            }
            return
        }
        if !drag.started {
            guard hypot(p.x - drag.down.x, p.y - drag.down.y) >= Self.dragThreshold else { return }
            drag.started = true
            switch drag.kind {
            case .note(let id, _), .velocity(let id):
                // Every selected note moves together (the pressed one is selected by now).
                let ids = selection.contains(id) ? selection : [id]
                drag.originals = notes.filter { ids.contains($0.id) }
                let label = Self.label(drag.kind, count: drag.originals.count)
                activeGesture = label
                store?.beginGesture(label)
            case .marquee:
                activeGesture = "Marquee"
            case .keys, .draw:
                break
            }
            self.drag = drag
        }
        switch drag.kind {
        case .note(let id, let zone):
            switch zone {
            case .body: moveDrag(&drag, primary: id, to: p, modifiers: modifiers)
            case .end: resizeEnd(drag, primary: id, to: p, modifiers: modifiers)
            case .start: resizeStart(drag, primary: id, to: p, modifiers: modifiers)
            }
            self.drag = drag
        case .draw(let id):
            resizeEnd(drag, primary: id, to: p, modifiers: modifiers)
        case .velocity:
            let delta = -(p.y - drag.down.y) / geometry.velocityPointsPerStep
            let changes = drag.originals.map { note in
                SetNoteProps.Change(id: note.id, velocity: UInt8(min(max((Double(note.velocity) + delta).rounded(), 1), 127)))
            }
            step(SetNoteProps(clipID: clipID ?? 0, notes: changes))
        case .marquee(let base):
            let rect = CGRect(x: min(drag.down.x, p.x), y: min(drag.down.y, p.y), width: abs(p.x - drag.down.x),
                              height: abs(p.y - drag.down.y))
            marquee = rect
            let g = geometry
            selection = base.union(notes.filter { g.rect($0).intersects(rect) }.map(\.id))
        case .keys:
            break
        }
    }

    func mouseUp(at p: CGPoint, modifiers: CanvasModifiers = []) {
        if let drag, !drag.started, case .note(let id, .body) = drag.kind, !modifiers.contains(.shift), selection.count > 1 {
            // A click (no drag) on one note of a multi-selection selects just that note.
            selection = [id]
        }
        finishDrag()
    }

    /// Ends the drag in progress (its gesture becomes one undo entry, none if it changed nothing)
    /// and the audition it started.
    func finishDrag() {
        if let drag {
            switch drag.kind {
            case .draw: store?.endGesture()
            case .note, .velocity: if drag.started { store?.endGesture() }
            case .keys, .marquee: break
            }
        }
        drag = nil
        marquee = nil
        activeGesture = nil
        stopAudition()
    }

    private static func label(_ kind: DragState.Kind, count: Int) -> String {
        switch kind {
        case .note(_, .body): count == 1 ? "Move Note" : "Move Notes"
        case .note(_, .end), .note(_, .start): count == 1 ? "Resize Note" : "Resize Notes"
        case .velocity: "Note Velocity"
        case .draw: "Add Note"
        case .keys, .marquee: ""
        }
    }

    /// A body drag: every original note by the same time and pitch offset, the pressed note's start
    /// snapped, no note before the timeline start or outside 0…127.
    private func moveDrag(_ drag: inout DragState, primary id: ModelID, to p: CGPoint, modifiers: CanvasModifiers) {
        guard let clipID, let primary = drag.originals.first(where: { $0.id == id }) else { return }
        let g = geometry
        let start = g.clipStart + primary.start.raw
        var target = start + g.ticks(forWidth: p.x - drag.down.x)
        if isSnapping(modifiers) { target = grid.snap(Tick(target), snap).raw }
        let earliest = drag.originals.map { g.clipStart + $0.start.raw }.min() ?? 0
        let ticks = max(target - start, -earliest)
        let pitches = drag.originals.map { Int($0.pitch) }
        let semitones = min(max(g.pitch(atY: p.y) - g.pitch(atY: drag.down.y), -(pitches.min() ?? 0)), 127 - (pitches.max() ?? 127))
        let dt = ticks - drag.movedTicks, ds = semitones - drag.movedSemitones
        guard dt != 0 || ds != 0 else { return }
        do {
            try store?.perform(MoveNotes(clipID: clipID, noteIDs: drag.originals.map(\.id), ticks: Tick(dt), semitones: ds))
        } catch {
            return  // refused: the drag keeps its last valid state
        }
        drag.movedTicks = ticks
        drag.movedSemitones = semitones
        // UI-021: a note dragged to another pitch sounds at it.
        if ds != 0, !sounding.isEmpty {
            audition(UInt8(Int(primary.pitch) + semitones), velocity: primary.velocity)
        }
    }

    /// Drags the end of the pressed note (snapped); every original note's length changes by the same
    /// amount, at least 1 tick (a snap step for the pressed one while snapping).
    private func resizeEnd(_ drag: DragState, primary id: ModelID, to p: CGPoint, modifiers: CanvasModifiers) {
        guard let clipID, let primary = drag.originals.first(where: { $0.id == id }) else { return }
        let g = geometry
        let start = g.clipStart + primary.start.raw
        let end = start + primary.length.raw
        let snapping = isSnapping(modifiers)
        var target: Int64
        if case .draw = drag.kind {
            target = g.tick(atX: p.x)  // the pointer's position, not a distance
            if target <= start { target = start + primary.length.raw }
        } else {
            target = end + g.ticks(forWidth: p.x - drag.down.x)
        }
        if snapping { target = grid.snap(Tick(target), snap).raw }
        let minimum: Int64 = snapping ? grid.step(snap, at: Tick(start)) : 1
        let length = max(target - start, minimum)
        let delta = length - primary.length.raw
        let changes = drag.originals.map { SetNoteProps.Change(id: $0.id, length: Tick(max($0.length.raw + delta, 1))) }
        if step(SetNoteProps(clipID: clipID, notes: changes)) { drawLength = length }
    }

    /// Drags the start of the pressed note (snapped), keeping every original note's end; a note
    /// keeps at least 1 tick.
    private func resizeStart(_ drag: DragState, primary id: ModelID, to p: CGPoint, modifiers: CanvasModifiers) {
        guard let clipID, let primary = drag.originals.first(where: { $0.id == id }) else { return }
        let g = geometry
        let start = g.clipStart + primary.start.raw
        var target = start + g.ticks(forWidth: p.x - drag.down.x)
        if isSnapping(modifiers) { target = grid.snap(Tick(target), snap).raw }
        var delta = target - start
        delta = min(delta, (drag.originals.map(\.length.raw).min() ?? 1) - 1)
        delta = max(delta, -(drag.originals.map { g.clipStart + $0.start.raw }.min() ?? 0))
        let changes = drag.originals.map {
            SetNoteProps.Change(id: $0.id, start: Tick($0.start.raw + delta), length: Tick($0.length.raw - delta))
        }
        step(SetNoteProps(clipID: clipID, notes: changes))
    }

    /// One step of the open gesture; a refused step is skipped (the drag keeps its last valid state).
    @discardableResult
    private func step(_ command: any Command) -> Bool {
        guard let store else { return false }
        do {
            try store.perform(command)
            return true
        } catch {
            return false
        }
    }

    // MARK: Actions (UI-020): each is one undo entry

    /// Runs `body` as one undo entry named `label`; a refused command ends it and becomes a toast.
    private func edit(_ label: String, _ body: (ProjectStore) throws(DAWError) -> Void) {
        guard let store else { return }
        finishDrag()
        store.beginGesture(label)
        defer { store.endGesture() }
        do {
            try body(store)
        } catch {
            window?.toasts.post(.error, .error, title: "\(label) failed", message: error.description)
        }
    }

    func selectAll() { selection = Set(notes.map(\.id)) }

    func deleteSelection() {
        let ids = selectedNotes.map(\.id)
        guard !ids.isEmpty else { return }
        deleteNotes(ids, label: ids.count == 1 ? "Delete Note" : "Delete Notes")
    }

    private func deleteNotes(_ ids: [ModelID], label: String) {
        guard let clipID else { return }
        edit(label) { store throws(DAWError) in try store.perform(RemoveNotes(clipID: clipID, noteIDs: ids)) }
        selection.subtract(ids)
    }

    /// UI-020: transposes the selection by `semitones` (↑/↓ 1, ⇧ an octave), as far as the
    /// highest and lowest notes allow (nothing if they are already at the edge).
    func transpose(by semitones: Int) {
        let selected = selectedNotes
        guard let clipID, let low = selected.map({ Int($0.pitch) }).min(), let high = selected.map({ Int($0.pitch) }).max()
        else { return }
        let amount = min(max(semitones, -low), 127 - high)
        guard amount != 0 else { return }
        edit("Transpose") { store throws(DAWError) in
            try store.perform(MoveNotes(clipID: clipID, noteIDs: selected.map(\.id), semitones: amount))
        }
    }

    /// UI-020: moves the selected notes' starts (all notes with no selection) toward the nearest
    /// line of `quantizeGrid` by `quantizeStrength`; lengths are kept. One undo entry; nothing if
    /// every note is already where it would go.
    func quantize() {
        guard let clipID, let clip, quantizeGrid != .off else { return }
        let targets = selection.isEmpty ? clip.notes : selectedNotes
        let grid = self.grid
        let strength = min(max(quantizeStrength, 0), 1)
        let changes: [SetNoteProps.Change] = targets.compactMap { note in
            let start = clip.start.raw + note.start.raw
            let line = grid.snap(Tick(start), quantizeGrid).raw
            let moved = start + Int64((Double(line - start) * strength).rounded())
            return moved == start ? nil : SetNoteProps.Change(id: note.id, start: Tick(moved - clip.start.raw))
        }
        guard !changes.isEmpty else { return }
        edit("Quantize") { store throws(DAWError) in try store.perform(SetNoteProps(clipID: clipID, notes: changes)) }
    }

    /// Changes the selected notes' velocities by `amount` (clamped to 1…127). One undo entry.
    func changeVelocity(by amount: Int) {
        guard let clipID else { return }
        let changes = selectedNotes.compactMap { note -> SetNoteProps.Change? in
            let v = UInt8(min(max(Int(note.velocity) + amount, 1), 127))
            return v == note.velocity ? nil : SetNoteProps.Change(id: note.id, velocity: v)
        }
        guard !changes.isEmpty else { return }
        edit("Note Velocity") { store throws(DAWError) in try store.perform(SetNoteProps(clipID: clipID, notes: changes)) }
    }

    /// The arrows while the canvas has focus: ↑/↓ transpose a semitone, with ⇧ an octave.
    @discardableResult
    func handleArrow(up: Bool, shift: Bool) -> Bool {
        guard isOpen, !selection.isEmpty else { return false }
        transpose(by: (up ? 1 : -1) * (shift ? 12 : 1))
        return true
    }

    // MARK: Audition (UI-021)

    /// Sounds `pitch` on the open clip's track (and stops whatever sounded before). The engine
    /// routes it to the track's instrument; a track without one stays silent.
    func audition(_ pitch: UInt8, velocity: UInt8) {
        guard let track = trackID, let engine else { return }
        if sounding == [pitch] && auditionTrack == track && auditionEngine === engine { return }
        stopAudition()
        engine.previewNote(track: track, pitch: pitch, velocity: velocity, on: true)
        auditionEngine = engine
        auditionTrack = track
        sounding = [pitch]
    }

    /// The note-off for everything auditioned, to the engine and track that got the note-on.
    func stopAudition() {
        if let engine = auditionEngine, let track = auditionTrack {
            for pitch in sounding { engine.previewNote(track: track, pitch: pitch, velocity: 0, on: false) }
        }
        auditionEngine = nil
        if auditionTrack != nil { auditionTrack = nil }
        if !sounding.isEmpty { sounding = [] }
    }

    // MARK: Zoom and scroll

    func zoom(by factor: Double, anchorX: Double = PianoRollGeometry.keyboardWidth) {
        let g = geometry
        let anchorTicks = (anchorX - PianoRollGeometry.keyboardWidth + scrollX) / g.pixelsPerTick
        pixelsPerBeat = min(max(pixelsPerBeat * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        scrollX = max(anchorTicks * geometry.pixelsPerTick - (anchorX - PianoRollGeometry.keyboardWidth), 0)
    }

    func zoomKeys(by factor: Double) {
        let center = scrollY + geometry.gridRect.height / 2
        let pitchAtCenter = center / keyHeight
        keyHeight = min(max(keyHeight * factor, Self.keyHeightRange.lowerBound), Self.keyHeightRange.upperBound)
        scrollY = clampScrollY(pitchAtCenter * keyHeight - geometry.gridRect.height / 2)
    }

    func scroll(dx: Double, dy: Double) {
        scrollX = max(scrollX + dx, 0)
        scrollY = clampScrollY(scrollY + dy)
    }

    /// UI-014: the playhead as the engine reports it.
    func playheadTick() -> Tick { window?.arrange.playheadTick() ?? Tick(0) }

    // MARK: Controls (UI-052)

    /// `pianoRoll.open` always; with a clip open, the tool, snap and quantize settings, the edit
    /// actions, a select button per visible note and an audition toggle per visible key.
    var controls: [UIControl] {
        var controls: [UIControl] = [
            .button("pianoRoll.open", "Open in Piano Roll", enabled: selectedArrangeMidiClip != nil) { [weak self] in
                self?.openSelected()
            },
        ]
        guard isOpen else { return controls }
        let hasSelection = !selectedNotes.isEmpty
        let hasNotes = !notes.isEmpty
        controls.append(.button("pianoRoll.close", "Close Piano Roll") { [weak self] in self?.close() })
        controls += PianoRollTool.allCases.map { tool in
            .toggle("pianoRoll.tool.\(tool.rawValue)", "\(tool.title) Tool", isOn: self.tool == tool) { [weak self] in self?.tool = tool }
        }
        controls += SnapMode.allCases.map { mode in
            .toggle("pianoRoll.snap.\(mode.rawValue)", "Note Snap \(mode.title)", isOn: snap == mode) { [weak self] in self?.snap = mode }
        }
        controls += SnapMode.allCases.filter { $0 != .off }.map { mode in
            .toggle("pianoRoll.quantize.grid.\(mode.rawValue)", "Quantize Grid \(mode.title)", isOn: quantizeGrid == mode) { [weak self] in
                self?.quantizeGrid = mode
            }
        }
        controls += Self.strengthPresets.map { percent in
            .toggle("pianoRoll.quantize.strength.\(percent)", "Quantize Strength \(percent)%",
                    isOn: Int((quantizeStrength * 100).rounded()) == percent) { [weak self] in
                self?.quantizeStrength = Double(percent) / 100
            }
        }
        controls += [
            .button("pianoRoll.quantize", "Quantize", enabled: hasNotes) { [weak self] in self?.quantize() },
            .button("pianoRoll.transpose.up", "Transpose Up", enabled: hasSelection) { [weak self] in self?.transpose(by: 1) },
            .button("pianoRoll.transpose.down", "Transpose Down", enabled: hasSelection) { [weak self] in self?.transpose(by: -1) },
            .button("pianoRoll.transpose.octaveUp", "Octave Up", enabled: hasSelection) { [weak self] in self?.transpose(by: 12) },
            .button("pianoRoll.transpose.octaveDown", "Octave Down", enabled: hasSelection) { [weak self] in self?.transpose(by: -12) },
            .button("pianoRoll.velocity.up", "Velocity Up", enabled: hasSelection) { [weak self] in
                self?.changeVelocity(by: Self.velocityStep)
            },
            .button("pianoRoll.velocity.down", "Velocity Down", enabled: hasSelection) { [weak self] in
                self?.changeVelocity(by: -Self.velocityStep)
            },
            .button("pianoRoll.selectAll", "Select All Notes", enabled: hasNotes) { [weak self] in self?.selectAll() },
            .button("pianoRoll.deselectAll", "Deselect Notes", enabled: hasSelection) { [weak self] in self?.selection = [] },
            .button("pianoRoll.delete", "Delete Notes", enabled: hasSelection) { [weak self] in self?.deleteSelection() },
            .toggle("pianoRoll.audition", "Audition Notes", isOn: auditionNotes) { [weak self] in
                guard let self else { return }
                auditionNotes.toggle()
            },
            .button("pianoRoll.zoom.in", "Piano Roll Zoom In", enabled: pixelsPerBeat < Self.zoomRange.upperBound) { [weak self] in
                self?.zoom(by: ProjectWindowModel.zoomStep)
            },
            .button("pianoRoll.zoom.out", "Piano Roll Zoom Out", enabled: pixelsPerBeat > Self.zoomRange.lowerBound) { [weak self] in
                self?.zoom(by: 1 / ProjectWindowModel.zoomStep)
            },
        ]
        controls += visibleNotes.map { note in
            .button("pianoRoll.note.\(note.id).select", "Select note \(note.id)") { [weak self] in self?.selection = [note.id] }
        }
        // UI-021: a key toggle holds its note until it is toggled off (ui.perform on/off).
        if let pitches = geometry.visiblePitches {
            let canSound = trackID != nil && engine != nil
            controls += pitches.reversed().map { pitch in
                let on = sounding.contains(UInt8(pitch))
                return .toggle("pianoRoll.key.\(pitch)", "Play \(Self.noteName(pitch))", isOn: on, enabled: canSound) { [weak self] in
                    guard let self else { return }
                    if on { stopAudition() } else { audition(UInt8(pitch), velocity: Self.defaultVelocity) }
                }
            }
        }
        return controls
    }

    /// "C4" for 60 (middle C, Yamaha/Logic numbering).
    static func noteName(_ pitch: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return names[pitch % 12] + "\(pitch / 12 - 1)"
    }

    static func isBlackKey(_ pitch: Int) -> Bool { [1, 3, 6, 8, 10].contains(pitch % 12) }
}
