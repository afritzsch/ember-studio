import DAWEngineInternals
import Foundation
import Testing

// C++ daw::TempoMap (Sources/DAWEngine/time). The Swift mirror has the same tests in
// Tests/DAWModelTests/TempoMapTests.swift; both read Tests/Fixtures/tempo_vectors.json.

@Suite("TempoMap (C++)")
struct EngineTempoMapTests {
    @Test("TIME-011: daw::TempoMap matches tempo_vectors.json")
    func sharedVectors() throws {
        let vectors = try TempoVectors.load()
        #expect(vectors.ppq == Int(daw.kPPQ))
        for v in vectors.maps {
            let map = try #require(makeMap(v.tempos, v.timeSignatures, v.sampleRate), "\(v.name)")
            for p in v.tickToSample {
                #expect(map.tickToSample(p.a) == p.b, "\(v.name): tickToSample(\(p.a))")
            }
            // The double arithmetic itself: these flip if a + b*c gets fused into an FMA.
            for p in v.tickToSampleBitExact {
                #expect(map.tickToSample(p.a) == p.b, "\(v.name): bit-exact tickToSample(\(p.a))")
            }
            for p in v.sampleToTick {
                #expect(map.sampleToTick(p.a) == p.b, "\(v.name): sampleToTick(\(p.a))")
            }
            for p in v.bpmAt {
                #expect(map.bpmAt(p.tick) == p.bpm, "\(v.name): bpmAt(\(p.tick))")
            }
            for p in v.bbt {
                let bbt = map.tickToBBT(p.tick)
                #expect([Int(bbt.bar), Int(bbt.beat), Int(bbt.tick)] == p.bbt, "\(v.name): tickToBBT(\(p.tick))")
                let back = map.bbtToTick(daw.BBT(bar: Int64(p.bbt[0]), beat: Int32(p.bbt[1]), tick: Int32(p.bbt[2])))
                #expect(back == p.tick, "\(v.name): bbtToTick(\(p.bbt))")
            }
        }
    }

    @Test("TIME-011: invalid maps from tempo_vectors.json are rejected with the same error")
    func sharedInvalidVectors() throws {
        let errors: [String: daw.TempoMapError] = [
            "noTempoEvents": .noTempoEvents, "noTimeSignatures": .noTimeSignatures,
            "firstEventNotAtTickZero": .firstEventNotAtTickZero, "eventsNotAscending": .eventsNotAscending,
            "tempoOutOfRange": .tempoOutOfRange, "invalidTimeSignature": .invalidTimeSignature,
            "sampleRateOutOfRange": .sampleRateOutOfRange,
        ]
        for v in try TempoVectors.load().invalid {
            let expected = try #require(errors[v.error], "unknown error \(v.error)")
            let (tempos, sigs) = eventLists(v.tempos, v.timeSignatures)
            #expect(daw.TempoMap.validate(tempos, sigs, v.sampleRate) == expected, "\(v.name)")
            #expect(makeMap(v.tempos, v.timeSignatures, v.sampleRate) == nil, "\(v.name)")
        }
    }

    @Test("TIME-001: 10k random positions at random tempos are within 1 sample of exact, and round-trip")
    func randomRoundTrip() throws {
        var rng = SplitMix64(seed: 0x7E3_0001)
        var checked = 0
        for _ in 0..<100 {
            let reference = RandomTempoMap(using: &rng)
            let map = try #require(makeMap(reference.tempos, [(0, 4, 4)], reference.sampleRate))
            for _ in 0..<100 {
                let tick = Int64.random(in: -100_000...25_000_000, using: &rng)
                let sample = map.tickToSample(tick)
                let error = abs(Decimal(sample) - reference.exactSample(tick))
                #expect(error <= 1, "tick \(tick): \(sample) vs exact \(reference.exactSample(tick))")
                // Every map here has > 9 samples per tick, so tick → sample → tick is lossless.
                #expect(map.sampleToTick(sample) == tick, "tick \(tick)")

                // sample → tick → sample lands on the start of the tick sounding at that sample.
                let s = Int64.random(in: -1_000_000...map.tickToSample(25_000_000), using: &rng)
                let t = map.sampleToTick(s)
                #expect(map.tickToSample(t) <= s && s < map.tickToSample(t + 1), "sample \(s)")
                checked += 1
            }
        }
        #expect(checked == 10_000)
    }

