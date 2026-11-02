import DAWModel
import Foundation

/// UI-012: what clip edges snap to while dragging. Note values are measured from the start of the
/// bar (so a 7/8 bar's eighths and a 4/4 bar's sixteenths both line up with the bar line).
enum SnapMode: String, CaseIterable, Codable, Sendable {
    case off, bar, beat
    case eighth = "8", sixteenth = "16", thirtySecond = "32"
    case quarterTriplet = "4t", eighthTriplet = "8t", sixteenthTriplet = "16t", thirtySecondTriplet = "32t"

    var title: String {
        switch self {
        case .off: "Off"
        case .bar: "Bar"
        case .beat: "Beat"
        case .eighth: "1/8"
        case .sixteenth: "1/16"
        case .thirtySecond: "1/32"
        case .quarterTriplet: "1/4 Triplet"
        case .eighthTriplet: "1/8 Triplet"
        case .sixteenthTriplet: "1/16 Triplet"
        case .thirtySecondTriplet: "1/32 Triplet"
        }
    }

    /// The grid step of a note-value mode, in ticks (960 PPQ; a triplet is 2/3 of the straight
    /// value). Nil for `off`, `bar` and `beat`, whose length depends on the time signature.
    var noteTicks: Int64? {
        switch self {
        case .off, .bar, .beat: nil
        case .eighth: Tick.ppq / 2
        case .sixteenth: Tick.ppq / 4
        case .thirtySecond: Tick.ppq / 8
        case .quarterTriplet: Tick.ppq * 2 / 3
        case .eighthTriplet: Tick.ppq / 3
        case .sixteenthTriplet: Tick.ppq / 6
        case .thirtySecondTriplet: Tick.ppq / 12
        }
    }
}

/// A grid line the canvas draws (UI-012).
struct GridLine: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A bar line, with its 1-based bar number.
        case bar(Int)
        case beat
        /// A line of the snap resolution between beats.
        case subdivision
    }

    var tick: Tick
    var kind: Kind
}

/// UI-012: bars and beats from the project's tempo map (its time signatures), snapping and the grid
/// lines to draw. Pure value math, unit-tested in `SnapGridTests`.
struct SnapGrid: Sendable {
    let tempoMap: TempoMap

    /// The bar containing `tick` as (start, length) in ticks. Ticks before 0 belong to bar 1.
    func bar(containing tick: Tick) -> (start: Tick, length: Int64) {
        let bbt = tempoMap.tickToBBT(Tick(max(tick.raw, 0)))
        let start = tempoMap.bbtToTick(BBT(bar: bbt.bar, beat: 1, tick: 0))
        let next = tempoMap.bbtToTick(BBT(bar: bbt.bar + 1, beat: 1, tick: 0))
        return (start, next.raw - start.raw)
    }

    /// The bar number (1-based) containing `tick`.
    func barNumber(at tick: Tick) -> Int { tempoMap.tickToBBT(Tick(max(tick.raw, 0))).bar }

    /// The beat length (one denominator note) at `tick`.
    func beatTicks(at tick: Tick) -> Int64 {
        let bar = bar(containing: tick)
        let bbt = tempoMap.tickToBBT(bar.start)
        // bbtToTick extrapolates beat 2 within the bar's signature even for 1/x bars.
        return tempoMap.bbtToTick(BBT(bar: bbt.bar, beat: 2, tick: 0)).raw - bar.start.raw
    }

    /// The step `mode` moves in at `tick` (bar, beat or note value); `off` steps by a beat, which is
    /// what a nudge with snapping off moves by.
    func step(_ mode: SnapMode, at tick: Tick) -> Int64 {
        switch mode {
        case .bar: bar(containing: tick).length
        case .beat, .off: beatTicks(at: tick)
        default: mode.noteTicks!
        }
    }

    /// UI-012: the grid line of `mode` nearest to `tick` (ties go to the later line); `off` returns
    /// `tick`. Lines restart at every bar line, so a bar that isn't a whole number of steps (7/8 at
    /// 1/4 triplets) still snaps to its bar lines. Never before 0.
    func snap(_ tick: Tick, _ mode: SnapMode) -> Tick {
        guard mode != .off else { return tick }
        let bar = bar(containing: tick)
        let barEnd = bar.start.raw + bar.length
        let step = mode == .bar ? bar.length : self.step(mode, at: tick)
        let rel = max(tick.raw, 0) - bar.start.raw
        // Nearest multiple of `step` inside the bar, then whichever of it and the next bar line is closer.
        let below = bar.start.raw + (rel / step) * step
        let above = min(below + step, barEnd)
        let nearest = max(tick.raw, 0) - below < above - max(tick.raw, 0) ? below : above
        return Tick(max(nearest, 0))
    }

    /// The lines to draw over `[from, to)` with at least `minSpacing` ticks between lines of one kind:
    /// bar lines (every 2ⁿth bar when bars are closer than that), beats when they fit, and the snap
    /// resolution's lines when they fit. Sorted by tick; at most one line per tick (the strongest).
    func lines(from: Tick, to: Tick, minSpacing: Double, snap mode: SnapMode) -> [GridLine] {
        guard to > from else { return [] }
        var lines: [GridLine] = []
        var barNumber = barNumber(at: from)
        var bar = self.bar(containing: from)
        // Thin bars by powers of two so a zoomed-out view still draws a bounded number of lines.
        var barEvery = 1
        while Double(bar.length) * Double(barEvery) < minSpacing && barEvery < 1 << 20 { barEvery *= 2 }
        let subStep = mode.noteTicks
        // Bounded by the visible bars (thinned), each with a bounded number of lines.
        while bar.start < to {
            if (barNumber - 1) % barEvery == 0 {
                if bar.start >= from { lines.append(GridLine(tick: bar.start, kind: .bar(barNumber))) }
                if barEvery == 1 {
                    let beat = beatTicks(at: bar.start)
                    let drawBeats = Double(beat) >= minSpacing
                    let sub = subStep.flatMap { Double($0) >= minSpacing && $0 < beat ? $0 : nil }
                    let fine = sub ?? (drawBeats ? beat : nil)
                    if let fine {
                        var t = bar.start.raw + fine
                        while t < bar.start.raw + bar.length && t < to.raw {
                            if t >= from.raw {
                                let onBeat = (t - bar.start.raw) % beat == 0
                                if onBeat && drawBeats {
                                    lines.append(GridLine(tick: Tick(t), kind: .beat))
                                } else if !onBeat {
                                    lines.append(GridLine(tick: Tick(t), kind: .subdivision))
                                }
                            }
                            t += fine
                        }
                    }
                }
            }
            barNumber += 1
            let next = tempoMap.bbtToTick(BBT(bar: barNumber, beat: 1, tick: 0))
            let nextNext = tempoMap.bbtToTick(BBT(bar: barNumber + 1, beat: 1, tick: 0))
            bar = (next, nextNext.raw - next.raw)
        }
        return lines
    }
}
