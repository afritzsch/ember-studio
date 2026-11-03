import CoreGraphics
import DAWModel
import Foundation
import Observation

/// Modifier keys a canvas gesture looks at.
struct CanvasModifiers: OptionSet, Sendable {
    let rawValue: Int
    static let shift = CanvasModifiers(rawValue: 1)
    /// UI-012: ⌘ turns snapping off for the drag.
    static let command = CanvasModifiers(rawValue: 2)
    static let option = CanvasModifiers(rawValue: 4)
}

/// Where on a clip a press landed (UI-013).
enum ClipZone: String, Sendable {
    case body, trimStart, trimEnd, fadeIn, fadeOut, gain
}

struct ClipHit: Equatable, Sendable {
    var clipID: ModelID
    var zone: ClipZone
}

/// UI-010..014: the arrange canvas's view model. It reads the project from the window's store and
/// changes it only through commands; every drag is one gesture (`beginGesture`/`endGesture`), so a
/// drag is one undo entry however many steps it took (UI-013, MODEL-003). Zoom, scroll and the clip
/// selection stay on `ProjectWindowModel`, which the rest of the window shares. The canvas view
/// (`TimelineCanvasView`) is thin: it forwards mouse events here and draws what this reports.
@Observable
@MainActor
final class ArrangeModel {
    /// Points a press must move before it counts as a drag.
    static let dragThreshold = 3.0
    /// The band at a clip's top holding its fade and gain handles.
    static let handleBand = 10.0
    static let edgeWidth = 6.0
    /// Gain handle sensitivity: dB per point dragged.
    static let gainDBPerPoint = 0.2
    static let minGainDB = -60.0

    @ObservationIgnored weak var window: ProjectWindowModel?

    /// UI-012
    var snap: SnapMode = .beat
    /// The canvas's size in points (set by the view).
    var viewSize = CGSize(width: 800, height: 480) {
        didSet { window?.viewportHeight = max(viewSize.height - TimelineGeometry.rulerHeight, 0) }
    }
    /// The marquee rectangle while one is dragged (view coordinates).
    private(set) var marquee: CGRect?
    /// The label of the gesture in progress ("Move Clip", "Trim Clip End", …).
    private(set) var activeGesture: String?
    /// Bumped when the engine reports newly loaded audio, so waveforms redraw (UI-011).
    private(set) var peaksVersion = 0

    @ObservationIgnored private var drag: DragState?
    @ObservationIgnored private var cachedIndex: (tracks: [Track], index: ClipIntervalIndex)?
    @ObservationIgnored let peaks = PeakCache()

    init() {}

    // MARK: Derived

    private var store: ProjectStore? { window?.store }
    var project: Project { window?.project ?? Project() }
    var tracks: [Track] { project.tracks }

    var geometry: TimelineGeometry {
        TimelineGeometry(pixelsPerBeat: window?.pixelsPerBeat ?? 32, scrollX: window?.scrollX ?? 0,
                         scrollY: window?.scrollY ?? 0, trackHeight: ProjectWindowModel.trackHeight, size: viewSize)
    }

    var grid: SnapGrid { SnapGrid(tempoMap: project.tempoMap) }

    var selection: Set<ModelID> {
        get { window?.selectedClips ?? [] }
        set { window?.selectedClips = newValue }
    }

    /// UI-010: the interval index over the current tracks, rebuilt only when they change.
    var index: ClipIntervalIndex {
        let tracks = self.tracks
        if let cached = cachedIndex, cached.tracks == tracks { return cached.index }
        let index = ClipIntervalIndex(tracks: tracks)
        cachedIndex = (tracks, index)
        return index
    }

    /// UI-010: only the clips inside the viewport (rows and time), through the interval index.
    var visibleClips: [ClipIntervalIndex.Entry] {
        let g = geometry
        let range = g.visibleTicks
        return index.clips(rows: g.visibleRows(of: tracks.count), from: range.from.raw, to: range.to.raw)
    }

    /// The clips that overlap a rectangle in view coordinates.
    func clips(in rect: CGRect) -> [ClipIntervalIndex.Entry] {
        let g = geometry
        let r = rect.standardized
        let top = g.rowUnclamped(atY: max(r.minY, TimelineGeometry.rulerHeight))
        let bottom = g.rowUnclamped(atY: r.maxY) + 1
        return index.clips(rows: top..<bottom, from: g.tick(atX: r.minX).raw, to: g.tick(atX: r.maxX).raw + 1)
            .filter { g.rect(start: $0.clip.start, length: $0.clip.length, row: $0.row).intersects(r) }
    }

