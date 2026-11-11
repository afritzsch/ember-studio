import DAWControl
import DAWModel
import Foundation
import Testing

// T-044: the M4 goldens (DSP-003, DSP-021, DW-101, DW-139) checked sample by sample, so a
// regenerated reference can't hide a wrong pitch, a stuck note, a missing chase or a misplaced
// note-off. Note positions come from DAWModel's TempoMap (TIME-011), source audio from the
// fixtures' asset file, and every voice is rebuilt from 06 "Sampler semantics": a voice reads its
// zone from frame 0 at rate 2^((note − root)/12), shaped by the linear ADSR advanced one sample at
// a time, with MIDI events acting on their exact frame.

@Suite("Golden references, M4 (DSP-003, DSP-021)")
struct M4GoldenReferenceTests {
    /// Centre pans on the track and the master (MIX-005): √½ · √½.
    static let centre = 0.5
    static let tolerance = 1e-6
    /// The fixtures' zone: rootKey 69 (A4) on a440_48k.wav, looping the whole asset.
    static let rootKey = 69
    static let assetFrames = 48000

    static func a440() throws -> [Float] {
        let tone = try M3GoldenReferenceTests.asset("a440_48k.wav")
        #expect(tone.count == assetFrames)
        return tone
    }

    /// 2^((note − root)/12) for the fixtures' notes: A4 (69) plays at 1, A5 (81) at 2 (DSP-021).
    /// Integer rates read whole source frames, which 4-point Hermite passes through exactly.
    static func rate(_ note: Int) -> Int {
        let rate = pow(2, Double(note - rootKey) / 12)
        #expect(rate == rate.rounded(), "the fixtures only use octaves of the root")
        return Int(rate)
    }

    /// DSP-022's linear ADSR with the sampler's default params (attack 2 ms, decay 0.3 s, sustain
    /// 1, release 0.2 s at 48 kHz), in the engine's float steps so a 9600-frame release ends on
    /// the frame it does there. One `next()` per output frame; a note-on starts it from 0 (its
    /// first frame is already one step up) and a note-off releases from the current level.
    struct Envelope {
        static let attackStep: Float = { let frames = Float(0.002) * Float(48000); return frames > 1 ? 1 / frames : 1 }()
        static let releaseFrames = Float(0.2) * Float(48000)

        enum Stage { case attack, sustain, release, idle }
        var stage = Stage.attack
        var level: Float = 0
        var releaseStep: Float = 1

        mutating func release() {
            guard stage != .release && stage != .idle else { return }
            stage = .release
            releaseStep = Self.releaseFrames > 1 ? level / Self.releaseFrames : level
            if releaseStep <= 0 { releaseStep = 1 }
        }

        mutating func next() -> Float {
            switch stage {
            case .attack:
                level += Self.attackStep
                if level >= 1 { (level, stage) = (1, .sustain) }  // sustain 1: decay has nowhere to go
            case .sustain:
                break
            case .release:
                level -= releaseStep
                if level <= 0 { (level, stage) = (0, .idle) }
            case .idle:
                return 0
            }
            return level
        }
    }

    /// A sampler voice in render frames: its note-on frame (negative: it started in an earlier
    /// render whose frames it went through), its note-off frame and its key. Velocity 127, so
    /// the velocity curve gives gain 1.
    struct Voice {
        var on: Int
        var off: Int?
        var key: Int
    }

    /// Every frame of the render, both channels: the voices summed (a looping zone, so a held
    /// note never ends) × 0.5.
    static func render(_ voices: [Voice], frames: Int, asset: [Float]) -> [Double] {
        var out = [Float](repeating: 0, count: frames)
        for voice in voices {
            var env = Envelope()
            var pos = 0
            let step = rate(voice.key)
            for n in voice.on..<frames {
                if n == voice.off { env.release() }
                let level = env.next()
                if env.stage == .idle { break }
                if n >= 0 { out[n] += level * asset[pos % asset.count] }
                pos += step
            }
        }
        return out.map { centre * Double($0) }
    }

    static func expectMatches(_ audio: AudioData, _ expected: [Double], _ name: String) {
        #expect(audio.sampleRate == 48000)
        #expect(audio.channels.count == 2)
        #expect(audio.frameCount == expected.count)
        guard audio.channels.count == 2, audio.frameCount == expected.count else { return }
        for (c, channel) in audio.channels.enumerated() {
            var worst = 0.0, worstAt = 0
            for (n, x) in channel.enumerated() {
                let diff = abs(Double(x) - expected[n])
                if diff > worst { (worst, worstAt) = (diff, n) }
            }
            #expect(worst < tolerance, "\(name) channel \(c): off by \(worst) at frame \(worstAt)")
        }
    }

    /// The tick → frame positions the fixtures state, at 120 bpm (TIME-001).
    static func frame(_ tick: Int64) -> Int { Int(TempoMap().tickToSample(Tick(tick))) }

    // MARK: sampler_pitch

