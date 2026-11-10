/// 11 Model (T-074): an automation lane on a track, bus or the master (`automation`). It drives
/// one param slot (`target`, AUTO-008) from its points while playing (AUTO-002), as its `mode`
/// says (AUTO-005). One lane per target in the whole project.
///
/// JSON: `{"id": 9, "target": {"kind": "strip", "channel": 2, "param": "gain"}, "mode": "read",
/// "points": [{"tick": 0, "value": 0}, {"tick": 3840, "value": 1, "curve": "hold"}]}`.
public struct AutomationLane: Identifiable, Hashable, Sendable, Codable {
    /// AUTO-005/006. `off` ignores the lane. `read` plays it and overrides the control while
    /// playing. `touch`, `latch` and `write` record gestures (T-075); until then they play like
    /// `read`.
    public enum Mode: String, Hashable, Sendable, Codable, CaseIterable {
        case read, touch, latch, write, off
    }

    public var id: ModelID
    public var target: ParamTarget
    /// Strictly increasing ticks (an invariant, so equal lanes are equal values).
    public var points: [AutomationPoint]
    public var mode: Mode

    public init(id: ModelID, target: ParamTarget, points: [AutomationPoint] = [], mode: Mode = .read) {
        self.id = id
        self.target = target
        self.points = points
        self.mode = mode
    }

    /// Whether the engine plays it (AUTO-005).
    public var isEnabled: Bool { mode != .off }

    private enum CodingKeys: String, CodingKey { case id, target, points, mode }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ModelID.self, forKey: .id)
        target = try c.decode(ParamTarget.self, forKey: .target)
        points = try c.decodeIfPresent([AutomationPoint].self, forKey: .points) ?? []
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .read
    }
}

/// 11 Model: one breakpoint. `value` is normalized 0…1; the engine maps it through the target's
/// range (`ParamInfo`, or the plugin parameter's). `curve` shapes the segment from this point to
/// the next one (AUTO-004).
///
/// JSON: `{"tick": 960, "value": 0.5}` (linear), `"curve": "hold"`, or `"curve": "exp", "shape": 3`.
public struct AutomationPoint: Hashable, Sendable, Codable {
    public enum Curve: Hashable, Sendable {
        case linear
        /// A step: the value holds until the next point.
        case hold
        /// `(e^(s·f) − 1) / (e^s − 1)` of the way at fraction f; s > 0 starts slowly, s < 0 fast.
        /// |s| ≤ `maxShape`.
        case exp(Float)
    }

    /// Exponential shapes beyond this are rejected (the engine clamps to the same, AutomationCurve.h).
    public static let maxShape: Float = 50

    public var tick: Tick
    public var value: Float
    public var curve: Curve

    public init(tick: Tick, value: Float, curve: Curve = .linear) {
        self.tick = tick
        self.value = value
        self.curve = curve
    }

    private enum CodingKeys: String, CodingKey { case tick, value, curve, shape }
    private enum CurveName: String, Codable { case linear, hold, exp }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tick = try c.decode(Tick.self, forKey: .tick)
        value = try c.decode(Float.self, forKey: .value)
        switch try c.decodeIfPresent(CurveName.self, forKey: .curve) ?? .linear {
        case .linear: curve = .linear
        case .hold: curve = .hold
        case .exp: curve = .exp(try c.decode(Float.self, forKey: .shape))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tick, forKey: .tick)
        try c.encode(value, forKey: .value)
        switch curve {
        case .linear: break  // the default, left out
        case .hold: try c.encode(CurveName.hold, forKey: .curve)
        case .exp(let shape):
            try c.encode(CurveName.exp, forKey: .curve)
            try c.encode(shape, forKey: .shape)
        }
    }

    /// The engine's wire values (AutomationPointDesc: curve 0 linear, 1 hold, 2 exponential).
    var engineCurve: (curve: UInt8, shape: Float) {
        switch curve {
        case .linear: (0, 0)
        case .hold: (1, 0)
        case .exp(let shape): (2, shape)
        }
    }
}