    func isSnapping(_ modifiers: CanvasModifiers) -> Bool { snap != .off && !modifiers.contains(.command) }

    // MARK: Hit testing

    /// The clip and zone under `point`; the topmost (latest drawn) clip wins where clips overlap.
    func hitTest(_ point: CGPoint) -> ClipHit? {
        let g = geometry
        guard let row = g.row(atY: point.y), row >= 0, row < tracks.count else { return nil }
        let tick = g.tick(atX: point.x).raw
        let candidates = index.clips(rows: row..<(row + 1), from: tick - 1, to: tick + 2)
        guard let entry = candidates.last(where: { g.rect(start: $0.clip.start, length: $0.clip.length, row: row).contains(point) })
        else { return nil }
        let rect = g.rect(start: entry.clip.start, length: entry.clip.length, row: row)
        return ClipHit(clipID: entry.id, zone: zone(of: point, in: rect, clip: entry.clip, geometry: g))
    }

    private func zone(of p: CGPoint, in r: CGRect, clip: Clip, geometry g: TimelineGeometry) -> ClipZone {
        let edge = min(Self.edgeWidth, r.width / 4)
        if case .audio(let audio) = clip, p.y <= r.minY + Self.handleBand {
            let fadeInX = r.minX + Double(audio.fadeIn.raw) * g.pixelsPerTick
            let fadeOutX = r.maxX - Double(audio.fadeOut.raw) * g.pixelsPerTick
            if abs(p.x - fadeInX) <= 5 && p.x <= r.midX { return .fadeIn }
            if abs(p.x - fadeOutX) <= 5 && p.x >= r.midX { return .fadeOut }
            if abs(p.x - r.midX) <= 8 { return .gain }
        }
        if p.x - r.minX <= edge { return .trimStart }
        if r.maxX - p.x <= edge { return .trimEnd }
        return .body
    }

    // MARK: Gestures (UI-013)

    private struct Original {
        var clip: Clip
        var row: Int
    }

    private struct DragState {
        enum Kind {
            case clip(ClipHit)
            case marquee(base: Set<ModelID>)
        }

        var down: CGPoint
        var kind: Kind
        var started = false
        var originals: [ModelID: Original] = [:]
    }

    /// A press at `point`: selects (shift toggles), and arms a drag of the clip zone under it or a marquee.
    func mouseDown(at point: CGPoint, modifiers: CanvasModifiers = []) {
        finishDrag()
        if let hit = hitTest(point) {
            if modifiers.contains(.shift) {
                if selection.contains(hit.clipID) {
                    selection.remove(hit.clipID)
                    return
                }
                selection.insert(hit.clipID)
            } else if !selection.contains(hit.clipID) {
                selection = [hit.clipID]
            }
            drag = DragState(down: point, kind: .clip(hit))
        } else {
            let base = modifiers.contains(.shift) ? selection : []
            if !modifiers.contains(.shift) { selection = [] }
            drag = DragState(down: point, kind: .marquee(base: base))
        }
    }

    /// UI-020: a double-click on a MIDI clip opens it in the piano roll. True if it did.
    @discardableResult
    func doubleClick(at point: CGPoint) -> Bool {
        guard let hit = hitTest(point), case .midi = project.clip(hit.clipID) else { return false }
        finishDrag()
        selection = [hit.clipID]
        window?.pianoRoll.open(hit.clipID)
        return true
    }

