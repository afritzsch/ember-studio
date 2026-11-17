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
    func rowY(_ index: Int) -> Double { Self.rulerHeight + Double(index) * trackHeight - scrollY }

    /// The row at view y (may be negative or past the last track); nil inside the ruler.
    func row(atY y: Double) -> Int? {
        guard y >= Self.rulerHeight else { return nil }
        return Int(((y - Self.rulerHeight + scrollY) / trackHeight).rounded(.down))
    }

    /// The row at view y without the ruler check (a drag that strays over the ruler stays on row 0 or above).
    func rowUnclamped(atY y: Double) -> Int {
        Int(((y - Self.rulerHeight + scrollY) / trackHeight).rounded(.down))
    }

    /// The rows at least partly visible, clamped to `0..<rows`.
    func visibleRows(of rows: Int) -> Range<Int> {
        let top = Int((scrollY / trackHeight).rounded(.down))
        let bottom = Int(((scrollY + max(size.height - Self.rulerHeight, 0)) / trackHeight).rounded(.up))
        let lo = min(max(top, 0), rows)
        return lo..<min(max(bottom, lo), rows)
    }

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
