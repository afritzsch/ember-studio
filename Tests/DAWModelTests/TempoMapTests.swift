import DAWModel
import Foundation
import Testing

// Swift DAWModel.TempoMap. The C++ engine map has the same tests in
// Tests/DAWEngineTests/TempoMapTests.swift; both read Tests/Fixtures/tempo_vectors.json.

@Suite("TempoMap (Swift)")
struct ModelTempoMapTests {
    @Test("TIME-011: DAWModel.TempoMap matches tempo_vectors.json")
    func sharedVectors() throws {
        let vectors = try TempoVectors.load()
        #expect(vectors.ppq == Int(Tick.ppq))
        for v in vectors.maps {
            let map = try TempoMap(tempoEvents: v.tempos, timeSignatures: v.timeSignatures, sampleRate: v.sampleRate)
            for p in v.tickToSample {
                #expect(map.tickToSample(Tick(p.a)) == p.b, "\(v.name): tickToSample(\(p.a))")
            }
            // The double arithmetic itself: these flip if a + b*c gets fused into an FMA.
            for p in v.tickToSampleBitExact {
                #expect(map.tickToSample(Tick(p.a)) == p.b, "\(v.name): bit-exact tickToSample(\(p.a))")
            }
            for p in v.sampleToTick {
                #expect(map.sampleToTick(p.a) == Tick(p.b), "\(v.name): sampleToTick(\(p.a))")
            }
            for p in v.bpmAt {
                #expect(map.bpmAt(Tick(p.tick)) == p.bpm, "\(v.name): bpmAt(\(p.tick))")
            }
            for p in v.bbt {
                let bbt = BBT(bar: p.bbt[0], beat: p.bbt[1], tick: p.bbt[2])
                #expect(map.tickToBBT(Tick(p.tick)) == bbt, "\(v.name): tickToBBT(\(p.tick))")
                #expect(map.bbtToTick(bbt) == Tick(p.tick), "\(v.name): bbtToTick(\(p.bbt))")
            }
        }
    }

