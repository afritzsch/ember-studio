import DAWControl
import Foundation
import Testing

// T-077: the rest of the M7 golden set (14 "Minimum golden set"). Each reference is checked
// against numbers written from 06's signal paths, so a regenerated reference can't hide a wrong
// filter, guard or ramp:
// - eq_response: the EQ's impulse response vs the analytic RBJ magnitude (DSP-030).
// - effects_silence_nan_guard: every effect's tail ends in exact 0; NaN in → silence out, counted
//   in telemetry (DSP-040, DW-142).
// - builtin_bypass_null: bypassed built-ins pass their input through untouched (PLUG-018).
// - effect_param_steps: a param step ramps across exactly one block on every effect (ENG-022,
//   AUTO-002).
// - m7_scene: all of them in one mix, bit-identical on two fresh engines (IO-011).

@Suite("Golden references, M7 (DSP-030..033, DSP-040, AUTO-002, T-077)")
struct M7GoldenTests {
    static let rate = 48000.0
    /// The master's centre pan, × √½ in float (MIX-005); hard pans give × 1 on their side.
    static let master = Double(Float(0.5.squareRoot()))
    /// A centre-panned track into the centre-panned master, as the engine multiplies it in float.
    static let centre = Double(Float(0.5.squareRoot()) * Float(0.5.squareRoot()))
    /// Shelf, HP and LP Q in the fixtures: √½ as the param slot (float) holds it.
    static let q = Double(Float(0.5.squareRoot()))

    static func reference(_ name: String, frames: Int) throws -> [[Float]] {
        let audio = try AudioData(contentsOf: GoldenHarness.reference(name))
        #expect(audio.sampleRate == rate)
        #expect(audio.channels.count == 2)
        #expect(audio.frameCount == frames)
        return audio.channels
    }

    // MARK: RBJ (independent of dsp/Biquad.h: the cookbook formulas, evaluated on the unit circle)

    struct Biquad {
        var b0, b1, b2, a1, a2: Double  // normalized by a0

        init(b: (Double, Double, Double), a: (Double, Double, Double)) {
            (b0, b1, b2, a1, a2) = (b.0 / a.0, b.1 / a.0, b.2 / a.0, a.1 / a.0, a.2 / a.0)
        }

        enum Kind { case highPass, lowPass, peak, lowShelf, highShelf }

