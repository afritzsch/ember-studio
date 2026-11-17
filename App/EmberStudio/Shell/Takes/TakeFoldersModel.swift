import CoreGraphics
import DAWModel
import Foundation
import Observation

/// UI-016 (T-081): a take folder as the arrange canvas places it, on its track's own row.
struct FolderPlacement: Equatable {
    var trackIndex: Int
    var trackID: NodeIDValue
    /// The track's display row (TimelineGeometry).
    var row: Int
    var folder: TakeFolder
}

/// UI-016: one take row of an expanded take folder, a band under its track's row.
struct TakeRow: Equatable {
    var trackIndex: Int
    var trackID: NodeIDValue
    var folderID: ModelID
    var take: Take
    /// 1-based, in recording order (pass number).
    var number: Int
    /// The track's display row, and this row's band under it (1-based; `TimelineGeometry.takeBands`).
    var row: Int
    var band: Int
}

/// UI-016 / REC-033 (T-081): take folders in the arrange view.
///   - Collapsed, a folder shows on its track's row as its comp (the flattened clips) with a
///     disclosure triangle at its left edge (`takeFolder.<id>.expand`).
///   - Expanded, each take (pass) gets a row of its own under the track (`TimelineGeometry`
///     `takeBands`; T-075's lane rows follow them), with the parts the comp plays highlighted.
///   - Swiping across a take row selects that range of the take for the comp: one
///     `SetCompSelection` on mouse up, one undo entry (MODEL-003). A click with no drag selects the
///     take for the whole folder. The swipe is snapped (⌘ off) and kept inside the take's clip and
///     the folder range.
///   - A folder can be deleted (`RemoveTakeFolder`, one undo entry).
@Observable
@MainActor
final class TakeFoldersModel {
    /// The disclosure triangle's box at a folder's top-left (view points).
    static let disclosureSize = 14.0

    @ObservationIgnored weak var window: ProjectWindowModel?

    /// Folders whose takes show.
    var expanded: Set<ModelID> = []
    /// The label of the gesture in progress (`ui.state`).
    private(set) var activeGesture: String?
    /// The swipe in progress (drawn as a highlight on its take row).
    private(set) var swipe: Swipe?

    struct Swipe: Equatable {
        var folderID: ModelID
        var takeID: ModelID
        var down: CGPoint
        var anchor: Tick
        var current: Tick
        /// Past the drag threshold: mouse up comps the range, not the whole folder.
        var started: Bool

        var range: (start: Tick, end: Tick) { (min(anchor, current), max(anchor, current)) }
    }

    init() {}

    private var store: ProjectStore? { window?.store }
    private var project: Project { window?.project ?? Project() }

    /// The document went away.
    func documentReplaced() {
        cancelSwipe()
        expanded = []
    }

    // MARK: Layout (UI-016)

    /// Every folder, with its track's display row in `g` (rows from T-075's lanes).
    func placements(geometry g: TimelineGeometry) -> [FolderPlacement] {
        var out: [FolderPlacement] = []
        for (i, track) in project.tracks.enumerated() where !track.takeFolders.isEmpty {
            let row = g.displayRow(ofTrack: i)
            for folder in track.takeFolders { out.append(FolderPlacement(trackIndex: i, trackID: track.id, row: row, folder: folder)) }
        }
        return out
    }

    /// The take rows of expanded folders: per track, each expanded folder's takes in order (one
    /// band each, folders in the track's order).
    func rows(geometry g: TimelineGeometry) -> [TakeRow] {
        var out: [TakeRow] = []
        guard !expanded.isEmpty else { return out }
        for (i, track) in project.tracks.enumerated() where !track.takeFolders.isEmpty {
            var band = 1
            let row = g.displayRow(ofTrack: i)
            for folder in track.takeFolders where expanded.contains(folder.id) {
                for (n, take) in folder.takes.enumerated() {
                    out.append(TakeRow(trackIndex: i, trackID: track.id, folderID: folder.id, take: take, number: n + 1, row: row,
                                       band: band))
                    band += 1
                }
            }
        }
        return out
    }

    /// The bands `TimelineGeometry` reserves for take rows (sorted by row), from `g`'s track rows.
    func bands(geometry g: TimelineGeometry) -> [TimelineGeometry.TakeBand] {
        guard !expanded.isEmpty else { return [] }
        var out: [TimelineGeometry.TakeBand] = []
        for (i, track) in project.tracks.enumerated() {
            let count = track.takeFolders.reduce(0) { expanded.contains($1.id) ? $0 + $1.takes.count : $0 }
            if count > 0 { out.append(.init(row: g.displayRow(ofTrack: i), count: count)) }
        }
        return out
    }