    @Test("TIME-011: invalid maps from tempo_vectors.json are rejected with the same error")
    func sharedInvalidVectors() throws {
        let errors: [String: TempoMapError] = [
            "noTempoEvents": .noTempoEvents, "noTimeSignatures": .noTimeSignatures,
            "firstEventNotAtTickZero": .firstEventNotAtTickZero, "eventsNotAscending": .eventsNotAscending,
            "tempoOutOfRange": .tempoOutOfRange, "invalidTimeSignature": .invalidTimeSignature,
            "sampleRateOutOfRange": .sampleRateOutOfRange,
        ]
        for v in try TempoVectors.load().invalid {
            let expected = try #require(errors[v.error], "unknown error \(v.error)")
            #expect(throws: expected, "\(v.name)") {
                try TempoMap(tempoEvents: v.tempos, timeSignatures: v.timeSignatures, sampleRate: v.sampleRate)
            }
        }
    }

    @Test("TIME-001: 10k random positions at random tempos are within 1 sample of exact, and round-trip")
    func randomRoundTrip() throws {
        var rng = SplitMix64(seed: 0x7E3_0001)
        var checked = 0
        for _ in 0..<100 {
            let reference = RandomTempoMap(using: &rng)
            let map = try TempoMap(
                tempoEvents: reference.tempos,
                timeSignatures: [TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)],
                sampleRate: reference.sampleRate)
            for _ in 0..<100 {
                let tick = Tick(Int64.random(in: -100_000...25_000_000, using: &rng))
                let sample = map.tickToSample(tick)
                let error = abs(Decimal(sample) - reference.exactSample(tick.raw))
                #expect(error <= 1, "tick \(tick.raw): \(sample) vs exact \(reference.exactSample(tick.raw))")
                // Every map here has > 9 samples per tick, so tick → sample → tick is lossless.
                #expect(map.sampleToTick(sample) == tick, "tick \(tick.raw)")

                // sample → tick → sample lands on the start of the tick sounding at that sample.
                let s = Int64.random(in: -1_000_000...map.tickToSample(25_000_000), using: &rng)
                let t = map.sampleToTick(s)
                #expect(map.tickToSample(t) <= s && s < map.tickToSample(Tick(t.raw + 1)), "sample \(s)")
                checked += 1
            }
        }
        #expect(checked == 10_000)
    }

    @Test("TIME-002: bars/beats across 4/4 → 7/8 → 3/4")
    func bbtTable() throws {
        // 4/4 for bars 1–2, 7/8 for bars 3–4, then 3/4 from bar 5.
        let map = try TempoMap(
            tempoEvents: [TempoEvent(tick: 0, bpm: 120)],
            timeSignatures: [
                TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4),
                TimeSignatureEvent(tick: 7680, numerator: 7, denominator: 8),
                TimeSignatureEvent(tick: 14400, numerator: 3, denominator: 4),
            ],
            sampleRate: 48000)
        let table: [(tick: Tick, bbt: BBT)] = [
            (-1, BBT(bar: 0, beat: 4, tick: 959)), (0, BBT(bar: 1, beat: 1, tick: 0)),
            (959, BBT(bar: 1, beat: 1, tick: 959)), (960, BBT(bar: 1, beat: 2, tick: 0)),
            (3840, BBT(bar: 2, beat: 1, tick: 0)), (7679, BBT(bar: 2, beat: 4, tick: 959)),
            (7680, BBT(bar: 3, beat: 1, tick: 0)), (8160, BBT(bar: 3, beat: 2, tick: 0)),
            (10560, BBT(bar: 3, beat: 7, tick: 0)), (11039, BBT(bar: 3, beat: 7, tick: 479)),
            (11040, BBT(bar: 4, beat: 1, tick: 0)), (14399, BBT(bar: 4, beat: 7, tick: 479)),
            (14400, BBT(bar: 5, beat: 1, tick: 0)), (15360, BBT(bar: 5, beat: 2, tick: 0)),
            (17280, BBT(bar: 6, beat: 1, tick: 0)), (19199, BBT(bar: 6, beat: 2, tick: 959)),
        ]
        for row in table {
            #expect(map.tickToBBT(row.tick) == row.bbt, "tick \(row.tick.raw)")
            #expect(map.bbtToTick(row.bbt) == row.tick)
        }
    }

    @Test("TIME-002: tickToBBT/bbtToTick round-trip with random signature changes")
    func bbtRoundTrip() throws {
        var rng = SplitMix64(seed: 0x7E3_0002)
        for _ in 0..<50 {
            var sigs = [TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)]
            for _ in 0..<Int.random(in: 0...8, using: &rng) {
                sigs.append(TimeSignatureEvent(
                    tick: Tick(sigs.last!.tick.raw + Int64.random(in: 1...20_000, using: &rng)),
                    numerator: Int(Int32.random(in: 1...64, using: &rng)),
                    denominator: [1, 2, 4, 8, 16, 32, 64].randomElement(using: &rng)!))
            }
            let map = try TempoMap(tempoEvents: [TempoEvent(tick: 0, bpm: 120)], timeSignatures: sigs, sampleRate: 48000)
            for _ in 0..<200 {
                let tick = Tick(Int64.random(in: -200_000...200_000, using: &rng))
                let bbt = map.tickToBBT(tick)
                #expect(map.bbtToTick(bbt) == tick)
                #expect(bbt.beat >= 1 && bbt.tick >= 0)
            }
        }
    }

    @Test("Default map is 120 bpm 4/4 at 48 kHz")
    func defaultMap() {
        let map = TempoMap()
        #expect(map.sampleRate == 48000)
        #expect(map.bpmAt(123_456) == 120)
        #expect(map.tickToSample(Tick(Tick.ppq)) == 24000)
        #expect(map.tickToBBT(3840).bar == 2)
    }

    @Test("TempoMap encodes only its events and rate, and decoding revalidates")
    func codable() throws {
        let map = try TempoMap(
            tempoEvents: [TempoEvent(tick: 0, bpm: 120), TempoEvent(tick: 1920, bpm: 133.5)],
            timeSignatures: [TimeSignatureEvent(tick: 0, numerator: 6, denominator: 8)],
            sampleRate: 44100)
        let data = try JSONEncoder().encode(map)
        let decoded = try JSONDecoder().decode(TempoMap.self, from: data)
        #expect(decoded == map)
        #expect(decoded.tickToSample(5000) == map.tickToSample(5000))

        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["tempoEvents", "timeSignatures", "sampleRate"])
        // Tick is a bare integer, not {"raw": …}.
        let secondTempo = try #require((json["tempoEvents"] as? [[String: Any]])?.last)
        #expect(secondTempo["tick"] as? Int == 1920)

        let invalid = Data(#"{"tempoEvents":[{"tick":5,"bpm":120}],"timeSignatures":[{"tick":0,"numerator":4,"denominator":4}],"sampleRate":48000}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TempoMap.self, from: invalid) }
    }
}

// MARK: - Helpers (duplicated from DAWEngineTests: test targets can't share sources)

/// A random tempo map with an exact `Decimal` reference for tick → sample.
private struct RandomTempoMap {
    let sampleRate: Double
    let tempos: [TempoEvent]
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
        tempos = zip(ticks, milliBPM).map { TempoEvent(tick: Tick($0), bpm: Double($1) / 1000) }
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
        let i = tempos.lastIndex { $0.tick.raw <= tick } ?? 0
        return startSamples[i] + Decimal(tick - tempos[i].tick.raw) * Self.samplesPerTick(sampleRate, milliBPM[i])
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
        private let sigRows: [[Int]]
        var tempos: [TempoEvent] { tempoRows.map { TempoEvent(tick: Tick($0.tick), bpm: $0.bpm) } }
        var timeSignatures: [TimeSignatureEvent] {
            sigRows.map { TimeSignatureEvent(tick: Tick(Int64($0[0])), numerator: $0[1], denominator: $0[2]) }
        }
        enum CodingKeys: String, CodingKey { case name, sampleRate, tempoRows = "tempos", sigRows = "timeSignatures" }
    }
    struct Map: Decodable {
        let events: MapEvents
        let tickToSample: [IntPair], tickToSampleBitExact: [IntPair], sampleToTick: [IntPair]
        let bpmAt: [BPMAt], bbt: [BBTRow]
        var name: String { events.name }
        var sampleRate: Double { events.sampleRate }
        var tempos: [TempoEvent] { events.tempos }
        var timeSignatures: [TimeSignatureEvent] { events.timeSignatures }
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
        var tempos: [TempoEvent] { events.tempos }
        var timeSignatures: [TimeSignatureEvent] { events.timeSignatures }
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