    func mouseDragged(to point: CGPoint, modifiers: CanvasModifiers = []) {
        guard var drag else { return }
        if !drag.started {
            guard hypot(point.x - drag.down.x, point.y - drag.down.y) >= Self.dragThreshold else { return }
            drag.started = true
            if case .clip(let hit) = drag.kind {
                let ids: [ModelID] = hit.zone == .body ? Array(selection) : [hit.clipID]
                for id in ids {
                    if let entry = index.entry(id) { drag.originals[id] = Original(clip: entry.clip, row: entry.row) }
                }
                let label = Self.label(hit.zone, count: drag.originals.count)
                activeGesture = label
                store?.beginGesture(label)
            }
            self.drag = drag
        }
        switch drag.kind {
        case .clip(let hit):
            update(hit, drag: drag, to: point, modifiers: modifiers)
        case .marquee(let base):
            let rect = CGRect(x: min(drag.down.x, point.x), y: min(drag.down.y, point.y),
                              width: abs(point.x - drag.down.x), height: abs(point.y - drag.down.y))
            marquee = rect
            activeGesture = "Marquee"
            selection = base.union(clips(in: rect).map(\.id))
        }
    }

    func mouseUp(at point: CGPoint, modifiers: CanvasModifiers = []) {
        if let drag, !drag.started, case .clip(let hit) = drag.kind, hit.zone == .body, !modifiers.contains(.shift),
           selection.count > 1 {
            // A click (no drag) on one clip of a multi-selection selects just that clip.
            selection = [hit.clipID]
        }
        finishDrag()
    }

    /// Ends the drag in progress: its gesture becomes one undo entry (none if it changed nothing).
    func finishDrag() {
        if let drag, drag.started, case .clip = drag.kind { store?.endGesture() }
        drag = nil
        marquee = nil
        activeGesture = nil
    }

    private static func label(_ zone: ClipZone, count: Int) -> String {
        switch zone {
        case .body: count == 1 ? "Move Clip" : "Move Clips"
        case .trimStart: "Trim Clip Start"
        case .trimEnd: "Trim Clip End"
        case .fadeIn: "Fade In"
        case .fadeOut: "Fade Out"
        case .gain: "Clip Gain"
        }
    }

    private func update(_ hit: ClipHit, drag: DragState, to point: CGPoint, modifiers: CanvasModifiers) {
        guard let primary = drag.originals[hit.clipID] else { return }
        let g = geometry
        let dx = g.ticks(forWidth: point.x - drag.down.x)
        let snapping = isSnapping(modifiers)
        let start = primary.clip.start.raw
        let end = start + primary.clip.length.raw
        switch hit.zone {
        case .body:
            var target = start + dx
            if snapping { target = grid.snap(Tick(target), snap).raw }
            let earliest = drag.originals.values.map(\.clip.start.raw).min() ?? 0
            let delta = max(target - start, -earliest)
            move(drag.originals, by: delta, rows: rowDelta(drag, to: point))
        case .trimStart:
            var target = start + dx
            if snapping { target = grid.snap(Tick(target), snap).raw }
            target = min(max(target, earliestStart(primary.clip)), end - 1)
            step(ResizeClip(clipID: hit.clipID, start: Tick(target), length: Tick(end - target)))
        case .trimEnd:
            var target = end + dx
            if snapping { target = grid.snap(Tick(target), snap).raw }
            target = max(min(target, latestEnd(primary.clip)), start + 1)
            step(ResizeClip(clipID: hit.clipID, start: Tick(start), length: Tick(target - start)))
        case .fadeIn, .fadeOut:
            guard case .audio(let current) = project.clip(hit.clipID) else { return }
            let at = g.tick(atX: point.x).raw
            let length = current.length.raw
            if hit.zone == .fadeIn {
                let fade = min(max(at - current.start.raw, 0), length)
                step(SetClipFades(clipID: hit.clipID, fadeIn: Tick(fade), fadeOut: current.fadeOut))
            } else {
                let fade = min(max(current.start.raw + length - at, 0), length)
                step(SetClipFades(clipID: hit.clipID, fadeIn: current.fadeIn, fadeOut: Tick(fade)))
            }
        case .gain:
            guard case .audio(let original) = primary.clip else { return }
            let db = Self.gainDB(original.gain) - (point.y - drag.down.y) * Self.gainDBPerPoint
            step(SetClipGain(clipID: hit.clipID, gain: Self.gain(fromDB: db)))
        }
    }

    /// The row offset of a move: whole rows the pointer moved, limited to the tracks there are, and
    /// 0 if any clip would land on a track of the other kind (audio ↔ MIDI).
    private func rowDelta(_ drag: DragState, to point: CGPoint) -> Int {
        let g = geometry
        var delta = g.rowUnclamped(atY: point.y) - g.rowUnclamped(atY: drag.down.y)
        let rows = drag.originals.values.map(\.row)
        guard let lo = rows.min(), let hi = rows.max() else { return 0 }
        delta = min(max(delta, -lo), tracks.count - 1 - hi)
        let tracks = self.tracks
        for original in drag.originals.values where tracks[original.row + delta].kind != tracks[original.row].kind {
            return 0
        }
        return delta
    }