    @Test("TIME-002: bars/beats across 4/4 → 7/8 → 3/4")
    func bbtTable() throws {
        // 4/4 for bars 1–2, 7/8 for bars 3–4, then 3/4 from bar 5.
        let map = try #require(makeMap([(0, 120)], [(0, 4, 4), (7680, 7, 8), (14400, 3, 4)], 48000))
        let table: [(tick: Int64, bar: Int64, beat: Int32, sub: Int32)] = [
            (-1, 0, 4, 959), (0, 1, 1, 0), (959, 1, 1, 959), (960, 1, 2, 0), (3840, 2, 1, 0),
            (7679, 2, 4, 959), (7680, 3, 1, 0), (8160, 3, 2, 0), (10560, 3, 7, 0), (11039, 3, 7, 479),
            (11040, 4, 1, 0), (14399, 4, 7, 479), (14400, 5, 1, 0), (15360, 5, 2, 0), (17280, 6, 1, 0),
            (19199, 6, 2, 959),
        ]
        for row in table {
            let bbt = map.tickToBBT(row.tick)
            #expect(bbt.bar == row.bar && bbt.beat == row.beat && bbt.tick == row.sub, "tick \(row.tick)")
            #expect(map.bbtToTick(daw.BBT(bar: row.bar, beat: row.beat, tick: row.sub)) == row.tick)
        }
    }

    @Test("TIME-002: tickToBBT/bbtToTick round-trip with random signature changes")
    func bbtRoundTrip() throws {
        var rng = SplitMix64(seed: 0x7E3_0002)
        for _ in 0..<50 {
            var sigs: [(Int64, Int32, Int32)] = [(0, 4, 4)]
            for _ in 0..<Int.random(in: 0...8, using: &rng) {
                let tick = sigs.last!.0 + Int64.random(in: 1...20_000, using: &rng)
                sigs.append((tick, Int32.random(in: 1...64, using: &rng), [1, 2, 4, 8, 16, 32, 64].randomElement(using: &rng)!))
            }
            let map = try #require(makeMap([(0, 120)], sigs, 48000))
            for _ in 0..<200 {
                let tick = Int64.random(in: -200_000...200_000, using: &rng)
                let bbt = map.tickToBBT(tick)
                #expect(map.bbtToTick(bbt) == tick)
                #expect(bbt.beat >= 1 && bbt.tick >= 0)
            }
        }
    }

    #if DEBUG
    // CONV §5.3: the trap exists only in Debug (BUILD-005).
    @Test("TIME-001/002: conversions make no RT violations under the RT trap")
    func conversionsAreRealtimeSafe() {
        var buffer = [CChar](repeating: 0, count: 1024)
        let failures = buffer.withUnsafeMutableBufferPointer {
            tempoMapConversionsRtSafe($0.baseAddress, $0.count)
        }
        let message = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        #expect(failures == 0, "\(failures) failed check(s); first: \(message)")
    }
    #endif

    @Test("Default map is 120 bpm 4/4 at 48 kHz")
    func defaultMap() {
        let map = daw.TempoMap()
        #expect(map.sampleRate() == 48000)
        #expect(map.bpmAt(123_456) == 120)
        #expect(map.tickToSample(Int64(daw.kPPQ)) == 24000)
        #expect(map.tickToBBT(3840).bar == 2)
    }
}

// MARK: - Helpers

