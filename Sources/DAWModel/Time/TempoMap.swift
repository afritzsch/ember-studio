
/// A step change to `bpm` at `tick` (no ramps in v1).
public struct TempoEvent: Hashable, Codable, Sendable {
    public var tick: Tick
    public var bpm: Double

    public init(tick: Tick, bpm: Double) {
        self.tick = tick
        self.bpm = bpm
    }
}

/// `numerator`/`denominator` from `tick` onward. The beat is one 1/denominator note. A signature
/// event always starts a new bar, so an event that isn't on a bar line of the previous signature
/// cuts that bar short.
public struct TimeSignatureEvent: Hashable, Codable, Sendable {
    public var tick: Tick
    public var numerator: Int
    public var denominator: Int

    public init(tick: Tick, numerator: Int, denominator: Int) {
        self.tick = tick
        self.numerator = numerator
        self.denominator = denominator
    }
}

/// Bars and beats are 1-based, `tick` is the offset inside the beat (0 ..< beat length). Ticks
/// before 0 extrapolate the first signature backwards, so they land in bar 0, -1, …
public struct BBT: Hashable, Codable, Sendable {
    public var bar: Int
    public var beat: Int
    public var tick: Int

    public init(bar: Int, beat: Int, tick: Int) {
        self.bar = bar
        self.beat = beat
        self.tick = tick
    }
}

/// Mirrors `daw::TempoMapError` (without `ok`). Codable (as its case name) because it travels
/// inside `DAWError.invalidTempoMap` (DW-021).
public enum TempoMapError: String, Error, Hashable, Sendable, Codable {
    case noTempoEvents
    case noTimeSignatures
    case firstEventNotAtTickZero
    case eventsNotAscending
    case tempoOutOfRange
    case invalidTimeSignature
    case sampleRateOutOfRange
}

/// Converts between ticks, sample positions and bars/beats.
///
/// TIME-011: this is the Swift mirror of `daw::TempoMap` (Sources/DAWEngine/time/TempoMap.h) and
/// must give bit-identical results, so the arithmetic below follows the C++ step for step.
/// `Tests/Fixtures/tempo_vectors.json` is checked against both.
public struct TempoMap: Hashable, Codable, Sendable {
    public static let minBPM = 1.0
    public static let maxBPM = 1000.0
    public static let minSampleRate = 1000.0
    public static let maxSampleRate = 768_000.0
    public static let maxTimeSignatureNumerator = 64
    public static let maxTimeSignatureDenominator = 64

    public let tempoEvents: [TempoEvent]
    public let timeSignatures: [TimeSignatureEvent]
    /// The rate the sample conversions use. Inside a `Project` this always equals
    /// `Project.sessionSampleRate`, which is the source of truth (DW-020).
    public let sampleRate: Double

    // Precomputed per event, as in the engine (TIME-001).
    private struct TempoSegment: Sendable {
        var tick: Int64
        var bpm: Double
        var startSample: Double
        var samplesPerTick: Double
    }

    private struct SigSegment: Sendable {
        var tick: Int64
        var firstBar: Int64
        var beatTicks: Int64
        var barTicks: Int64
    }

    private let tempoSegments: [TempoSegment]
    private let sigSegments: [SigSegment]

