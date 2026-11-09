import DAWModel
import Foundation

/// UI-030: the faders' dB taper, between a control's position (0 bottom, 1 top) and linear gain.
/// Piecewise linear in dB, with the resolution where it is used: unity at 0.75, +12 dB (the model's
/// `ChannelStripState.maxGain`) at the top, and position 0 is silence (gain 0, "−∞").
enum FaderTaper {
    /// (position, dB), ascending. Below the first point dB falls to `bottomDB` and position 0 is silence.
    static let points: [(position: Double, db: Double)] = [(0.05, -60), (0.25, -30), (0.5, -12), (0.75, 0), (1, 12)]
    /// The dB of positions just above 0. Position 0 itself is silence.
    static let bottomDB = -100.0
    static let unityPosition = 0.75
    /// `up`/`down` controls move a fader by this much; at or below `points[0].db`, `down` goes to silence.
    static let nudgeDB = 1.0

    static func position(gain: Float) -> Double {
        guard gain.isFinite, gain > 0 else { return 0 }
        return position(db: 20 * log10(Double(gain)))
    }

    static func position(db: Double) -> Double {
        if db <= bottomDB { return 0 }
        let first = points[0]
        if db < first.db { return (db - bottomDB) / (first.db - bottomDB) * first.position }
        for (a, b) in zip(points, points.dropFirst()) where db <= b.db {
            return a.position + (db - a.db) / (b.db - a.db) * (b.position - a.position)
        }
        return 1
    }

    /// Linear gain at `position`, within the model's range (MODEL-031).
    static func gain(position: Double) -> Float {
        guard position > 0 else { return 0 }
        return gain(db: db(position: position))
    }

    static func gain(db: Double) -> Float {
        min(Float(pow(10, db / 20)), ChannelStripState.maxGain)
    }

    static func db(position: Double) -> Double {
        let p = min(max(position, 0), 1)
        let first = points[0]
        if p < first.position { return bottomDB + p / first.position * (first.db - bottomDB) }
        for (a, b) in zip(points, points.dropFirst()) where p <= b.position {
            return a.db + (p - a.position) / (b.position - a.position) * (b.db - a.db)
        }
        return points[points.count - 1].db
    }

    /// `gain` moved by `delta` dB. Silence goes up to the bottom of the marked range, and a `down`
    /// at or below it goes to silence.
    static func nudged(gain: Float, by delta: Double) -> Float {
        let floorDB = points[0].db
        guard gain > 0 else { return delta > 0 ? Self.gain(db: floorDB) : 0 }
        let db = 20 * log10(Double(gain))
        if delta < 0, db <= floorDB { return 0 }
        return Self.gain(db: max(db + delta, floorDB))
    }

    /// "−3.0", "+1.5", "0.0", "−∞".
    static func label(gain: Float) -> String {
        guard gain > 0, gain.isFinite else { return "−∞" }
        let db = 20 * log10(Double(gain))
        if abs(db) < 0.05 { return "0.0" }
        return String(format: "%+.1f", db).replacingOccurrences(of: "-", with: "−")
    }
}

/// UI-030: pan as a control's position, and its readout.
enum PanTaper {
    /// `left`/`right` controls move a pan by this much.
    static let nudge: Float = 0.05

    static func position(pan: Float) -> Double { Double((pan + 1) / 2) }

    static func pan(position: Double) -> Float { min(max(Float(position * 2 - 1), -1), 1) }

    /// "C", "L40", "R25".
    static func label(pan: Float) -> String {
        let percent = Int((abs(pan) * 100).rounded())
        return percent == 0 ? "C" : pan < 0 ? "L\(percent)" : "R\(percent)"
    }
}
