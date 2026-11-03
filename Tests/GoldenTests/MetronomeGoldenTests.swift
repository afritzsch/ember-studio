import DAWControl
import Foundation
import Testing

// T-024: metronome_click's reference checked against the spec numbers on every sample, so a
// regenerated reference can't hide a click that moved, lost its accent or changed shape.

@Suite("Metronome golden reference (TIME-010, DSP-011)")
struct MetronomeGoldenTests {
    /// Beats of the fixture's tempo map (3/4 at 120 bpm, 150 bpm from tick 4320, 4/4 from tick
    /// 5760) as (sample, downbeat), derived in its header comment.
    static let clicks: [(sample: Int, downbeat: Bool)] = [
        (0, true), (24000, false), (48000, false), (72000, true), (96000, false), (117600, false),
        (136800, true), (156000, false), (175200, false), (194400, false), (213600, true),
    ]

    /// The click shape of Metronome.h: amp · (1 − k/N)³ · cos(2π f k / rate), N = 960 at 48 kHz.
    static func click(_ k: Int, downbeat: Bool) -> Double {
        let env = 1 - Double(k) / 960
        let hz = downbeat ? 1500.0 : 1000.0
        return (downbeat ? 0.5 : 0.25) * env * env * env * cos(2 * Double.pi * hz * Double(k) / 48000)
    }

    @Test("TIME-010, DSP-011: metronome_click clicks on every beat's exact sample, accented on bar starts")
    func clicksOnEverySample() throws {
        let audio = try AudioData(contentsOf: GoldenHarness.reference("metronome_click"))
        #expect(audio.sampleRate == 48000)
        #expect(audio.channels.count == 2)
        #expect(audio.frameCount == 232800)
        guard audio.channels.count == 2, audio.frameCount == 232800 else { return }

        var expected = [Double](repeating: 0, count: 232800)
        for c in Self.clicks {
            for k in 0..<960 { expected[c.sample + k] += Self.click(k, downbeat: c.downbeat) }
        }
        for (index, channel) in audio.channels.enumerated() {
            var worst = 0.0
            for (i, x) in channel.enumerated() { worst = max(worst, abs(Double(x) - expected[i])) }
            #expect(worst < 1e-6, "channel \(index)")
            // Sample-exact onsets: silence on the frame before, full amplitude on the beat's frame.
            for c in Self.clicks {
                #expect(abs(Double(channel[c.sample]) - (c.downbeat ? 0.5 : 0.25)) < 1e-6)
                #expect(c.sample == 0 || channel[c.sample - 1] == 0)
            }
        }
    }
}