    /// The take rows of track `id` (empty while its folders are collapsed), for the header column.
    func rows(of trackID: NodeIDValue) -> [TakeRow] {
        guard let g = window?.arrange.geometry else { return [] }
        return rows(geometry: g).filter { $0.trackID == trackID }
    }

    // MARK: Canvas geometry

    /// A folder's rectangle on its track's row (view coordinates), like a clip's.
    func folderRect(_ p: FolderPlacement, geometry g: TimelineGeometry) -> CGRect {
        let x0 = g.x(p.folder.start), x1 = g.x(p.folder.end)
        return CGRect(x: x0, y: g.rowY(p.row) + 1, width: max(x1 - x0, 1), height: g.trackHeight - 2)
    }

    /// The disclosure triangle's box of a folder (in its title band, at its left edge).
    func disclosureRect(_ p: FolderPlacement, geometry g: TimelineGeometry) -> CGRect {
        let r = folderRect(p, geometry: g)
        return CGRect(x: r.minX + 1, y: r.minY, width: Self.disclosureSize, height: Self.disclosureSize)
    }

    /// A take row's band (view coordinates, the full width).
    func rowRect(_ row: TakeRow, geometry g: TimelineGeometry) -> CGRect {
        CGRect(x: 0, y: g.takeRowY(row: row.row, take: row.band), width: g.size.width, height: g.trackHeight)
    }

    /// The take's clip on its row (view coordinates, inset like a clip).
    func takeRect(_ row: TakeRow, geometry g: TimelineGeometry) -> CGRect {
        let x0 = g.x(row.take.clip.start), x1 = g.x(row.take.clip.end)
        return CGRect(x: x0, y: g.takeRowY(row: row.row, take: row.band) + 1, width: max(x1 - x0, 1), height: g.trackHeight - 2)
    }

    /// The take row under `p`.
    func takeRowHit(_ p: CGPoint, geometry g: TimelineGeometry) -> TakeRow? {
        guard p.y >= TimelineGeometry.rulerHeight, !expanded.isEmpty else { return nil }
        let (row, band) = g.rowAndTake(ofSlot: g.slot(atY: p.y))
        guard band > 0 else { return nil }
        return rows(geometry: g).first { $0.row == row && $0.band == band }
    }

    /// The folder whose disclosure triangle is under `p`.
    func disclosureHit(_ p: CGPoint, geometry g: TimelineGeometry) -> FolderPlacement? {
        guard let row = g.row(atY: p.y), g.rowAndTake(ofSlot: g.slot(atY: p.y)).take == 0 else { return nil }
        return placements(geometry: g).last { $0.row == row && disclosureRect($0, geometry: g).insetBy(dx: -2, dy: -2).contains(p) }
    }

    /// The folder on the track row under `p` (its comp), if any.
    func folderHit(_ p: CGPoint, geometry g: TimelineGeometry) -> FolderPlacement? {
        guard let row = g.row(atY: p.y), g.rowAndTake(ofSlot: g.slot(atY: p.y)).take == 0 else { return nil }
        return placements(geometry: g).last { $0.row == row && folderRect($0, geometry: g).contains(p) }
    }

    /// The parts of `take` (cut at the comp's boundaries) and whether the comp plays each one.
    static func pieces(of take: Take, in folder: TakeFolder) -> [(start: Tick, end: Tick, inComp: Bool)] {
        let start = max(take.clip.start, folder.start), end = min(take.clip.end, folder.end)
        guard start < end else { return [] }
        var out: [(start: Tick, end: Tick, inComp: Bool)] = []
        for segment in folder.comp {
            let a = max(segment.start, start), b = min(segment.end, end)
            guard a < b else { continue }
            let inComp = segment.take == take.id
            if let last = out.last, last.inComp == inComp, last.end == a {
                out[out.count - 1].end = b
            } else {
                out.append((a, b, inComp))
            }
        }
        return out
    }

    /// `clip` cut to `[from, to)` (its audio kept in place, MIDI notes kept relative), like
    /// `TakeFolder.flattened` does for one segment; nil if nothing is left.
    static func cut(_ clip: Clip, from: Tick, to: Tick, tempo: TempoMap) -> Clip? {
        let from = max(from, clip.start), to = min(to, clip.end)
        guard to > from else { return nil }
        switch clip {
        case .audio(var a):
            a.sourceOffsetSamples += tempo.tickToSample(from) - tempo.tickToSample(a.start)
            a.start = from
            a.length = Tick(to.raw - from.raw)
            a.fadeIn = 0
            a.fadeOut = 0
            return .audio(a)
        case .midi(var m):
            let shift = from.raw - m.start.raw
            m.notes = m.notes.map { note in
                var note = note
                note.start = Tick(note.start.raw - shift)
                return note
            }
            m.start = from
            m.length = Tick(to.raw - from.raw)
            return .midi(m)
        }
    }

