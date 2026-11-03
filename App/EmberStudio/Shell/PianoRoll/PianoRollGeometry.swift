import CoreGraphics
import DAWModel
import Foundation

/// UI-020: the piano roll's coordinate system, in view points with y down:
///
///     ┌ corner ┬ ruler (bars) ─────────────────────────────┐  rulerHeight
///     │ keys   │ note grid: one row of keyHeight per pitch, │
///     │ 127…0  │ 127 at the top; x = timeline ticks         │
///     ├ "Vel"  ┼ velocity lane: a stem per note ────────────┤  laneHeight
///
/// Content x is the absolute timeline tick × `pixelsPerTick` (so the grid lines up with bars and
/// beats of the tempo map, UI-012); content y is `(127 − pitch) × keyHeight`. The view shows content
/// from `scrollX`/`scrollY`. Notes are relative to their clip (MODEL-005), so `clipStart` converts.
struct PianoRollGeometry: Equatable, Sendable {
    static let keyboardWidth = 48.0
    static let rulerHeight = 18.0
    static let laneHeight = 72.0
    static let pitchCount = 128

    var pixelsPerBeat: Double
    var keyHeight: Double
    var scrollX: Double
    var scrollY: Double
    var size: CGSize
    /// The open clip's start on the timeline (0 with no clip).
    var clipStart: Int64

    var pixelsPerTick: Double { pixelsPerBeat / Double(Tick.ppq) }
    var contentHeight: Double { Double(Self.pitchCount) * keyHeight }

    // MARK: Areas

    /// The note grid, right of the keyboard, between the ruler and the velocity lane.
    var gridRect: CGRect {
        CGRect(x: Self.keyboardWidth, y: Self.rulerHeight, width: max(size.width - Self.keyboardWidth, 0),
               height: max(size.height - Self.rulerHeight - Self.laneHeight, 0))
    }

    var keyboardRect: CGRect { CGRect(x: 0, y: Self.rulerHeight, width: Self.keyboardWidth, height: gridRect.height) }
    var rulerRect: CGRect { CGRect(x: Self.keyboardWidth, y: 0, width: gridRect.width, height: Self.rulerHeight) }
    var laneRect: CGRect { CGRect(x: Self.keyboardWidth, y: gridRect.maxY, width: gridRect.width, height: Self.laneHeight) }

    // MARK: Time ↔ x

    /// The view x of an absolute tick.
    func x(_ tick: Int64) -> Double { Self.keyboardWidth + Double(tick) * pixelsPerTick - scrollX }

    /// The absolute tick at view x (nearest).
    func tick(atX x: Double) -> Int64 { Int64(((x - Self.keyboardWidth + scrollX) / pixelsPerTick).rounded()) }

    /// The absolute tick at view x, rounded down (the grid cell a click is in).
    func tickFloor(atX x: Double) -> Int64 { Int64(((x - Self.keyboardWidth + scrollX) / pixelsPerTick).rounded(.down)) }

    func ticks(forWidth width: Double) -> Int64 { Int64((width / pixelsPerTick).rounded()) }

    /// The absolute ticks the grid shows, `[from, to)`.
    var visibleTicks: (from: Int64, to: Int64) {
        (Int64((scrollX / pixelsPerTick).rounded(.down)), Int64(((scrollX + gridRect.width) / pixelsPerTick).rounded(.up)) + 1)
    }

    // MARK: Pitch ↔ y

    /// The view y of the top of `pitch`'s row.
    func rowY(_ pitch: Int) -> Double { Self.rulerHeight + Double(127 - pitch) * keyHeight - scrollY }

    /// The pitch at view y, unclamped (may be outside 0…127).
    func pitch(atY y: Double) -> Int { 127 - Int(((y - Self.rulerHeight + scrollY) / keyHeight).rounded(.down)) }

    /// The pitches at least partly visible in the grid, clamped to 0…127 (empty with no grid).
    var visiblePitches: ClosedRange<Int>? {
        guard gridRect.height > 0 else { return nil }
        let high = min(max(pitch(atY: gridRect.minY), 0), 127)
        let low = min(max(pitch(atY: gridRect.maxY - 0.001), 0), 127)
        return low...max(low, high)
    }

    // MARK: Notes

    /// A note's rectangle in view coordinates (half a point of inset between rows).
    func rect(_ note: Note) -> CGRect {
        let x0 = x(clipStart + note.start.raw)
        let x1 = x(clipStart + note.start.raw + note.length.raw)
        return CGRect(x: x0, y: rowY(Int(note.pitch)) + 0.5, width: max(x1 - x0, 2), height: max(keyHeight - 1, 1))
    }

    /// The top of a velocity stem in the lane.
    func velocityY(_ velocity: UInt8) -> Double {
        let lane = laneRect
        return lane.maxY - 4 - (lane.height - 8) * Double(velocity) / 127
    }

    /// Velocity points per unit of velocity (the lane's usable height over 127).
    var velocityPointsPerStep: Double { max(laneRect.height - 8, 1) / 127 }
}

extension SnapGrid {
    /// UI-020: the grid line of `mode` at or before `tick` (where a click draws a note), with
    /// lines restarting at every bar line as in `snap`; `off` returns `tick`. Never before 0.
    func floor(_ tick: Tick, _ mode: SnapMode) -> Tick {
        let t = max(tick.raw, 0)
        guard mode != .off else { return Tick(t) }
        let bar = bar(containing: Tick(t))
        let step = mode == .bar ? bar.length : self.step(mode, at: Tick(t))
        return Tick(bar.start.raw + (t - bar.start.raw) / step * step)
    }
}