    /// DSP-021: A4 on an A4-rooted zone plays the asset as it is; A5 plays every second source
    /// frame, which is the 440 Hz sine at 880 Hz. Every sample, envelopes included.
    @Test("DSP-021: sampler_pitch plays A4 at rate 1 and A5 at rate 2 (2× the frequency), sample by sample")
    func samplerPitchSamples() throws {
        let audio = try AudioData(contentsOf: GoldenHarness.reference("sampler_pitch"))
        let tone = try Self.a440()
        #expect([0, 480, 960, 1440, 1920].map(Self.frame) as [Int] == [0, 12000, 24000, 36000, 48000] as [Int])
        let voices = [Voice(on: 0, off: 12000, key: 69), Voice(on: 24000, off: 36000, key: 81)]
        let expected = Self.render(voices, frames: 48000, asset: tone)
        Self.expectMatches(audio, expected, "sampler_pitch")
        guard let l = audio.channels.first, l.count == 48000 else { return }

        // Straight from DSP-021, without the envelope model: once the attack is over (96
        // frames), A4 is 0.5 × the asset and A5 0.5 × every second asset frame.
        #expect(Self.rate(69) == 1 && Self.rate(81) == 2)
        var worst = 0.0
        for n in 96..<12000 { worst = max(worst, abs(Double(l[n]) - 0.5 * Double(tone[n]))) }
        for n in 24096..<36000 {
            worst = max(worst, abs(Double(l[n]) - 0.5 * Double(tone[(2 * (n - 24000)) % tone.count])))
        }
        #expect(worst < Self.tolerance)

        // 2× the frequency, counted: rising zero crossings over 10800 frames, 99 periods at 440 Hz.
        // Both windows start mid-period (source frames 1250 and 2 × 1210), so none sits on an edge.
        func risingCrossings(_ range: Range<Int>) -> Int {
            range.dropFirst().filter { l[$0 - 1] < 0 && l[$0] >= 0 }.count
        }
        #expect(risingCrossings(1250..<12050) == 99)
        #expect(risingCrossings(25210..<36010) == 198)

        // Each release ends 9600 frames (0.2 s) after its note-off; nothing sounds between notes.
        #expect(l[21500..<21600].contains { $0 != 0 })
        #expect(l[21600..<24000].allSatisfy { $0 == 0 })
        #expect(l[45600...].allSatisfy { $0 == 0 })
    }

    // MARK: midi_loop_wrap

    /// The fixture's loop, ticks [100, 1000), and where its wraps fall in the 60000-frame render.
    static let loopStart = 2500, loopEnd = 25000
    static let wraps = [25000, 47500]

    /// DSP-003, DW-103: at each wrap the note hanging over the loop end (X, A5) gets its note-off
    /// on the wrap frame and the note spanning the loop start (Y, A4) its chased note-on there.
    static let loopVoices = [
        Voice(on: 0, off: 10000, key: 69),          // Y, first pass
        Voice(on: 20000, off: 25000, key: 81),      // X, ended by the first wrap
        Voice(on: 25000, off: 32500, key: 69),      // Y chased at the first wrap: ticks 100..400
        Voice(on: 42500, off: 47500, key: 81),      // X again (tick 800 in the second pass)
        Voice(on: 47500, off: 55000, key: 69),      // Y chased at the second wrap
    ]

    @Test("TIME-005, DSP-003: midi_loop_wrap's loop and wraps come from the tempo map and fall mid-block")
    func midiLoopWrapPositions() {
        #expect(Self.frame(100) == Self.loopStart && Self.frame(1000) == Self.loopEnd)
        let length = Self.loopEnd - Self.loopStart
        #expect(Self.wraps == [Self.loopEnd, Self.loopEnd + length])
        #expect(Self.wraps.allSatisfy { $0 % 512 != 0 })
        // Y spans the loop start and ends inside the loop; X starts inside it and ends after it.
        #expect(Self.frame(0) < Self.loopStart && Self.frame(400) > Self.loopStart && Self.frame(400) < Self.loopEnd)
        #expect(Self.frame(800) > Self.loopStart && Self.frame(1200) > Self.loopEnd)
        // In the loop, Y chased at a wrap W sounds its remaining 300 ticks; X starts 700 ticks in.
        #expect(Self.loopVoices[2].off! - Self.wraps[0] == Self.frame(400) - Self.loopStart)
        #expect(Self.loopVoices[3].on - Self.wraps[0] == Self.frame(800) - Self.loopStart)
    }