    private func move(_ originals: [ModelID: Original], by delta: Int64, rows: Int) {
        let tracks = self.tracks
        for (id, original) in originals.sorted(by: { $0.key < $1.key }) {
            let start = Tick(original.clip.start.raw + delta)
            let track = tracks[original.row + rows].id
            if let location = project.clipLocation(id), location.track == track, project.clip(id)?.start == start { continue }
            step(MoveClip(clipID: id, start: start, trackID: track))
        }
    }

    /// One step of the open gesture. A step the model refuses is skipped: the drag keeps its last
    /// valid state (the store applies nothing for a refused command).
    private func step(_ command: any Command) {
        try? store?.perform(command)
    }

    /// The earliest start a trim can give `clip`: 0, and for audio the start of its file (the
    /// source offset can't go negative).
    func earliestStart(_ clip: Clip) -> Int64 {
        guard case .audio(let audio) = clip else { return 0 }
        let map = project.tempoMap
        let fileStart = map.tickToSample(audio.start) - audio.sourceOffsetSamples
        var tick = map.sampleToTick(fileStart)
        if map.tickToSample(tick) < fileStart { tick.raw += 1 }
        return max(tick.raw, 0)
    }

    /// The latest end a trim can give `clip`: for audio the end of its file, else the timeline's end.
    func latestEnd(_ clip: Clip) -> Int64 {
        guard case .audio(let audio) = clip, let asset = project.asset(audio.assetID) else { return Tick.timelineEnd.raw }
        let map = project.tempoMap
        let frames = Int64((Double(asset.frames) * project.sessionSampleRate / asset.originalSampleRate).rounded())
        let fileEnd = map.tickToSample(audio.start) - audio.sourceOffsetSamples + frames
        var tick = map.sampleToTick(fileEnd)
        if map.tickToSample(tick) < fileEnd { tick.raw += 1 }
        return tick.raw
    }

    static func gainDB(_ gain: Float) -> Double {
        gain > 0 ? max(20 * log10(Double(gain)), minGainDB) : minGainDB
    }

    /// dB to linear clip gain, clamped to the model's range (MODEL-031); the bottom of the range is silence.
    static func gain(fromDB db: Double) -> Float {
        let clamped = min(db, 20 * log10(Double(AudioClip.maxGain)))
        guard clamped > minGainDB else { return 0 }
        return min(Float(pow(10, clamped / 20)), AudioClip.maxGain)
    }

    // MARK: Actions (UI-013)

    func selectAll() { selection = Set(tracks.flatMap { $0.clips.map(\.id) }) }

