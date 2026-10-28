/// A musical position at 960 PPQ (D-06). Every musical position in the model is a `Tick`.
public struct Tick: Hashable, Comparable, Codable, Sendable {
    /// Ticks per quarter note, `daw::kPPQ` in the engine.
    public static let ppq: Int64 = 960

    public var raw: Int64

    /// The end of the timeline: clips, tempo and signature events and the loop lie in
    /// 0…`timelineEnd` (T-030, MODEL-031). 2^40 ticks is about 18 years at 120 bpm, and at the
    /// slowest tempo and highest rate (1 bpm, 768 kHz: 48 000 samples a tick) still converts to a
    /// sample position far inside Int64, so `tickToSample` can't overflow on a valid position.
    public static let timelineEnd = Tick(1 << 40)

    public init(_ raw: Int64) { self.raw = raw }
    public init(raw: Int64) { self.raw = raw }

    public static func < (lhs: Tick, rhs: Tick) -> Bool { lhs.raw < rhs.raw }

    // A bare integer in JSON, so project files stay readable.
    public init(from decoder: any Decoder) throws {
        raw = try decoder.singleValueContainer().decode(Int64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

extension Tick: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { raw = value }
}

/// A sample position at the session rate, `daw::SamplePos` in the engine.
public typealias SamplePos = Int64