    /// The folders and take rows inside `g`'s viewport (rows and time).
    func visible(geometry g: TimelineGeometry) -> (folders: [FolderPlacement], rows: [TakeRow]) {
        let ticks = g.visibleTicks
        let tracks = g.visibleTracks(of: project.tracks.count)
        let folders = placements(geometry: g).filter {
            tracks.contains($0.trackIndex) && $0.folder.start < ticks.to && $0.folder.end > ticks.from
        }
        let top = g.slot(atY: TimelineGeometry.rulerHeight), bottom = g.slot(atY: g.size.height - 1)
        let rows = rows(geometry: g).filter { row in
            let slot = g.slot(ofRow: row.row) + row.band
            return slot >= top && slot <= bottom && row.take.clip.start < ticks.to && row.take.clip.end > ticks.from
        }
        return (folders, rows)
    }

    // MARK: Actions

    func toggleExpanded(_ folderID: ModelID) {
        if expanded.contains(folderID) { expanded.remove(folderID) } else { expanded.insert(folderID) }
    }

    /// The take plays over `[start, end)` (clamped to the folder and the take's clip). Nothing if
    /// the range is empty or the comp already plays it there. One undo entry ("Select Take").
    func select(_ takeID: ModelID, in folderID: ModelID, from start: Tick, to end: Tick) {
        guard let folder = project.takeFolder(folderID), let take = folder.take(takeID) else { return }
        let a = max(start, folder.start, take.clip.start), b = min(end, folder.end, take.clip.end)
        guard a < b, folder.comp(selecting: takeID, from: a, to: b) != folder.comp else { return }
        perform(SetCompSelection(folderID: folderID, start: a, end: b, takeID: takeID), label: "Select Take")
    }

    /// The take plays wherever it has a clip in the folder (the whole folder for a full pass).
    func selectWhole(_ takeID: ModelID, in folderID: ModelID) {
        guard let folder = project.takeFolder(folderID) else { return }
        select(takeID, in: folderID, from: folder.start, to: folder.end)
    }

    /// Deletes the folder and its takes (their audio files stay). One undo entry.
    func remove(_ folderID: ModelID) {
        guard project.takeFolder(folderID) != nil else { return }
        if swipe?.folderID == folderID { cancelSwipe() }
        perform(RemoveTakeFolder(folderID: folderID), label: "Delete Take Folder")
    }

    /// `ui.perform` "swipe" (UI-016, T-081): the swipe gesture on a take row as ticks. The id is
    /// `takeFolder.<folder>.take.<take>.swipe`; the range is clamped like a drag's (not snapped).
    func performSwipe(_ accessibilityID: String, start: Tick, end: Tick) throws(DAWError) {
        guard let (folderID, takeID) = Self.swipeTarget(accessibilityID), let folder = project.takeFolder(folderID),
              let take = folder.take(takeID)
        else { throw .invalidArgument("no take row \"\(accessibilityID)\" (takeFolder.<folder>.take.<take>.swipe)") }
        let a = max(min(start, end), folder.start, take.clip.start), b = min(max(start, end), folder.end, take.clip.end)
        guard a < b else {
            throw .invalidArgument("[\(start.raw), \(end.raw)) is outside take \(takeID) in folder \(folderID) ([\(max(folder.start, take.clip.start).raw), \(min(folder.end, take.clip.end).raw)))")
        }
        guard let store else { return }
        let before = store.project
        select(takeID, in: folderID, from: a, to: b)
        if store.project == before, folder.comp(selecting: takeID, from: a, to: b) != folder.comp {
            throw .invalidArgument("Select Take was refused")
        }
    }

    /// `takeFolder.<folder>.take.<take>.swipe` → (folder, take).
    static func swipeTarget(_ id: String) -> (ModelID, ModelID)? {
        let parts = id.split(separator: ".")
        guard parts.count == 5, parts[0] == "takeFolder", parts[2] == "take", parts[4] == "swipe",
              let folder = ModelID(parts[1]), let take = ModelID(parts[3]) else { return nil }
        return (folder, take)
    }

    static func swipeID(folder: ModelID, take: ModelID) -> String { "takeFolder.\(folder).take.\(take).swipe" }

