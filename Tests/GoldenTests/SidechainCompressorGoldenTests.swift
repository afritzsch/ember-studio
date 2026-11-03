import DAWControl
import Foundation
import Testing

// T-071: the sidechain_compressor golden (DSP-031, MIX-008) checked sample by sample, so a
// regenerated reference can't hide a wrong gain curve, ballistics or key timing. The expected
// gain comes from an oracle written from 06's compressor signal path (nodes/Compressor.h), keyed
// by the fixture's kick asset placed at its clip frames; the tone comes from its asset file.

@Suite("Golden references, M7 (DSP-031, MIX-008)")
struct SidechainCompressorGoldenTests {
    static let rate = 48000.0
    /// The fixture's compressor: threshold −30 dB, ratio 4, attack 5 ms, release 80 ms, knee 6 dB,
    /// makeup 0, peak detector.
    static let threshold = -30.0, ratio = 4.0, attackMs = 5.0, releaseMs = 80.0, knee = 6.0
    /// Kick clips at ticks 240, 720, 1200: 25 frames per tick at 120 bpm.
    static let kickStarts = [6000, 18000, 30000]
    static let frames = 36000

    static func staticGainDb(_ x: Double) -> Double {
        if x <= threshold - knee / 2 { return 0 }
        if x >= threshold + knee / 2 { return (threshold + (x - threshold) / ratio) - x }
        let d = x - threshold + knee / 2
        return (1 / ratio - 1) * d * d / (2 * knee)
    }

    /// e[n] in dB for every output frame, keyed by the kick track's (pre-fader) clip output.
    static func gainReductionDb(kick: [Float]) -> [Double] {
        var key = [Float](repeating: 0, count: frames)
        for start in kickStarts {
            for (i, x) in kick.enumerated() where start + i < frames { key[start + i] = x }
        }
        let attack = exp(-1 / (attackMs / 1000 * rate)), release = exp(-1 / (releaseMs / 1000 * rate))
        var env = 0.0
        return key.map { k in
            let level = abs(Double(k))
            let x = level > 0 ? max(20 * log10(level), -200) : -200
            let c = staticGainDb(x)
            let a = c < env ? attack : release
            env = a * env + (1 - a) * c
            return env
        }
    }

    @Test("DSP-031, MIX-008: sidechain_compressor is the tone × 0.5 ducked by the kick-keyed gain, sample by sample")
    func duckedToneSamples() throws {
        let audio = try AudioData(contentsOf: GoldenHarness.reference("sidechain_compressor"))
        #expect(audio.sampleRate == 48000)
        #expect(audio.channels.count == 2)
        #expect(audio.frameCount == Self.frames)
        guard audio.channels.count == 2, audio.frameCount == Self.frames else { return }
        let tone = try M3GoldenReferenceTests.asset("tone_441_48k.wav")
        let kick = try M3GoldenReferenceTests.asset("kick_48k.wav")
        #expect(tone.count == 35000 && kick.count == 9600)
        let gr = Self.gainReductionDb(kick: kick)

        // Every sample: 0.5 (centre pans on Pad and the master) × tone × 10^(e/20).
        for channel in audio.channels {
            var worst = 0.0
            for n in 0..<Self.frames {
                let source = n < tone.count ? Double(tone[n]) : 0
                let expected = 0.5 * source * pow(10, gr[n] / 20)
                worst = max(worst, abs(Double(channel[n]) - expected))
            }
            #expect(worst < 1e-6)
        }

        // Timing, stated in the render itself: nothing is reduced before the first kick; the gain
        // drops on the first frame the key's level enters the knee (0 latency, no lookahead), and
        // where the tone is loud enough to measure, the render's gain is the oracle's to 0.01 dB.
        let firstReduced = gr.firstIndex { $0 < 0 } ?? Self.frames
        #expect((6000..<6100).contains(firstReduced))
        let l = audio.channels[0]
        for n in 0..<firstReduced { #expect(l[n] == audio.channels[1][n]) }
        #expect((0..<firstReduced).allSatisfy { abs(Double(l[$0]) - 0.5 * Double(tone[$0])) < 1e-7 })
        var worstDb = 0.0
        for n in 0..<tone.count where abs(tone[n]) > 0.1 {
            worstDb = max(worstDb, abs(20 * log10(Double(l[n]) / (0.5 * Double(tone[n]))) - gr[n]))
        }
        #expect(worstDb < 0.01)
        // The kick ducks the tone by more than 15 dB. After a kick ends (frame 15600, the key is
        // 0 from 15599 on) the gain only releases: 2400 frames at 80 ms is × e^(−0.625) in dB.
        #expect((gr.min() ?? 0) < -15)
        #expect(abs(gr[17999] - gr[15599] * exp(-2400 / (Self.releaseMs / 1000 * Self.rate))) < 1e-9)
    }
}
