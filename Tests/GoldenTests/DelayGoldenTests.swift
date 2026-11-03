import DAWControl
import Foundation
import Testing

// T-072: the delay_tempo_sync golden (DSP-032). The reference is checked sample by sample against
// the echo pattern 06 gives for an impulse through a tempo-synced delay, so a regenerated
// reference can't hide a wrong delay time, feedback or mix.

@Suite("Golden references, M7 (DSP-032)")
struct DelayGoldenTests {
    static let name = "delay_tempo_sync"
    static let frames = 60000
    /// 1/8 note at 120 bpm and 48 kHz: 250 ms.
    static let echoFrames = 12000

    @Test("DSP-032: delay_tempo_sync has the dry click, then echoes every 1/8 note (12000 frames) halving with feedback 0.5, and nothing else")
    func echoesOnTheBeat() throws {
        let audio = try AudioData(contentsOf: GoldenHarness.reference(Self.name))
        #expect(audio.sampleRate == 48000)
        #expect(audio.channels.count == 2)
        #expect(audio.frameCount == Self.frames)
        guard audio.channels.count == 2, audio.frameCount == Self.frames else { return }
        // Centre pans on the track and the master: √½ · √½ = 0.5 (in float, to within 1e-7).
        var want = [Double](repeating: 0, count: Self.frames)
        want[0] = 0.5 * 0.5  // dry × (1 − mix)
        for k in 1...4 { want[k * Self.echoFrames] = 0.5 * 0.5 * pow(0.5, Double(k - 1)) }  // wet × mix
        for channel in audio.channels {
            for n in 0..<Self.frames {
                if want[n] == 0 {
                    #expect(channel[n] == 0, "frame \(n)")
                } else {
                    #expect(abs(Double(channel[n]) - want[n]) < 1e-7, "frame \(n)")
                }
            }
        }
        #expect(audio.channels[0] == audio.channels[1])
    }
}
