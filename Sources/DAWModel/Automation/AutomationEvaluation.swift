import Foundation

/// AUTO-004 (T-075): the model's mirror of the engine's lane evaluation (automation/
/// AutomationCurve.h, AutomationPlayer): what a lane plays at a tick, so the controls can show it
/// (AUTO-007) and recording can keep the curve it doesn't overwrite.
extension AutomationLane {
    /// The normalized value at `tick`; nil without points. Before the first point the lane holds
    /// the first value, after the last the last; a point's curve shapes the segment it starts.
    public func value(at tick: Tick) -> Float? {
        guard let first = points.first else { return nil }
        if tick <= first.tick { return first.value }
        // The last point at or before `tick` (binary search: points are strictly increasing).
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if points[mid].tick <= tick { lo = mid } else { hi = mid - 1 }
        }
        guard lo + 1 < points.count else { return points[lo].value }
        return AutomationPoint.interpolate(points[lo], points[lo + 1], at: tick)
    }

    /// The point governing `tick`: the last at or before it.
    func pointIndex(atOrBefore tick: Tick) -> Int? {
        points.lastIndex { $0.tick <= tick }
    }
}

extension AutomationPoint {
    /// AUTO-004: the value between `a` and `b` (b after a) at `tick`, shaped by `a`'s curve,
    /// clamped to 0…1. Exponential: `(e^(s·f) − 1)/(e^s − 1)`, |s| < 1e-4 linear, s clamped ±50.
    public static func interpolate(_ a: AutomationPoint, _ b: AutomationPoint, at tick: Tick) -> Float {
        let span = Double(b.tick.raw - a.tick.raw)
        guard span > 0 else { return clamp(b.value) }
        let f = Swift.min(Swift.max(Double(tick.raw - a.tick.raw) / span, 0), 1)
        var w: Double
        switch a.curve {
        case .linear: w = f
        case .hold: w = f >= 1 ? 1 : 0
        case .exp(let shape):
            let s = shape.isFinite ? Swift.min(Swift.max(Double(shape), -Double(maxShape)), Double(maxShape)) : 0
            w = abs(s) < 1e-4 ? f : expm1(s * f) / expm1(s)
        }
        return clamp(Float(Double(a.value) + (Double(b.value) - Double(a.value)) * w))
    }

    private static func clamp(_ v: Float) -> Float { v >= 0 ? (v <= 1 ? v : 1) : 0 }
}

/// AUTO-006 (T-075): Ramer–Douglas–Peucker thinning of a recorded gesture. A point is dropped
/// when the line between the points kept around it passes within `epsilon` of its value at its
/// tick (vertical distance, in normalized units: ε = 0.005 is 0.5 % of the range). The first and
/// last points are always kept. Iterative (an explicit stack), so long gestures don't recurse.
public enum AutomationThinning {
    /// AUTO-006: 0.5 % of the normalized range.
    public static let defaultEpsilon: Float = 0.005

    public static func thin(_ points: [AutomationPoint], epsilon: Float = defaultEpsilon) -> [AutomationPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            let pa = points[a], pb = points[b]
            let span = Double(pb.tick.raw - pa.tick.raw)
            var worst = -1.0, worstIndex = a
            for i in (a + 1)..<b {
                let f = span > 0 ? Double(points[i].tick.raw - pa.tick.raw) / span : 0
                let line = Double(pa.value) + (Double(pb.value) - Double(pa.value)) * f
                let d = abs(Double(points[i].value) - line)
                if d > worst { worst = d; worstIndex = i }
            }
            if worst > Double(epsilon) {
                keep[worstIndex] = true
                stack.append((a, worstIndex))
                stack.append((worstIndex, b))
            }
        }
        return points.indices.compactMap { keep[$0] ? points[$0] : nil }
    }
}
