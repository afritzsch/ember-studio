import CoreGraphics
import DAWModel
import Foundation

/// The arrange canvas's coordinate system (UI-010), in view points with y down: a ruler strip at
/// the top, then one row of `trackHeight` per track. Content x is `tick × pixelsPerTick`; the view
/// shows content from `scrollX`/`scrollY`.
struct TimelineGeometry: Equatable, Sendable {
    static let rulerHeight = 22.0

    var pixelsPerBeat: Double
    var scrollX: Double
    var scrollY: Double
    var trackHeight: Double
    var size: CGSize

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

    /// A clip's rectangle in view coordinates (one point of inset between rows).
    func rect(start: Tick, length: Tick, row: Int) -> CGRect {
        let x0 = x(start)
        let x1 = x(Tick(start.raw + length.raw))
        return CGRect(x: x0, y: rowY(row) + 1, width: max(x1 - x0, 1), height: trackHeight - 2)
    }
}