    /// 120 bpm, 4/4, 48 kHz.
    public init() {
        self.init(
            validated: [TempoEvent(tick: 0, bpm: 120)],
            [TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)],
            48_000)
    }

    public init(
        tempoEvents: [TempoEvent], timeSignatures: [TimeSignatureEvent], sampleRate: Double
    ) throws(TempoMapError) {
        if let error = Self.validate(
            tempoEvents: tempoEvents, timeSignatures: timeSignatures, sampleRate: sampleRate)
        {
            throw error
        }
        self.init(validated: tempoEvents, timeSignatures, sampleRate)
    }

    /// The same events at another rate (DW-020: changing the session rate rebuilds the map).
    public func withSampleRate(_ sampleRate: Double) throws(TempoMapError) -> TempoMap {
        try TempoMap(tempoEvents: tempoEvents, timeSignatures: timeSignatures, sampleRate: sampleRate)
    }

    /// The first problem found, in the same order as `daw::TempoMap::validate`, or nil.
    public static func validate(
        tempoEvents: [TempoEvent], timeSignatures: [TimeSignatureEvent], sampleRate: Double
    ) -> TempoMapError? {
        guard sampleRate >= minSampleRate && sampleRate <= maxSampleRate else {
            return .sampleRateOutOfRange
        }
        guard !tempoEvents.isEmpty else { return .noTempoEvents }
        for (i, event) in tempoEvents.enumerated() {
            if i == 0 && event.tick.raw != 0 { return .firstEventNotAtTickZero }
            if i > 0 && event.tick <= tempoEvents[i - 1].tick { return .eventsNotAscending }
            if !(event.bpm >= minBPM && event.bpm <= maxBPM) { return .tempoOutOfRange }
        }
        guard !timeSignatures.isEmpty else { return .noTimeSignatures }
        for (i, event) in timeSignatures.enumerated() {
            if i == 0 && event.tick.raw != 0 { return .firstEventNotAtTickZero }
            if i > 0 && event.tick <= timeSignatures[i - 1].tick { return .eventsNotAscending }
            let den = event.denominator
            let validDenominator =
                den >= 1 && den <= maxTimeSignatureDenominator && den & (den - 1) == 0
            if event.numerator < 1 || event.numerator > maxTimeSignatureNumerator
                || !validDenominator
            {
                return .invalidTimeSignature
            }
        }
        return nil
    }

    private init(
        validated tempoEvents: [TempoEvent], _ timeSignatures: [TimeSignatureEvent],
        _ sampleRate: Double
    ) {
        self.tempoEvents = tempoEvents
        self.timeSignatures = timeSignatures
        self.sampleRate = sampleRate

        var tempo: [TempoSegment] = []
        tempo.reserveCapacity(tempoEvents.count)
        for event in tempoEvents {
            var start = 0.0
            if let prev = tempo.last {
                // TIME-001: accumulate in double; only the outputs are rounded.
                start = prev.startSample
                    + (Double(event.tick.raw) - Double(prev.tick)) * prev.samplesPerTick
            }
            tempo.append(
                TempoSegment(
                    tick: event.tick.raw, bpm: event.bpm, startSample: start,
                    samplesPerTick: Self.samplesPerTick(sampleRate, event.bpm)))
        }
        tempoSegments = tempo

        var sigs: [SigSegment] = []
        sigs.reserveCapacity(timeSignatures.count)
        for event in timeSignatures {
            var firstBar: Int64 = 1
            if let prev = sigs.last {
                // A partial last bar still counts as a bar (see TimeSignatureEvent).
                firstBar = prev.firstBar + Self.ceilDiv(event.tick.raw - prev.tick, prev.barTicks)
            }
            let beatTicks = Tick.ppq * 4 / Int64(event.denominator)
            sigs.append(
                SigSegment(
                    tick: event.tick.raw, firstBar: firstBar, beatTicks: beatTicks,
                    barTicks: beatTicks * Int64(event.numerator)))
        }
        sigSegments = sigs
    }

    // MARK: Conversions

    /// TIME-001: the nearest sample to the exact position of `tick`. O(log n) in tempo events.
    public func tickToSample(_ tick: Tick) -> SamplePos {
        let s = tempoSegments[Self.segmentIndex(tempoSegments) { $0.tick <= tick.raw }]
        return Self.roundToInt64(
            s.startSample + (Double(tick.raw) - Double(s.tick)) * s.samplesPerTick)
    }

    /// TIME-001: the last tick whose `tickToSample` is <= `sample`, i.e. the tick sounding at that
    /// sample. `tickToSample(sampleToTick(s)) <= s < tickToSample(sampleToTick(s) + 1)`.
    public func sampleToTick(_ sample: SamplePos) -> Tick {
        // Same estimate-then-correct scheme as the engine; see TempoMap.cpp.
        let target = Double(sample) + 0.5
        let s = tempoSegments[Self.segmentIndex(tempoSegments) { $0.startSample <= target }]
        let offset = ((target - s.startSample) / s.samplesPerTick).rounded(.up) - 1.0
        var t = Self.clampToInt64(Double(s.tick) + offset)

        var i = 0
        while i < 4 && tickToSample(Tick(t + 1)) <= sample {
            t += 1
            i += 1
        }
        i = 0
        while i < 4 && tickToSample(Tick(t)) > sample {
            t -= 1
            i += 1
        }
        return Tick(t)
    }

    public func bpmAt(_ tick: Tick) -> Double {
        tempoSegments[Self.segmentIndex(tempoSegments) { $0.tick <= tick.raw }].bpm
    }

    /// TIME-002
    public func tickToBBT(_ tick: Tick) -> BBT {
        let s = sigSegments[Self.segmentIndex(sigSegments) { $0.tick <= tick.raw }]
        let rel = tick.raw - s.tick
        let barIndex = Self.floorDiv(rel, s.barTicks)
        let inBar = rel - barIndex * s.barTicks
        return BBT(
            bar: Int(s.firstBar + barIndex), beat: Int(inBar / s.beatTicks + 1),
            tick: Int(inBar % s.beatTicks))
    }

    /// TIME-002: inverse of `tickToBBT` for every BBT it returns. Other inputs (beat > numerator,
    /// tick >= beat length) extrapolate linearly within the bar's signature.
    public func bbtToTick(_ bbt: BBT) -> Tick {
        let bar = Int64(bbt.bar)
        let s = sigSegments[Self.segmentIndex(sigSegments) { $0.firstBar <= bar }]
        return Tick(
            s.tick + (bar - s.firstBar) * s.barTicks + Int64(bbt.beat - 1) * s.beatTicks
                + Int64(bbt.tick))
    }

    // MARK: Helpers (match the anonymous namespace in TempoMap.cpp)

    private static let maxPosition = 4_611_686_018_427_387_904.0  // 2^62

    private static func clampToInt64(_ x: Double) -> Int64 {
        Int64(min(max(x, -maxPosition), maxPosition))
    }

    /// Half away from zero, like `std::llround`.
    private static func roundToInt64(_ x: Double) -> Int64 {
        Int64(min(max(x, -maxPosition), maxPosition).rounded(.toNearestOrAwayFromZero))
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        a >= 0 ? a / b : -((-a - 1) / b) - 1
    }

    private static func ceilDiv(_ a: Int64, _ b: Int64) -> Int64 {
        (a + b - 1) / b  // a >= 0 only
    }

    private static func samplesPerTick(_ sampleRate: Double, _ bpm: Double) -> Double {
        (sampleRate * 60.0) / (bpm * Double(Tick.ppq))
    }

    /// Index of the last segment at or before the position, or 0 when the position precedes them
    /// all (the first segment extrapolates backwards). Same as the engine's upper_bound - 1.
    private static func segmentIndex<T>(_ segments: [T], _ isAtOrBefore: (T) -> Bool) -> Int {
        var lo = 0
        var hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if isAtOrBefore(segments[mid]) { lo = mid + 1 } else { hi = mid }
        }
        return max(lo - 1, 0)
    }

    // MARK: Hashable, Codable (only the events and rate; the segments are derived)

    public static func == (lhs: TempoMap, rhs: TempoMap) -> Bool {
        lhs.tempoEvents == rhs.tempoEvents && lhs.timeSignatures == rhs.timeSignatures
            && lhs.sampleRate == rhs.sampleRate
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(tempoEvents)
        hasher.combine(timeSignatures)
        hasher.combine(sampleRate)
    }

    private enum CodingKeys: String, CodingKey {
        case tempoEvents, timeSignatures, sampleRate
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tempos = try c.decode([TempoEvent].self, forKey: .tempoEvents)
        let sigs = try c.decode([TimeSignatureEvent].self, forKey: .timeSignatures)
        let rate = try c.decode(Double.self, forKey: .sampleRate)
        if let error = Self.validate(tempoEvents: tempos, timeSignatures: sigs, sampleRate: rate) {
            throw DecodingError.dataCorrupted(
                .init(codingPath: c.codingPath, debugDescription: "invalid tempo map: \(error)",
                      underlyingError: error))
        }
        self.init(validated: tempos, sigs, rate)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tempoEvents, forKey: .tempoEvents)
        try c.encode(timeSignatures, forKey: .timeSignatures)
        try c.encode(sampleRate, forKey: .sampleRate)
    }
}