    private func perform(_ command: any Command, label: String) {
        guard let window else { return }
        do {
            try window.store.perform(command)
        } catch {
            window.toasts.post(.error, .error, title: "\(label) failed", message: error.description)
        }
    }

    // MARK: Gestures (UI-016)

    var isDragging: Bool { swipe != nil }

    /// A press: on a folder's disclosure triangle toggles it; on a take row starts a swipe there.
    /// True if the press was taken.
    func mouseDown(at p: CGPoint, modifiers: CanvasModifiers, geometry g: TimelineGeometry, snap: (Tick) -> Tick) -> Bool {
        cancelSwipe()
        if let row = takeRowHit(p, geometry: g) {
            guard let folder = project.takeFolder(row.folderID) else { return true }
            let tick = clampToTake(swipeTick(p.x, modifiers: modifiers, geometry: g, snap: snap), row.take, folder)
            swipe = Swipe(folderID: row.folderID, takeID: row.take.id, down: p, anchor: tick, current: tick, started: false)
            activeGesture = "Swipe Take"
            return true
        }
        if let placement = disclosureHit(p, geometry: g) {
            toggleExpanded(placement.folder.id)
            return true
        }
        return false
    }

    func mouseDragged(to p: CGPoint, modifiers: CanvasModifiers, geometry g: TimelineGeometry, snap: (Tick) -> Tick) {
        guard var swipe, let folder = project.takeFolder(swipe.folderID), let take = folder.take(swipe.takeID) else { return }
        if !swipe.started {
            guard hypot(p.x - swipe.down.x, p.y - swipe.down.y) >= ArrangeModel.dragThreshold else { return }
            swipe.started = true
        }
        swipe.current = clampToTake(swipeTick(p.x, modifiers: modifiers, geometry: g, snap: snap), take, folder)
        if swipe != self.swipe { self.swipe = swipe }
    }

    /// Ends the swipe: the range plays the take (one undo entry), or a click selects the take for
    /// the whole folder.
    func mouseUp() {
        guard let swipe else { return }
        cancelSwipe()
        if swipe.started {
            let range = swipe.range
            select(swipe.takeID, in: swipe.folderID, from: range.start, to: range.end)
        } else {
            selectWhole(swipe.takeID, in: swipe.folderID)
        }
    }

    /// Drops the swipe without changing the comp.
    func cancelSwipe() {
        if swipe != nil { swipe = nil }
        if activeGesture != nil { activeGesture = nil }
    }

    private func swipeTick(_ x: Double, modifiers: CanvasModifiers, geometry g: TimelineGeometry, snap: (Tick) -> Tick) -> Tick {
        let tick = Tick(max(g.tick(atX: x).raw, 0))
        return modifiers.contains(.command) ? tick : snap(tick)
    }

    private func clampToTake(_ tick: Tick, _ take: Take, _ folder: TakeFolder) -> Tick {
        let lo = max(take.clip.start, folder.start), hi = min(take.clip.end, folder.end)
        return min(max(tick, lo), hi)
    }

    // MARK: Controls (UI-052)

    /// Per folder `takeFolder.<id>.expand` (toggle) and `takeFolder.<id>.remove`; per take of an
    /// expanded folder `takeFolder.<id>.take.<take>.select` (the take for the whole folder). The
    /// swipe (`takeFolder.<id>.take.<take>.swipe`) is a canvas gesture: `ui.perform` runs it with
    /// action `swipe` and `start`/`end`, and `ui.state` lists its id per take row.
    var controls: [UIControl] {
        var controls: [UIControl] = []
        for track in project.tracks {
            for folder in track.takeFolders {
                controls += folderControls(folder, trackName: track.name)
            }
        }
        return controls
    }

    func folderControls(_ folder: TakeFolder, trackName: String) -> [UIControl] {
        let id = folder.id
        var controls: [UIControl] = [
            .toggle("takeFolder.\(id).expand", "Show Takes of \(trackName)", isOn: expanded.contains(id)) { [weak self] in
                self?.toggleExpanded(id)
            },
            .button("takeFolder.\(id).remove", "Delete Take Folder on \(trackName)") { [weak self] in self?.remove(id) },
        ]
        if expanded.contains(id) {
            for (n, take) in folder.takes.enumerated() {
                controls.append(takeControl(folder: id, take: take.id, number: n + 1))
            }
        }
        return controls
    }

    func takeControl(folder: ModelID, take: ModelID, number: Int) -> UIControl {
        .button("takeFolder.\(folder).take.\(take).select", "Use Take \(number)") { [weak self] in self?.selectWhole(take, in: folder) }
    }
}