        init(_ kind: Kind, freq: Double, q: Double, gainDb: Double = 0, rate: Double = M7GoldenTests.rate) {
            let w = 2 * Double.pi * freq / rate, c = cos(w), alpha = sin(w) / (2 * q)
            let A = pow(10, gainDb / 40), s = 2 * A.squareRoot() * alpha
            switch kind {
            case .highPass: self.init(b: ((1 + c) / 2, -(1 + c), (1 + c) / 2), a: (1 + alpha, -2 * c, 1 - alpha))
            case .lowPass: self.init(b: ((1 - c) / 2, 1 - c, (1 - c) / 2), a: (1 + alpha, -2 * c, 1 - alpha))
            case .peak: self.init(b: (1 + alpha * A, -2 * c, 1 - alpha * A), a: (1 + alpha / A, -2 * c, 1 - alpha / A))
            case .lowShelf:
                self.init(b: (A * ((A + 1) - (A - 1) * c + s), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - s)),
                          a: ((A + 1) + (A - 1) * c + s, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - s))
            case .highShelf:
                self.init(b: (A * ((A + 1) + (A - 1) * c + s), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - s)),
                          a: ((A + 1) - (A - 1) * c + s, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - s))
            }
        }

        /// |H(e^jω)|² at `freq`.
        func power(at freq: Double, rate: Double = M7GoldenTests.rate) -> Double {
            let w = 2 * Double.pi * freq / rate
            func mag2(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
                let re = c0 + c1 * cos(w) + c2 * cos(2 * w), im = -(c1 * sin(w) + c2 * sin(2 * w))
                return re * re + im * im
            }
            return mag2(b0, b1, b2) / mag2(1, a1, a2)
        }

        func lerp(_ to: Biquad, _ t: Double) -> Biquad {
            var c = self
            c.b0 += (to.b0 - b0) * t
            c.b1 += (to.b1 - b1) * t
            c.b2 += (to.b2 - b2) * t
            c.a1 += (to.a1 - a1) * t
            c.a2 += (to.a2 - a2) * t
            return c
        }
    }

    static func responseDb(_ bands: [Biquad], at freq: Double) -> Double {
        10 * log10(bands.reduce(1) { $0 * $1.power(at: freq) })
    }

    /// The DTFT of `x` at `freq`, in dB.
    static func dtftDb(_ x: [Float], at freq: Double) -> Double {
        let w = -2 * Double.pi * freq / rate
        var re = 0.0, im = 0.0
        for (n, v) in x.enumerated() where v != 0 {
            re += Double(v) * cos(w * Double(n))
            im += Double(v) * sin(w * Double(n))
        }
        return 10 * log10(re * re + im * im)
    }

    // MARK: eq_response

    static let slopes = [Biquad(.highPass, freq: 100, q: q), Biquad(.lowPass, freq: 4000, q: q)]
    static let bells = [Biquad(.lowShelf, freq: 150, q: q, gainDb: -6), Biquad(.peak, freq: 1000, q: 2, gainDb: 9),
                        Biquad(.peak, freq: 5000, q: 3, gainDb: -9), Biquad(.highShelf, freq: 12000, q: q, gainDb: 4)]

    @Test("DSP-030: eq_response matches the analytic RBJ magnitude within 0.01 dB; bell boost/cut, shelves, HP/LP slopes")
    func eqResponse() throws {
        let channels = try Self.reference("eq_response", frames: 24000)
        guard channels.count == 2, channels[0].count == 24000 else { return }
        let gainDb = 20 * log10(Self.master)
        let freqs: [Double] = [12.5, 25, 50, 100, 200, 400, 1000, 2000, 4000, 5000, 8000, 16000, 20000, 23000]
        func measured(_ c: Int, _ f: Double) -> Double { Self.dtftDb(channels[c], at: f) - gainDb }
        for f in freqs {
            for (c, bands) in [(0, Self.slopes), (1, Self.bells)] {
                let want = Self.responseDb(bands, at: f), got = measured(c, f)
                #expect(abs(got - want) < 0.01, "channel \(c) at \(f) Hz: \(got) dB, analytic \(want) dB")
            }
        }
        // Stated in 06 terms: −3 dB at the HP and LP corners, 12 dB/oct far below the HP corner.
        #expect(abs(measured(0, 100) + 3.0103) < 0.01)
        #expect(abs(measured(0, 4000) + 3.0103) < 0.01)
        #expect(abs(measured(0, 25) - measured(0, 12.5) - 12) < 0.1)
        // Bilinear warping makes the LP steeper than 12 dB/oct near Nyquist, never shallower.
        #expect(measured(0, 8000) - measured(0, 16000) > 12)
        // The bells: boost at 1 kHz and cut at 5 kHz within a few tenths of their gains (the
        // shelves add a little), the low shelf's −6 dB at the bottom, the high shelf's +4 dB at the top.
        #expect(abs(measured(1, 1000) - 9) < 0.1)
        #expect(abs(measured(1, 5000) + 9) < 0.5)
        #expect(abs(measured(1, 12.5) + 6) < 0.01)
        #expect(abs(measured(1, 23000) - 4) < 0.01)
        // DSP-040: the response ends in exact 0, no denormal tail.
        for channel in channels { #expect(channel[12000...].allSatisfy { $0 == 0 }) }
    }

    // MARK: effects_silence_nan_guard

    @Test("DSP-040, DW-142: each effect's tail ends in exact 0; NaN-fed effects output silence and count every block")
    @MainActor func silenceAndNaNGuard() async throws {
        let name = "effects_silence_nan_guard"
        let fixture = try GoldenFixture(name: name, contentsOf: GoldenHarness.fixturesDirectory.appending(path: "\(name).jsonl"))
        let run = await GoldenHarness.run(fixture, reference: GoldenHarness.reference(name))
        defer { try? FileManager.default.removeItem(at: run.workDirectory) }
        #expect(run.failures == [])
        #expect(run.comparison?.pass == true)
        // Four NaN-fed effects, each guarding every block of the render: 4 × 188 512-frame blocks
        // (the engine's few blocks outside the render don't play the clip players' sources).
        let renderBlocks: Int64 = (96000 + 511) / 512
        let nanBlocks = run.telemetry?["nanBlocks"]?.int64Value ?? -1
        let blocks = run.telemetry?["blocksRendered"]?.int64Value ?? -1
        #expect(blocks >= renderBlocks)
        #expect(nanBlocks == 4 * renderBlocks, "nanBlocks \(nanBlocks), blocksRendered \(blocks)")

        let channels = try Self.reference(name, frames: 96000)
        guard channels.count == 2, channels[0].count == 96000 else { return }
        // Clicks at 0, 24000, 48000, 72000. Each effect is heard, then is exactly 0 well before the
        // next click (the frame its tail ended, measured, with a margin in the fixture's @expects).
        let slots: [(name: String, start: Int, quietBy: Int)] =
            [("EQ", 0, 12000), ("Comp", 24000, 24001), ("Delay", 48000, 61000), ("Reverb", 72000, 91000)]
        for (index, slot) in slots.enumerated() {
            let end = index + 1 < slots.count ? slots[index + 1].start : 96000
            for channel in channels {
                #expect(channel[slot.start] != 0, "\(slot.name): the click is heard")
                #expect(channel[slot.start..<end].allSatisfy { $0.isFinite }, "\(slot.name): finite")
                #expect(channel[slot.quietBy..<end].allSatisfy { $0 == 0 }, "\(slot.name): exact 0 after the tail")
            }
        }
        // The effects' own tails, not just the click: echoes 480 frames apart, a reverb tail.
        #expect(channels[0][48480] != 0 && channels[0][48960] != 0)
        #expect(channels[0][72000 + 2000..<72000 + 4000].contains { $0 != 0 })
    }

    // MARK: builtin_bypass_null

    @Test("PLUG-018, DSP-030..033: bypassed built-in EQ, compressor, delay and reverb null against the dry signal; running, they don't")
    func builtinBypassNull() throws {
        let channels = try Self.reference("builtin_bypass_null", frames: 24000)
        guard channels.count == 2, channels[0].count == 24000 else { return }
        #expect(channels[0].allSatisfy { $0 == 0 })
        let kick = try M3GoldenReferenceTests.asset("kick_48k.wav")
        var deviation = 0.0
        for (n, y) in channels[1].enumerated() {
            let dry = n < kick.count ? Double(kick[n]) * Self.master : 0
            deviation = max(deviation, abs(Double(y) - dry))
        }
        #expect(deviation > 0.05)  // the running chain changes the kick audibly
        #expect(channels[1][12000..<24000].contains { $0 != 0 })  // echoes and reverb after the kick
    }

    // MARK: effect_param_steps

    static let blockSize = 512
    /// Slot k's tone starts at 36000·k; its lane steps 720 ticks (18000 frames) later, inside these
    /// blocks (the first whose start tick is at or past the step).
    static let stepBlocks = [36, 106, 176, 247]
    static let toneStarts = [0, 36000, 72000, 108000]

    /// ENG-022 for one step: `a` before `block`, `a + (b − a)·(i + 1)/512` on its frame i (exactly
    /// `b` on the last), then `b`.
    static func ramp(_ n: Int, block: Int, from a: Double, to b: Double) -> Double {
        let start = block * blockSize
        if n < start { return a }
        let i = n - start
        if i >= blockSize - 1 { return b }
        return Double(Float(a) + Float(b - a) / Float(blockSize) * Float(i + 1))
    }

    static func input(_ tone: [Float], at start: Int, frames: Int) -> [Double] {
        var x = [Double](repeating: 0, count: frames)
        for (i, v) in tone.enumerated() where start + i < frames { x[start + i] = Double(v) }
        return x
    }

    @Test("ENG-022, AUTO-002: a param step on the EQ, compressor, delay and reverb ramps linearly over one block, sample by sample")
    func paramSteps() throws {
        let frames = 144000
        let channels = try Self.reference("effect_param_steps", frames: frames)
        guard channels.count == 2, channels[0].count == frames else { return }
        let tone = try M3GoldenReferenceTests.asset("tone_441_48k.wav")
        #expect(tone.count == 35000)

        // EQ: peak 1 at 441 Hz Q 1, 0 → +12 dB; the step block lerps the coefficients (06).
        var eq = [Double](repeating: 0, count: frames)
        do {
            let x = Self.input(tone, at: Self.toneStarts[0], frames: frames)
            let flat = Biquad(.peak, freq: 441, q: 1, gainDb: 0), boost = Biquad(.peak, freq: 441, q: 1, gainDb: 12)
            let start = Self.stepBlocks[0] * Self.blockSize
            var z1 = 0.0, z2 = 0.0
            for n in 0..<frames {
                let c = n < start ? flat : n >= start + Self.blockSize - 1 ? boost
                    : flat.lerp(boost, Double(n - start + 1) / Double(Self.blockSize))
                let y = c.b0 * x[n] + z1
                z1 = c.b1 * x[n] - c.a1 * y + z2
                z2 = c.b2 * x[n] - c.a2 * y
                eq[n] = Double(Float(y))
            }
        }
        // Compressor at ratio 1 (no reduction): in × 10^(makeup/20), makeup 0 → 12 dB.
        let compIn = Self.input(tone, at: Self.toneStarts[1], frames: frames)
        let comp = compIn.indices.map { compIn[$0] * pow(10, Self.ramp($0, block: Self.stepBlocks[1], from: 0, to: 12) / 20) }
        // Delay, 20 ms (960 frames), no feedback, no lowpass: (1 − mix)·in + mix·in[n − 960].
        let delayIn = Self.input(tone, at: Self.toneStarts[2], frames: frames)
        let delay = delayIn.indices.map { n -> Double in
            let m = Self.ramp(n, block: Self.stepBlocks[2], from: 0, to: 1)
            return (1 - m) * delayIn[n] + m * (n >= 960 ? delayIn[n - 960] : 0)
        }
        // Reverb: the FDN's wet signal (ReverbGoldenTests.wet), mix 0 → 1.
        let verbIn = Self.input(tone, at: Self.toneStarts[3], frames: frames)
        let (wetL, wetR) = ReverbGoldenTests.wet(verbIn, size: 0.3, decay: 0.5, damping: 0.5, predelayMs: 0)

        for (c, channel) in channels.enumerated() {
            let wet = c == 0 ? wetL : wetR
            var worst = [Double](repeating: 0, count: 4)
            for n in 0..<frames {
                let m = Self.ramp(n, block: Self.stepBlocks[3], from: 0, to: 1)
                let verb = (1 - m) * verbIn[n] + m * wet[n]
                let parts = [eq[n], comp[n], delay[n], verb]
                let want = Self.centre * parts.reduce(0, +)
                let err = abs(Double(channel[n]) - want)
                // Attribute the error to the slot the frame belongs to.
                let slot = min(n / 36000, 3)
                worst[slot] = max(worst[slot], err)
            }
            for (slot, name) in ["EQ", "Comp", "Delay", "Reverb"].enumerated() {
                #expect(worst[slot] < 1e-5, "channel \(c), \(name): worst error \(worst[slot])")
            }
        }

        // No jump at the step: inside each step block the output moves no further per frame than
        // it does at the new setting over the four blocks after it (plus the ramp's own slope).
        func maxStep(_ x: [Float], _ range: Range<Int>) -> Double {
            range.reduce(0) { max($0, abs(Double(x[$1]) - Double(x[$1 - 1]))) }
        }
        for block in Self.stepBlocks {
            let start = block * Self.blockSize, end = start + Self.blockSize
            for channel in channels {
                let during = maxStep(channel, start..<end), after = maxStep(channel, end..<(end + 4 * Self.blockSize))
                #expect(during <= after * 1.05 + 0.002, "block \(block): \(during) per frame during the step, \(after) after")
            }
        }
    }

    // MARK: m7_scene

    @Test("IO-011, DSP-030..033, AUTO-002: m7_scene renders the same bits on two fresh engines and nulls against its reference")
    @MainActor func sceneDeterministic() async throws {
        let name = "m7_scene"
        let fixture = try GoldenFixture(name: name, contentsOf: GoldenHarness.fixturesDirectory.appending(path: "\(name).jsonl"))
        var renders: [AudioData] = []
        for _ in 0..<2 {
            let run = await GoldenHarness.run(fixture, reference: GoldenHarness.reference(name))
            defer { try? FileManager.default.removeItem(at: run.workDirectory) }
            #expect(run.failures == [])
            #expect(run.comparison?.pass == true)
            #expect(run.renders.allSatisfy { $0.rtViolations == 0 && $0.clippedSamples == 0 })
            #expect(run.telemetry?["nanBlocks"]?.int64Value == 0)
            guard let golden = run.golden else { continue }
            renders.append(try AudioData(contentsOf: golden))
        }
        #expect(renders.count == 2)
        guard renders.count == 2 else { return }
        #expect(renders[0].frameCount == 96000 && renders[0].channels.count == 2)
        for (a, b) in zip(renders[0].channels, renders[1].channels) {
            #expect(a.map(\.bitPattern) == b.map(\.bitPattern))
            #expect(a.allSatisfy { $0.isFinite })
            // The reverb bus still rings after the last kick and tone have passed.
            #expect(a[94000..<96000].contains { $0 != 0 })
        }
    }
}
