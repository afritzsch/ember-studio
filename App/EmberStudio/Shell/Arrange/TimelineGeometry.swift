import CoreGraphics
import DAWModel
import Foundation

/// The arrange canvas's coordinate system (UI-010), in view points with y down: a ruler strip at
/// the top, then rows of `trackHeight`: one per track, followed by one per automation lane of a
/// track whose lanes are expanded (UI-015, T-075). Content x is `tick × pixelsPerTick`; the view
/// shows content from `scrollX`/`scrollY`.
///
/// "Row" means a display row (track or lane); clip APIs take a *track index* and map it through
/// `trackRows` (empty: no lanes expanded, so track index = row).
struct TimelineGeometry: Equatable, Sendable {
    static let rulerHeight = 22.0

    var pixelsPerBeat: Double
    var scrollX: Double
    var scrollY: Double
    var trackHeight: Double
    var size: CGSize
    /// UI-015 (T-075): the display row of each track, ascending; empty when no lanes show.
    var trackRows: [Int] = []
    /// UI-015: rows in all (tracks and lanes); nil when `trackRows` is empty.
    var rowTotal: Int?
    /// UI-016 (T-081): the take rows of expanded take folders, as bands of `trackHeight` right
    /// under a display row (a track's own row), sorted by row. They take no row numbers, so lane
    /// rows (T-075) and clip rows keep theirs; they only push later rows down. Empty: none.
    var takeBands: [TakeBand] = []

    /// UI-016: `count` take rows under display row `row`.
    struct TakeBand: Equatable, Sendable {
        var row: Int
        var count: Int
    }

    var pixelsPerTick: Double { pixelsPerBeat / Double(Tick.ppq) }

    // MARK: Time ↔ x

    /// The view x of `tick`.
    func x(_ tick: Tick) -> Double { Double(tick.raw) * pixelsPerTick - scrollX }

    /// The tick at view x (nearest).
    func tick(atX x: Double) -> Tick { Tick(Int64(((x + scrollX) / pixelsPerTick).rounded())) }

    /// A distance in points as ticks (nearest).
    func ticks(forWidth width: Double) -> Int64 { Int64((width / pixelsPerTick).rounded()) }

    /// The ticks the view shows, `[from, to)`.
    var visibleTicks: (from: Tick, to: Tick) {
        (Tick(Int64((scrollX / pixelsPerTick).rounded(.down))),
         Tick(Int64(((scrollX + size.width) / pixelsPerTick).rounded(.up)) + 1))
    }

    // MARK: Rows ↔ y

    /// The view y of the top of row `index`.
    func rowY(_ index: Int) -> Double { slotY(slot(ofRow: index)) }

    /// The row at view y (may be negative or past the last track); nil inside the ruler. A take
    /// row (UI-016) counts as the row it is under.
    func row(atY y: Double) -> Int? {
        guard y >= Self.rulerHeight else { return nil }
        return rowAndTake(ofSlot: slot(atY: y)).row
    }

    /// The row at view y without the ruler check (a drag that strays over the ruler stays on row 0 or above).
    func rowUnclamped(atY y: Double) -> Int { rowAndTake(ofSlot: slot(atY: y)).row }

    /// The rows at least partly visible, clamped to `0..<rows`.
    func visibleRows(of rows: Int) -> Range<Int> {
        let top = Int((scrollY / trackHeight).rounded(.down))
        let bottom = Int(((scrollY + max(size.height - Self.rulerHeight, 0)) / trackHeight).rounded(.up))
        guard !takeBands.isEmpty else {
            let lo = min(max(top, 0), rows)
            return lo..<min(max(bottom, lo), rows)
        }
        // UI-016: through the slots (take rows show their row's track).
        let lo = min(max(rowAndTake(ofSlot: top).row, 0), rows)
        let hi = bottom > top ? rowAndTake(ofSlot: bottom - 1).row + 1 : lo
        return lo..<min(max(hi, lo), rows)
    }

    // MARK: Slots: rows and take rows (UI-016, T-081)

    /// A slot is a band of `trackHeight` counted from the top of the content: each display row
    /// is one, and each take row under it (`takeBands`) one more.
    func slot(ofRow row: Int) -> Int {
        guard !takeBands.isEmpty else { return row }
        var slot = row
        for band in takeBands where band.row < row { slot += band.count }
        return slot
    }

