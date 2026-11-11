import DAWControl
import DAWModel
import Foundation
import Testing

// T-036 (DW-073): the M3 goldens checked sample by sample, so a regenerated reference can't hide
// a wrong clip position, fade or reset. Positions come from DAWModel's TempoMap, the bit-identical
// Swift mirror of the engine's (TIME-011), never from the render itself; source audio comes from
// the fixture's asset file.

@Suite("Golden references, M3 (TIME-001, TIME-005..008, DSP-001)")
struct M3GoldenReferenceTests {
    /// Both strips are centre-panned (MIX-005): √½ · √½.
    static let centre = 0.5
    static let tolerance = 1e-6

    static func asset(_ name: String) throws -> [Float] {
        let audio = try AudioData(contentsOf: GoldenHarness.fixturesDirectory.appending(path: "assets/\(name)"))
        #expect(audio.sampleRate == 48000)
        #expect(audio.channels.count == 1)
        return audio.channels.first ?? []
    }

    // MARK: clips_fades_tempo_change

    /// The fixture's map: 120 bpm, then 90 bpm from tick 240 (SetTempoEvent), 4/4, 48 kHz.
    static func tempoChangeMap() throws -> TempoMap {
        try TempoMap(tempoEvents: [TempoEvent(tick: 0, bpm: 120), TempoEvent(tick: 240, bpm: 90)],
                     timeSignatures: [TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)],
                     sampleRate: 48000)
    }

    /// An audio clip as the fixture adds it, in ticks.
    struct ClipSpec {
        var start: Int64, length: Int64, sourceOffset: Int, gain: Double, fadeIn: Int64, fadeOut: Int64
    }

    static let clipA = ClipSpec(start: 480, length: 700, sourceOffset: 0, gain: 0.5, fadeIn: 100, fadeOut: 200)
    static let clipB = ClipSpec(start: 1180, length: 700, sourceOffset: 17500, gain: 1.5, fadeIn: 250, fadeOut: 300)

    /// DSP-001 placed on `map`: samples [S, E) = [tickToSample(start), tickToSample(start + length));
    /// fades are ticks converted the same way, frame k of a K-frame fade-in at k/K, the fade-out
    /// mirrored (0 on the last frame); source frame offset + (p − S), silent outside the asset.
    struct PlacedClip {
        var start: Int, end: Int, fadeInEnd: Int, fadeOutStart: Int
        var spec: ClipSpec

        init(_ spec: ClipSpec, on map: TempoMap) {
            self.spec = spec
            start = Int(map.tickToSample(Tick(spec.start)))
            end = Int(map.tickToSample(Tick(spec.start + spec.length)))
            fadeInEnd = Int(map.tickToSample(Tick(spec.start + spec.fadeIn)))
            fadeOutStart = Int(map.tickToSample(Tick(spec.start + spec.length - spec.fadeOut)))
        }

        func value(at p: Int, asset: [Float]) -> Double {
            guard (start..<end).contains(p) else { return 0 }
            let src = spec.sourceOffset + (p - start)
            guard asset.indices.contains(src) else { return 0 }
            var g = spec.gain
            let sinceStart = p - start, untilEnd = end - 1 - p
            let fadeIn = fadeInEnd - start, fadeOut = end - fadeOutStart
            if sinceStart < fadeIn { g *= Double(sinceStart) / Double(fadeIn) }
            if untilEnd < fadeOut { g *= Double(untilEnd) / Double(fadeOut) }
            return g * Double(asset[src])
        }
    }

    /// TIME-001/D-06: the positions the fixture's comment states are the tempo map's, and the
    /// tempo change moved both clips (they would sit elsewhere at a constant 120 bpm).
    @Test("TIME-001, D-06: clips_fades_tempo_change's clip and fade positions come from the tempo map")
    func tempoChangePositions() throws {
        let map = try Self.tempoChangeMap()
        #expect(map.tickToSample(Tick(240)) == 6000)       // the change, inside block 11 (5632..<6144)
        #expect(6000 % 512 != 0)                           // TIME-007: mid-block
        let a = PlacedClip(Self.clipA, on: map), b = PlacedClip(Self.clipB, on: map)
        #expect([a.start, a.fadeInEnd, a.fadeOutStart, a.end] as [Int] == [14000, 17333, 30667, 37333] as [Int])
        #expect([b.start, b.fadeInEnd, b.fadeOutStart, b.end] as [Int] == [37333, 45667, 50667, 60667] as [Int])
        #expect(a.end == b.start)  // adjacent
        #expect(map.tickToSample(Tick(2160)) == 70000)     // the render's end

        let constant = TempoMap()  // 120 bpm throughout: where the clips were added
        #expect(PlacedClip(Self.clipA, on: constant).start == 12000)
        #expect(PlacedClip(Self.clipB, on: constant).start == 29500)
        #expect(PlacedClip(Self.clipB, on: constant).end - PlacedClip(Self.clipB, on: constant).start == 17500)
    }

    /// DSP-001 per sample: every frame is 0.5 · gain · fade · source with the source frame
    /// counted from the clip's own start (moved, not stretched), silence outside both clips and
    /// after B's audio runs out.
    @Test("DSP-001, TIME-001, D-06: clips_fades_tempo_change matches the clips sample by sample")
    func tempoChangeSamples() throws {
        let audio = try AudioData(contentsOf: GoldenHarness.reference("clips_fades_tempo_change"))
        let tone = try Self.asset("tone_441_48k.wav")
        #expect(tone.count == 35000)
        #expect(audio.sampleRate == 48000)
        #expect(audio.channels.count == 2)
        #expect(audio.frameCount == 70000)
        guard audio.channels.count == 2, audio.frameCount == 70000 else { return }
        let map = try Self.tempoChangeMap()
        let clips = [PlacedClip(Self.clipA, on: map), PlacedClip(Self.clipB, on: map)]

        for (c, channel) in audio.channels.enumerated() {
            var worst = 0.0, worstAt = 0
            for (p, x) in channel.enumerated() {
                let expected = Self.centre * clips.reduce(0) { $0 + $1.value(at: p, asset: tone) }
                let diff = abs(Double(x) - expected)
                if diff > worst { (worst, worstAt) = (diff, p) }
            }
            #expect(worst < Self.tolerance, "channel \(c): off by \(worst) at frame \(worstAt)")
        }

        // The edges, exactly where the map puts them.
        let l = audio.channels[0].map(Double.init)
        let a = clips[0], b = clips[1]
        #expect(l[..<a.start].allSatisfy { $0 == 0 })              // nothing before A
        #expect(l[a.start] == 0 && l[a.start + 1] != 0)            // fade-in starts at 0
        #expect(abs(l[a.fadeInEnd + 12] - Self.centre * 0.5 * Double(tone[a.fadeInEnd + 12 - a.start])) < Self.tolerance)
        #expect(l[a.end - 1] == 0)                                 // A's fade-out ends at 0
        #expect(l[b.start] == 0 && l[b.start + 1] != 0)            // B's fade-in starts at 0
        // D-06: B's source runs out 17500 frames after its start, before its span ends.
        let audioEnd = b.start + (tone.count - Self.clipB.sourceOffset)
        #expect(audioEnd == 54833 && audioEnd > b.fadeOutStart && audioEnd < b.end)  // inside the fade-out
        #expect(l[audioEnd - 1] != 0)
        #expect(l[audioEnd...].allSatisfy { $0 == 0 })
    }

    // MARK: locate_reset

    /// Frames the first render processed: 12000 (ticks 0..480 at 120 bpm), in whole 512-frame
    /// blocks (IO-010: the last block is rendered in full and cut).
    static let firstRenderBlocks = (12000 + 511) / 512
    static let effectFramesBefore = firstRenderBlocks * 512

    /// TIME-008: L is the clip from tick 1000 (sample 25000) at full level from frame 0: the
    /// locate reset the clip player, so no 64-frame wrap crossfade from where the first render
    /// stopped. DW-063 (T-089): R is the effect's sine from phase 0, since a render resets every
    /// node; a live locate keeping effect state is checked in C++ (TransportTests
    /// "locateFlagsReset", OfflineResetTests "resetsEveryNode").
    @Test("TIME-008, DW-063: locate_reset restarts the clip player cleanly, and the render resets the effect too")
    func locateResetSamples() throws {
        let audio = try AudioData(contentsOf: GoldenHarness.reference("locate_reset"))
        let tone = try Self.asset("tone_441_48k.wav")
        #expect(audio.channels.count == 2)
        #expect(audio.frameCount == 6000)
        guard audio.channels.count == 2, audio.frameCount == 6000 else { return }
        let start = Int(TempoMap().tickToSample(Tick(1000)))
        #expect(start == 25000)
        #expect(Self.effectFramesBefore == 12288)

        let half = 0.5.squareRoot()  // hard pan × the master's centre pan
        var worst = (left: 0.0, right: 0.0)
        for f in 0..<6000 {
            let left = half * Double(tone[start + f])
            let right = half * 0.5 * sin(2 * Double.pi * 1100 * Double(f) / 48000)
            worst.left = max(worst.left, abs(Double(audio.channels[0][f]) - left))
            worst.right = max(worst.right, abs(Double(audio.channels[1][f]) - right))
        }
        #expect(worst.left < Self.tolerance)
        #expect(worst.right < Self.tolerance)

        // What a missing reset would look like: frame 0 of a crossfade plays the new pass at 1/64
        // plus 63/64 of the old pass at sample 12288; an effect left running would be at its
        // frame 12288, about 0.21, instead of sin(0) = 0.
        let l0 = Double(audio.channels[0][0]), r0 = Double(audio.channels[1][0])
        #expect(abs(l0 - half * Double(tone[start])) < Self.tolerance)
        let crossfaded = half * (Double(tone[start]) / 64 + 63.0 / 64 * Double(tone[Self.effectFramesBefore]))
        #expect(abs(l0 - crossfaded) > 0.1)
        #expect(abs(r0) < Self.tolerance)
        let running = half * 0.5 * sin(2 * Double.pi * 1100 * Double(Self.effectFramesBefore) / 48000)
        #expect(abs(running) > 0.2)
    }

    /// The fixture really renders twice, and the first render is what the second one's numbers
    /// assume: 12000 frames, the effect's sine from frame 0, the clip from tick 0.
    @Test("TIME-008: locate_reset's first render plays ticks 0..480 from a fresh effect")
    @MainActor func locateResetFirstRender() async throws {
        let fixture = try GoldenFixture(name: "locate_reset", contentsOf:
            GoldenHarness.fixturesDirectory.appending(path: "locate_reset.jsonl"))
        let run = await GoldenHarness.run(fixture, reference: nil)
        #expect(run.failures == [])
        #expect(run.renders.map(\.frames) == [12000, 6000])
        guard run.renders.count == 2 else { return }
        let first = try AudioData(contentsOf: URL(fileURLWithPath: run.renders[0].path))
        let tone = try Self.asset("tone_441_48k.wav")
        let half = 0.5.squareRoot()
        var worst = 0.0
        for f in 0..<first.frameCount {
            let left = half * Double(tone[f])
            let right = half * 0.5 * sin(2 * Double.pi * 1100 * Double(f) / 48000)
            worst = max(worst, abs(Double(first.channels[0][f]) - left), abs(Double(first.channels[1][f]) - right))
        }
        #expect(worst < Self.tolerance)
        if run.failures.isEmpty { try? FileManager.default.removeItem(at: run.workDirectory) }
    }

    // MARK: loop_wrap_midblock

    /// The fixture's loop, ticks [86, 319) at 120 bpm (25 frames per tick), and where its wraps
    /// fall in the 24000-frame render that starts at tick 0.
    static let loopStart = 2150, loopEnd = 7975
    static let wraps = [7975, 13800, 19625]

    /// TIME-005: the wraps sit where the tempo map puts the loop, inside blocks, and the second
    /// one's 64-frame crossfade runs over a block boundary.
    @Test("TIME-005: loop_wrap_midblock's loop points and wraps come from the tempo map and fall mid-block")
    func loopWrapPositions() {
        let map = TempoMap()
        #expect(Int(map.tickToSample(Tick(86))) == Self.loopStart)
        #expect(Int(map.tickToSample(Tick(319))) == Self.loopEnd)
        let length = Self.loopEnd - Self.loopStart
        #expect(Self.wraps == [Self.loopEnd, Self.loopEnd + length, Self.loopEnd + 2 * length])
        #expect(Self.wraps.allSatisfy { $0 % 512 != 0 })
        #expect(Self.wraps[1] % 512 > 512 - 64)  // 488: 24 frames in this block, 40 in the next
    }

    /// TIME-005/006, DSP-001 per sample: straight playback up to the first wrap; after a wrap at
    /// W, frame W + d is the loop from 2150 + d, and for d < 64 the new pass fades in at
    /// (d + 1)/64 while the old pass goes on from 7975 + d at (63 − d)/64.
    @Test("TIME-005/006: loop_wrap_midblock matches the looped clip sample by sample, with 64-frame wrap crossfades")
    func loopWrapSamples() throws {
        let audio = try AudioData(contentsOf: GoldenHarness.reference("loop_wrap_midblock"))
        let tone = try Self.asset("tone_441_48k.wav")
        #expect(audio.channels.count == 2)
        #expect(audio.frameCount == 24000)
        guard audio.channels.count == 2, audio.frameCount == 24000 else { return }

        func expected(_ i: Int) -> Double {
            guard let w = Self.wraps.last(where: { $0 <= i }) else { return Self.centre * Double(tone[i]) }
            let d = i - w
            let new = Double(tone[Self.loopStart + d])
            guard d < 64 else { return Self.centre * new }
            let old = Double(tone[Self.loopEnd + d])
            return Self.centre * (Double(d + 1) / 64 * new + Double(63 - d) / 64 * old)
        }
        for (c, channel) in audio.channels.enumerated() {
            var worst = 0.0, worstAt = 0
            for (i, x) in channel.enumerated() {
                let diff = abs(Double(x) - expected(i))
                if diff > worst { (worst, worstAt) = (diff, i) }
            }
            #expect(worst < Self.tolerance, "channel \(c): off by \(worst) at frame \(worstAt)")
        }
    }

    /// TIME-005 "click-free": no frame-to-frame step anywhere is larger than the tone's own
    /// steepest step plus 1/64 of the jump across the wrap. A hard cut would step by ~0.5.
    @Test("TIME-005: loop_wrap_midblock is click-free across every wrap")
    func loopWrapIsClickFree() throws {
        let audio = try AudioData(contentsOf: GoldenHarness.reference("loop_wrap_midblock"))
        let tone = try Self.asset("tone_441_48k.wav")
        guard let left = audio.channels.first, left.count == 24000 else {
            Issue.record("unexpected reference shape")
            return
        }
        let hardCut = Self.centre * abs(Double(tone[Self.loopStart]) - Double(tone[Self.loopEnd - 1]))
        #expect(hardCut > 0.49)
        let sineStep = Self.centre * 0.5 * 2 * Double.pi * 441 / 48000  // 0.0144
        let jump = Self.centre * 2 * 0.5                                  // the two passes at most a full swing apart
        var largest = 0.0
        for i in 1..<left.count { largest = max(largest, abs(Double(left[i]) - Double(left[i - 1]))) }
        #expect(largest <= sineStep + jump / 64 + 1e-6, "largest step \(largest)")
        #expect(largest < hardCut / 10)
    }
}
