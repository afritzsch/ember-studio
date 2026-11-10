import DAWControl
import DAWModel
import Foundation
import Testing

// T-089 (DW-125): loop_short_multiwrap checked sample by sample, so a regenerated reference can't
// hide a gap, a missed pass or a wrong crossfade. Positions come from DAWModel's TempoMap (the
// bit-identical mirror of the engine's, TIME-011), source audio from the fixture's asset file.

@Suite("Golden references, transport (DW-125, TIME-005/006, DSP-001)")
struct TransportGoldenReferenceTests {
    static let name = "loop_short_multiwrap"
    /// The fixture's loop, ticks [86, 126) at 120 bpm (25 frames per tick), 1000 frames, and
    /// where it wraps in the 24000-frame render from tick 0 in 4096-frame blocks.
    static let loopStart = 2150, loopEnd = 3150, frames = 24000, block = 4096
    static var wraps: [Int] { Array(stride(from: loopEnd, to: frames, by: loopEnd - loopStart)) }

    @Test("DW-125: loop_short_multiwrap's loop is shorter than a block and wraps several times in one")
    func wrapPositions() {
        let map = TempoMap()
        #expect(Int(map.tickToSample(Tick(86))) == Self.loopStart)
        #expect(Int(map.tickToSample(Tick(126))) == Self.loopEnd)
        #expect(Self.loopEnd - Self.loopStart < Self.block)
        #expect(Self.wraps.count == 21)
        // Blocks with four or more wraps: the transport can't lay one out as two segments.
        let perBlock = Dictionary(grouping: Self.wraps, by: { $0 / Self.block }).mapValues(\.count)
        #expect(perBlock.values.filter { $0 >= 4 }.count >= 4)
    }

    /// TIME-005/006, DSP-001 per sample: straight playback up to the first wrap; after a wrap at
    /// W, frame W + d is the loop from 2150 + d, and for d < 64 the new pass fades in at
    /// (d + 1)/64 while the old one goes on from 3150 + d at (63 − d)/64. No frame is silent.
    @Test("DW-125: loop_short_multiwrap plays every pass of the loop sample by sample, crossfaded, no gap")
    func samples() throws {
        let audio = try AudioData(contentsOf: GoldenHarness.reference(Self.name))
        let tone = try M3GoldenReferenceTests.asset("tone_441_48k.wav")
        let centre = M3GoldenReferenceTests.centre
        #expect(audio.channels.count == 2)
        #expect(audio.frameCount == Self.frames)
        guard audio.channels.count == 2, audio.frameCount == Self.frames else { return }
        let wraps = Self.wraps
        func expected(_ i: Int) -> Double {
            guard let w = wraps.last(where: { $0 <= i }) else { return centre * Double(tone[i]) }
            let d = i - w
            let new = Double(tone[Self.loopStart + d])
            guard d < 64 else { return centre * new }
            let old = Double(tone[Self.loopEnd + d])
            return centre * (Double(d + 1) / 64 * new + Double(63 - d) / 64 * old)
        }
        for (c, channel) in audio.channels.enumerated() {
            var worst = 0.0, worstAt = 0
            for (i, x) in channel.enumerated() {
                let diff = abs(Double(x) - expected(i))
                if diff > worst { (worst, worstAt) = (diff, i) }
            }
            #expect(worst < M3GoldenReferenceTests.tolerance, "channel \(c): off by \(worst) at frame \(worstAt)")
        }
        // No gap: the old engine left the rest of a block silent after one pass of a short loop.
        let left = audio.channels[0]
        var longestSilence = 0, run = 0
        for x in left { run = x == 0 ? run + 1 : 0; longestSilence = max(longestSilence, run) }
        #expect(longestSilence < 2)
    }
}