    @Test("DSP-003, DW-101, DW-103: midi_loop_wrap ends the hanging note and chases the note at the loop start on every wrap, sample by sample")
    func midiLoopWrapSamples() throws {
        let audio = try AudioData(contentsOf: GoldenHarness.reference("midi_loop_wrap"))
        let tone = try Self.a440()
        let expected = Self.render(Self.loopVoices, frames: 60000, asset: tone)
        Self.expectMatches(audio, expected, "midi_loop_wrap")
        guard let l = audio.channels.first, l.count == 60000 else { return }

        // What the failures would look like, per wrap W. X (on 5000 frames before W) contributes
        // only its release after W: from W + 9600 on the render is Y alone, where a stuck X would
        // add a full-level 880 Hz sine. Y's chased voice starts on W itself: before W the render
        // is X alone, from W on it is X's release plus Y's attack.
        for (w, y) in zip(Self.wraps, [Self.loopVoices[2], Self.loopVoices[4]]) {
            let x = Voice(on: w - 5000, off: w, key: 81)
            let xOnly = Self.render([x], frames: w + 9700, asset: tone)
            let yOnly = Self.render([y], frames: w + 9700, asset: tone)
            #expect((w + 9600..<w + 9700).allSatisfy { abs(Double(l[$0]) - yOnly[$0]) < Self.tolerance })
            let stuck = Self.render([Voice(on: x.on, off: nil, key: 81)], frames: w + 9700, asset: tone)
            #expect((w + 9600..<w + 9700).map { abs(stuck[$0]) }.max() ?? 0 > 0.2)
            #expect((w - 96..<w).allSatisfy { abs(Double(l[$0]) - xOnly[$0]) < Self.tolerance })
            #expect((w..<w + 96).allSatisfy { abs(Double(l[$0]) - xOnly[$0] - yOnly[$0]) < Self.tolerance })
            #expect((w + 1..<w + 96).allSatisfy { yOnly[$0] != 0 })
        }
        // Between Y's release and X's next note-on the render is silent: no other voice sounds.
        #expect(l[19600..<20000].allSatisfy { $0 == 0 })
        #expect(l[42100..<42500].allSatisfy { $0 == 0 })
        #expect(l[19500..<19600].contains { $0 != 0 })  // Y's first release runs up to 19600
    }

    // MARK: midi_locate_no_stuck_notes

    /// The first render's frames, in whole 512-frame blocks (IO-010): Z's voice has read this many
    /// source frames when the second render starts.
    static let firstRenderFrames = 12000
    static let firstRenderBlocks = (firstRenderFrames + 511) / 512

    /// DSP-003, DW-063 (T-089): the second render starts with every node reset, so the held Z
    /// (A4) from the first render is gone (before T-089 it released from frame 0); DW-103 chases
    /// V (A5) there. After V's release the render is silent: no note is left stuck. The live
    /// locate (note-off and release of a held note) is checked in C++: MidiClipPlayerTests
    /// "locateAndStop" and "noStuckNotesFuzz".
    @Test("DSP-003, DW-103, DW-063: midi_locate_no_stuck_notes leaves nothing of the held note and chases the next one at the render start; nothing rings after")
    func locateNoStuckNotesSamples() throws {
        let audio = try AudioData(contentsOf: GoldenHarness.reference("midi_locate_no_stuck_notes"))
        let tone = try Self.a440()
        #expect(Self.frame(1920) == 48000 && Self.frame(2000) == 50000 && Self.frame(1960) == 49000)
        #expect(Self.frame(2160) - Self.frame(2000) == 4000 && Self.frame(2640) - Self.frame(2000) == 16000)
        let before = Self.firstRenderBlocks * 512
        #expect(before == 12288)
        let voices = [Voice(on: 0, off: 4000, key: 81)]
        let expected = Self.render(voices, frames: 16000, asset: tone)
        Self.expectMatches(audio, expected, "midi_locate_no_stuck_notes")
        guard let l = audio.channels.first, l.count == 16000 else { return }

        // A stuck Z would go on at 0.25 × the 440 Hz sine; the render is silent after V's
        // release (4000 + 9600).
        #expect(l[13600...].allSatisfy { $0 == 0 })
        #expect(l[13500..<13600].contains { $0 != 0 })
        // Frame 0 is V's first attack step on source frame 0 (0): nothing of Z, which a held or
        // releasing voice would put there (one release step down from 1 at source frame 12288).
        let z0 = Self.centre * Double(1 - 1 / Envelope.releaseFrames) * Double(tone[before])
        #expect(abs(Double(l[0])) < Self.tolerance)
        #expect(abs(z0) > 0.01)
    }

    /// The fixture really renders twice, and the first render is what the second one's numbers
    /// assume: 12000 frames of Z from tick 0, still held at the end.
    @Test("DSP-003: midi_locate_no_stuck_notes's first render plays the held A4 from tick 0")
    @MainActor func locateNoStuckNotesFirstRender() async throws {
        let fixture = try GoldenFixture(name: "midi_locate_no_stuck_notes", contentsOf:
            GoldenHarness.fixturesDirectory.appending(path: "midi_locate_no_stuck_notes.jsonl"))
        let run = await GoldenHarness.run(fixture, reference: nil)
        #expect(run.failures == [])
        #expect(run.renders.map(\.frames) == [12000, 16000])
        guard run.renders.count == 2 else { return }
        let first = try AudioData(contentsOf: URL(fileURLWithPath: run.renders[0].path))
        let tone = try Self.a440()
        Self.expectMatches(first, Self.render([Voice(on: 0, off: nil, key: 69)], frames: 12000, asset: tone),
                           "first render")
        if run.failures.isEmpty { try? FileManager.default.removeItem(at: run.workDirectory) }
    }
}