    /// Runs `body` as one undo entry named `label`; a refused command ends it and becomes a toast.
    private func gesture(_ label: String, _ body: (ProjectStore) throws(DAWError) -> Void) {
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

    /// The selected clips, in timeline order.
    private var selectedEntries: [ClipIntervalIndex.Entry] {
        let index = self.index
        return selection.compactMap { index.entry($0) }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// UI-013 (⌘D): copies of the selected clips right after the selection, on their own tracks; the
    /// copies become the selection. One undo entry.
    func duplicateSelection() {
        let entries = selectedEntries
        guard let first = entries.first?.start, let last = entries.map(\.end).max() else { return }
        let offset = last - first
        var copies: Set<ModelID> = []
        gesture("Duplicate") { store throws(DAWError) in
            for entry in entries {
                let before = Set(store.project.track(entry.trackID)?.clips.map(\.id) ?? [])
                let start = Tick(entry.start + offset)
                switch entry.clip {
                case .audio(let a):
                    try store.perform(AddClip(trackID: entry.trackID, start: start, length: a.length, assetID: a.assetID,
                                              sourceOffsetSamples: a.sourceOffsetSamples, gain: a.gain, fadeIn: a.fadeIn,
                                              fadeOut: a.fadeOut))
                case .midi(let m):
                    try store.perform(AddClip(trackID: entry.trackID, start: start, length: m.length))
                }
                guard let copy = store.project.track(entry.trackID)?.clips.first(where: { !before.contains($0.id) })?.id else {
                    continue
                }
                if case .midi(let m) = entry.clip, !m.notes.isEmpty {
                    try store.perform(AddNotes(clipID: copy, notes: m.notes.map {
                        AddNotes.NoteSpec(start: $0.start, length: $0.length, pitch: $0.pitch, velocity: $0.velocity, channel: $0.channel)
                    }))
                }
                copies.insert(copy)
            }
        }
        if !copies.isEmpty { selection = copies }
    }

    /// UI-013: splits the selected clips that `tick` falls strictly inside. Both halves stay selected.
    func splitSelection(at tick: Tick) {
        let entries = selectedEntries.filter { $0.start < tick.raw && tick.raw < $0.end }
        guard !entries.isEmpty else { return }
        var added: Set<ModelID> = []
        gesture("Split") { store throws(DAWError) in
            for entry in entries {
                let before = Set(store.project.track(entry.trackID)?.clips.map(\.id) ?? [])
                try store.perform(SplitClip(clipID: entry.id, at: tick))
                if let right = store.project.track(entry.trackID)?.clips.first(where: { !before.contains($0.id) })?.id {
                    added.insert(right)
                }
            }
        }
        selection.formUnion(added)
    }

    /// Splits at the clicked point (context menu): the selection if the clip is in it, else that clip.
    func split(_ clipID: ModelID, at tick: Tick) {
        if !selection.contains(clipID) { selection = [clipID] }
        splitSelection(at: tick)
    }

    func deleteSelection() {
        let entries = selectedEntries
        guard !entries.isEmpty else { return }
        gesture(entries.count == 1 ? "Delete Clip" : "Delete Clips") { store throws(DAWError) in
            for entry in entries { try store.perform(RemoveClip(clipID: entry.id)) }
        }
        selection = []
    }

    /// Moves the selection by `steps` of the snap grid (a beat with snapping off) and `rows` tracks,
    /// as one undo entry (the same path a drag takes).
    func nudgeSelection(steps: Int, rows: Int) {
        let entries = selectedEntries
        guard let first = entries.first else { return }
        let step = grid.step(snap, at: first.clip.start)
        let delta = max(Int64(steps) * step, -first.start)
        let tracks = self.tracks
        let lo = entries.map(\.row).min()!, hi = entries.map(\.row).max()!
        var rowDelta = min(max(rows, -lo), tracks.count - 1 - hi)
        if entries.contains(where: { tracks[$0.row + rowDelta].kind != tracks[$0.row].kind }) { rowDelta = 0 }
        guard delta != 0 || rowDelta != 0 else { return }
        let originals = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, Original(clip: $0.clip, row: $0.row)) })
        gesture(entries.count == 1 ? "Move Clip" : "Move Clips") { _ in move(originals, by: delta, rows: rowDelta) }
    }

    // MARK: Zoom and scroll (UI-010)

    /// Zooms by `factor` keeping the time under `anchorX` (view x) in place.
    func zoom(by factor: Double, anchorX: Double) {
        guard let window else { return }
        let contentTicks = (anchorX + window.scrollX) / geometry.pixelsPerTick
        window.zoom(by: factor)
        window.scrollX = max(contentTicks * geometry.pixelsPerTick - anchorX, 0)
    }

    func scroll(dx: Double, dy: Double) {
        guard let window else { return }
        window.scrollX = max(window.scrollX + dx, 0)
        let content = Double(tracks.count) * ProjectWindowModel.trackHeight
        let visible = max(viewSize.height - TimelineGeometry.rulerHeight, 0)
        window.scrollY = min(max(window.scrollY + dy, 0), max(content - visible, 0))
    }

    // MARK: Engine (UI-011, UI-014)

    /// UI-014: the playhead as the engine reports it now (TIME-009: latency-compensated).
    func playheadTick() -> Tick { window?.engine?.transport().tick ?? window?.transport.tick ?? Tick(0) }

    /// UI-011: the peaks to draw `assetID` with at `samplesPerPixel`, cached.
    func peakLevel(_ assetID: ModelID, samplesPerPixel: Double) -> PeakLevel? {
        peaks.level(assetID, level: WaveformMesh.level(samplesPerPixel: samplesPerPixel), engine: window?.engine)
    }

    /// UI-011: the waveform bars of the visible audio clips, in view points. Each clip uses the
    /// mipmap level its zoom calls for; clips whose audio hasn't loaded draw none.
    func waveformBars() -> [WaveformBar] {
        let g = geometry
        let map = project.tempoMap
        var bars: [WaveformBar] = []
        for entry in visibleClips {
            guard case .audio(let clip) = entry.clip,
                  let peaks = peakLevel(clip.assetID, samplesPerPixel: WaveformMesh.samplesPerPixel(at: clip.start, geometry: g, tempoMap: map))
            else { continue }
            let color: SIMD4<Float> = selection.contains(clip.id) ? [1, 1, 1, 0.95] : [0.08, 0.1, 0.14, 0.8]
            WaveformMesh.append(clip: clip, rect: g.rect(start: clip.start, length: clip.length, row: entry.row), peaks: peaks,
                                geometry: g, tempoMap: map, color: color, into: &bars)
        }
        return bars
    }

    /// The mipmap level `clip` is drawn with now, or nil if its peaks aren't there (ui.state).
    func waveformLevel(_ clip: AudioClip) -> Int? {
        let spp = WaveformMesh.samplesPerPixel(at: clip.start, geometry: geometry, tempoMap: project.tempoMap)
        return peakLevel(clip.assetID, samplesPerPixel: spp).map { _ in WaveformMesh.level(samplesPerPixel: spp) }
    }

    /// Engine events: newly loaded audio drops its cached peaks and redraws the waveforms. A
    /// session-rate pass (IO-033) drops every peak once, when it finishes; its `started` and
    /// per-asset `progress` events (T-056) leave the cache alone. An `assetsReloaded` without
    /// `reload` counts as finished.
    func engineEventsArrived(_ events: [EngineEvent]) {
        let loaded = events.filter { $0.kind == .assetLoaded }
        let reloaded = events.contains { (event: EngineEvent) -> Bool in
            guard event.kind == .assetsReloaded else { return false }
            let phase: AssetsReload.Phase = event.reload?.phase ?? .finished
            return phase == .finished
        }
        guard reloaded || !loaded.isEmpty else { return }
        peaks.invalidate(reloaded ? nil : Set(loaded.map(\.subject)))
        peaksVersion += 1
    }

    // MARK: Controls (UI-052)

    /// Snap modes, the edit actions, nudges and a select button per visible clip.
    var controls: [UIControl] {
        let hasSelection = !selection.isEmpty
        var controls: [UIControl] = SnapMode.allCases.map { mode in
            .toggle("snap.\(mode.rawValue)", "Snap \(mode.title)", isOn: snap == mode) { [weak self] in self?.snap = mode }
        }
        controls += [
            .button("edit.selectAll", "Select All Clips", enabled: index.clipCount > 0) { [weak self] in self?.selectAll() },
            .button("edit.deselectAll", "Deselect Clips", enabled: hasSelection) { [weak self] in self?.selection = [] },
            .button("edit.duplicate", "Duplicate", enabled: hasSelection) { [weak self] in self?.duplicateSelection() },
            .button("edit.split", "Split at Playhead", enabled: hasSelection) { [weak self] in
                guard let self else { return }
                splitSelection(at: playheadTick())
            },
            .button("edit.delete", "Delete Clips", enabled: hasSelection) { [weak self] in self?.deleteSelection() },
            .button("clip.nudge.left", "Nudge Left", enabled: hasSelection) { [weak self] in self?.nudgeSelection(steps: -1, rows: 0) },
            .button("clip.nudge.right", "Nudge Right", enabled: hasSelection) { [weak self] in self?.nudgeSelection(steps: 1, rows: 0) },
            .button("clip.nudge.up", "Move to Track Above", enabled: hasSelection) { [weak self] in self?.nudgeSelection(steps: 0, rows: -1) },
            .button("clip.nudge.down", "Move to Track Below", enabled: hasSelection) { [weak self] in
                self?.nudgeSelection(steps: 0, rows: 1)
            },
        ]
        controls += visibleClips.map { entry in
            .button("clip.\(entry.id).select", "Select clip \(entry.id)") { [weak self] in self?.selection = [entry.id] }
        }
        return controls
    }
}