    /// The display row a slot belongs to, and which band of it: 0 the row itself, k ≥ 1 its k-th
    /// take row.
    func rowAndTake(ofSlot slot: Int) -> (row: Int, take: Int) {
        guard !takeBands.isEmpty, slot >= 0 else { return (slot, 0) }
        var offset = 0
        for band in takeBands {
            if slot <= band.row + offset { return (slot - offset, 0) }
            if slot <= band.row + offset + band.count { return (band.row, slot - band.row - offset) }
            offset += band.count
        }
        return (slot - offset, 0)
    }

    /// The view y of the top of slot `slot`.
    func slotY(_ slot: Int) -> Double { Self.rulerHeight + Double(slot) * trackHeight - scrollY }

    /// The slot at view y (no ruler check).
    func slot(atY y: Double) -> Int { Int(((y - Self.rulerHeight + scrollY) / trackHeight).rounded(.down)) }

    /// The view y of the top of take row `take` (1-based) under display row `row`.
    func takeRowY(row: Int, take: Int) -> Double { slotY(slot(ofRow: row) + take) }

    /// Take rows in all.
    var takeRowTotal: Int { takeBands.reduce(0) { $0 + $1.count } }

    /// Slots in all for `tracks` tracks (rows, lanes and take rows): the content height in rows.
    func slotCount(tracks: Int) -> Int { rowCount(tracks: tracks) + takeRowTotal }

    /// A clip's rectangle in view coordinates (one point of inset between rows); `row` is the
    /// clip's track index.
    func rect(start: Tick, length: Tick, row: Int) -> CGRect {
        let x0 = x(start)
        let x1 = x(Tick(start.raw + length.raw))
        return CGRect(x: x0, y: rowY(displayRow(ofTrack: row)) + 1, width: max(x1 - x0, 1), height: trackHeight - 2)
    }

    // MARK: Tracks ↔ display rows (UI-015, T-075)

    /// Rows in all for `tracks` tracks.
    func rowCount(tracks: Int) -> Int { rowTotal ?? tracks }

    /// The display row of track `index` (indices past the last track continue after the last row).
    func displayRow(ofTrack index: Int) -> Int {
        guard !trackRows.isEmpty else { return index }
        if index < 0 { return index }
        if index < trackRows.count { return trackRows[index] }
        return (rowTotal ?? trackRows.count) + (index - trackRows.count)
    }

    /// The track whose own row (not a lane) is display row `row`, nil for a lane row.
    func track(ofRow row: Int) -> Int? {
        guard !trackRows.isEmpty else { return row }
        if row < 0 { return row }
        if let i = trackRows.firstIndex(of: row) { return i }
        let total = rowTotal ?? trackRows.count
        return row >= total ? trackRows.count + (row - total) : nil
    }

    /// The track at view y: its own row's, nil on a lane row or in the ruler.
    func track(atY y: Double) -> Int? { row(atY: y).flatMap { track(ofRow: $0) } }

    /// The track a display row belongs to (a lane row belongs to the track above it).
    func owningTrack(ofRow row: Int) -> Int {
        guard !trackRows.isEmpty, row >= 0 else { return row }
        let total = rowTotal ?? trackRows.count
        if row >= total { return trackRows.count + (row - total) }
        return (trackRows.lastIndex { $0 <= row }) ?? 0
    }

    /// `rowUnclamped` as a track index (a lane row counts as its track).
    func trackUnclamped(atY y: Double) -> Int { owningTrack(ofRow: rowUnclamped(atY: y)) }

    /// The tracks with a row (own or lane) at least partly visible, clamped to `0..<tracks`.
    func visibleTracks(of tracks: Int) -> Range<Int> {
        guard !trackRows.isEmpty else { return visibleRows(of: tracks) }
        let rows = visibleRows(of: rowCount(tracks: tracks))
        guard !rows.isEmpty else { return 0..<0 }
        let lo = owningTrack(ofRow: rows.lowerBound)
        let hi = owningTrack(ofRow: rows.upperBound - 1)
        return min(lo, tracks)..<min(hi + 1, tracks)
    }
}