#if DEBUG
// Sources/DAWEngine/time/TempoMapSelfTests.cpp (needs RtScope, so it runs as C++).
@_silgen_name("daw_selftest_tempomap_conversions_rt_safe")
private func tempoMapConversionsRtSafe(_ message: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int32
#endif

private func eventLists(
    _ tempos: [(Int64, Double)], _ sigs: [(Int64, Int32, Int32)]
) -> (daw.TempoEventList, daw.TimeSigEventList) {
    var t = daw.TempoEventList()
    for (tick, bpm) in tempos { t.push_back(daw.TempoEvent(tick: tick, bpm: bpm)) }
    var s = daw.TimeSigEventList()
    for (tick, num, den) in sigs { s.push_back(daw.TimeSigEvent(tick: tick, num: num, den: den)) }
    return (t, s)
}

private func makeMap(
    _ tempos: [(Int64, Double)], _ sigs: [(Int64, Int32, Int32)], _ sampleRate: Double
) -> daw.TempoMap? {
    let (t, s) = eventLists(tempos, sigs)
    return daw.testing.makeTempoMap(t, s, sampleRate).value
}

/// A random tempo map with an exact `Decimal` reference for tick → sample.
private struct RandomTempoMap {
    let sampleRate: Double
    let tempos: [(Int64, Double)]
    private let milliBPM: [Int64]
    private let startSamples: [Decimal]

    init(using rng: inout SplitMix64) {
        sampleRate = [44100, 48000, 88200, 96000, 192_000].randomElement(using: &rng)!
        var ticks: [Int64] = [0]
        for _ in 0..<Int.random(in: 0..<32, using: &rng) {
            ticks.append(ticks.last! + Int64.random(in: 1...1_000_000, using: &rng))
        }
        // Tempos in 1/1000 bpm, so the reference can hold them exactly.
        milliBPM = ticks.map { _ in Int64.random(in: 20_000...300_000, using: &rng) }
        tempos = zip(ticks, milliBPM).map { ($0, Double($1) / 1000) }
        var starts: [Decimal] = [0]
        for i in 1..<ticks.count {
            starts.append(starts[i - 1] + Decimal(ticks[i] - ticks[i - 1]) * Self.samplesPerTick(sampleRate, milliBPM[i - 1]))
        }
        startSamples = starts
    }

    private static func samplesPerTick(_ sampleRate: Double, _ milliBPM: Int64) -> Decimal {
        Decimal(Int64(sampleRate)) * 60 * 1000 / (Decimal(milliBPM) * 960)
    }

    func exactSample(_ tick: Int64) -> Decimal {
        let i = tempos.lastIndex { $0.0 <= tick } ?? 0
        return startSamples[i] + Decimal(tick - tempos[i].0) * Self.samplesPerTick(sampleRate, milliBPM[i])
    }
}

/// Deterministic generator so a failing seed reproduces.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Tests/Fixtures/tempo_vectors.json, located from this file so no resource bundle is needed.
struct TempoVectors: Decodable {
    struct IntPair: Decodable {
        let a: Int64, b: Int64
        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            a = try c.decode(Int64.self)
            b = try c.decode(Int64.self)
        }
    }
    struct BPMAt: Decodable {
        let tick: Int64, bpm: Double
        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            tick = try c.decode(Int64.self)
            bpm = try c.decode(Double.self)
        }
    }
    struct BBTRow: Decodable {
        let tick: Int64, bbt: [Int]
        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            tick = try c.decode(Int64.self)
            bbt = [try c.decode(Int.self), try c.decode(Int.self), try c.decode(Int.self)]
        }
    }
    struct MapEvents: Decodable {
        let name: String
        let sampleRate: Double
        private let tempoRows: [BPMAt]
        private let sigRows: [[Int32]]
        var tempos: [(Int64, Double)] { tempoRows.map { ($0.tick, $0.bpm) } }
        var timeSignatures: [(Int64, Int32, Int32)] { sigRows.map { (Int64($0[0]), $0[1], $0[2]) } }
        enum CodingKeys: String, CodingKey { case name, sampleRate, tempoRows = "tempos", sigRows = "timeSignatures" }
    }
    struct Map: Decodable {
        let events: MapEvents
        let tickToSample: [IntPair], tickToSampleBitExact: [IntPair], sampleToTick: [IntPair]
        let bpmAt: [BPMAt], bbt: [BBTRow]
        var name: String { events.name }
        var sampleRate: Double { events.sampleRate }
        var tempos: [(Int64, Double)] { events.tempos }
        var timeSignatures: [(Int64, Int32, Int32)] { events.timeSignatures }
        enum CodingKeys: CodingKey { case tickToSample, tickToSampleBitExact, sampleToTick, bpmAt, bbt }
        init(from decoder: any Decoder) throws {
            events = try MapEvents(from: decoder)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tickToSample = try c.decode([IntPair].self, forKey: .tickToSample)
            tickToSampleBitExact = try c.decode([IntPair].self, forKey: .tickToSampleBitExact)
            sampleToTick = try c.decode([IntPair].self, forKey: .sampleToTick)
            bpmAt = try c.decode([BPMAt].self, forKey: .bpmAt)
            bbt = try c.decode([BBTRow].self, forKey: .bbt)
        }
    }
    struct Invalid: Decodable {
        let events: MapEvents
        let error: String
        var name: String { events.name }
        var sampleRate: Double { events.sampleRate }
        var tempos: [(Int64, Double)] { events.tempos }
        var timeSignatures: [(Int64, Int32, Int32)] { events.timeSignatures }
        enum CodingKeys: CodingKey { case error }
        init(from decoder: any Decoder) throws {
            events = try MapEvents(from: decoder)
            error = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .error)
        }
    }

    let ppq: Int
    let maps: [Map]
    let invalid: [Invalid]

    static func load() throws -> TempoVectors {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tempo_vectors.json")
        return try JSONDecoder().decode(TempoVectors.self, from: Data(contentsOf: url))
    }
}
