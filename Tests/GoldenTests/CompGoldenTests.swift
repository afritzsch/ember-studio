import DAWControl
import Foundation
import Testing

// T-080 (REC-032): the comp_crossfade reference itself shows DSP-002's equal-power curve at both
// comp boundaries, so a regenerated reference can't hide a hard cut. See the fixture's header.
@Suite("Comp golden (REC-032)")
struct CompGoldenTests {
    static func tone1k(_ n: Int) -> Double { n < 12000 ? 0.5 * sin(2 * Double.pi * Double(n) / 48) : 0 }
    static func tone441(_ n: Int) -> Double { n < 35000 ? 0.5 * sin(2 * Double.pi * 441 * Double(n) / 48000) : 0 }

    /// What the comp plays at sample n: T2 (1 kHz) to 6000, T3 (441 Hz from frame 6000) to 18000,
    /// T1 (441 Hz from frame 0) after; the later take fades in over 64 samples at sin(fπ/2) while
    /// the earlier one passes at cos(fπ/2), f = (d + 1)/64.
    static func expected(_ n: Int) -> Double {
        func fade(_ d: Int) -> (Double, Double) {
            let f = Double(d + 1) / 64
            return (sin(f * .pi / 2), cos(f * .pi / 2))
        }
        switch n {
        case ..<6000: return tone1k(n)
        case 6000..<6064:
            let (w, u) = fade(n - 6000)
            return w * tone441(n + 6000) + u * tone1k(n)
        case 6064..<18000: return tone441(n + 6000)
        case 18000..<18064:
            let (w, u) = fade(n - 18000)
            return w * tone441(n) + u * tone441(n + 6000)
        default: return tone441(n)
        }
    }

    @Test("REC-032: comp_crossfade crossfades both comp boundaries over 64 samples with the equal-power curve, sample by sample")
    func boundariesAreEqualPower() throws {
        let audio = try AudioData(contentsOf: GoldenHarness.reference("comp_crossfade"))
        #expect(audio.sampleRate == 48000 && audio.frameCount == 24000)
        // The centre pan law's gain, from a sample of T2 alone.
        let gain = Double(audio.channels[0][100]) / Self.tone1k(100)
        #expect(abs(gain - 0.5) < 1e-3)
        for channel in audio.channels {
            var worst = 0.0
            for (n, x) in channel.enumerated() { worst = max(worst, abs(Double(x) - gain * Self.expected(n))) }
            #expect(worst < 1e-5)
        }
    }
}
