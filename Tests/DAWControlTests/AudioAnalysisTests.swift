import DAWControl
import DAWModel
import Foundation
import Testing

// CTL-002 audio.analyze / audio.compare: the numbers agents check renders against (14).

@Suite("Audio analysis (CTL-002)")
struct AudioAnalysisTests {
    let rate = 48_000.0

    @Test("CTL-002 audio.analyze: peak, RMS and the spectrum of a sine")
    func sineLevels() throws {
        let sine = TestAudio.sine(frequency: 1000, amplitude: 0.5, sampleRate: rate, frames: 48_000)
        let a = try AudioAnalysis.analyze(AudioData(sampleRate: rate, channels: [sine, sine.map { $0 * 0.1 }]))
        #expect(a.channels == 2 && a.frames == 48_000)
        #expect(abs(a.peakDb[0] + 6.0206) < 0.001)
        #expect(abs(a.peakDb[1] + 26.0206) < 0.001)
        #expect(abs(a.rmsDb[0] + 9.0309) < 0.01, "a sine's RMS is peak − 3.01 dB")
        #expect(abs(a.spectrumPeakHz - 1000) < 1)
        // The mono mix is (0.5 + 0.05) / 2 = 0.275 → -11.21 dB, all in the band holding 1 kHz.
        let band = try #require(a.spectrum.first { $0.lowHz <= 1000 && 1000 < $0.highHz })
        #expect(abs(band.db + 11.21) < 0.1)
        #expect(a.spectrum.filter { $0.highHz < 500 }.allSatisfy { $0.db < -60 })
        #expect(abs(a.dcOffset) < 1e-4)
        #expect(a.firstNonSilentSample == 1, "sin(0) = 0")
    }

    @Test("CTL-002 audio.analyze: BS.1770 loudness of a full-scale 1 kHz sine is -3.01 LUFS in one channel, ~0 in two")
    func loudness() throws {
        let sine = TestAudio.sine(frequency: 1000, amplitude: 1, sampleRate: rate, frames: 5 * 48_000)
        let mono = try AudioAnalysis.analyze(AudioData(sampleRate: rate, channels: [sine]))
        #expect(abs(mono.lufsIntegrated + 3.01) < 0.05)
        let stereo = try AudioAnalysis.analyze(AudioData(sampleRate: rate, channels: [sine, sine]))
        #expect(abs(stereo.lufsIntegrated - 0) < 0.05)
        // At 44.1 kHz the K-weighting is derived for that rate and gives the same reading.
        let sine44 = TestAudio.sine(frequency: 1000, amplitude: 1, sampleRate: 44_100, frames: 5 * 44_100)
        #expect(abs(try AudioAnalysis.analyze(AudioData(sampleRate: 44_100, channels: [sine44])).lufsIntegrated + 3.01) < 0.05)
        // -20 dB quieter reads 20 LU lower. The absolute gate drops the blocks in the leading second
        // of silence; the three that straddle the start (25/50/75 % sine) pass both gates, so the
        // mean power is (47 + 1.5) / 50 of the sine's: -23.01 - 0.13 LUFS.
        let quiet = [Float](repeating: 0, count: 48_000) + sine.map { $0 * 0.1 }
        #expect(abs(try AudioAnalysis.analyze(AudioData(sampleRate: rate, channels: [quiet])).lufsIntegrated + 23.14) < 0.02)
    }

    @Test("CTL-002 audio.analyze: true peak finds the inter-sample peak a sample peak misses")
    func truePeak() throws {
        // fs/4 at 45°: every sample is ±0.707, the waveform peaks at 1.0 between them.
        let sine = TestAudio.sine(frequency: rate / 4, amplitude: 1, sampleRate: rate, frames: 4800, phase: Double.pi / 4)
        let a = try AudioAnalysis.analyze(AudioData(sampleRate: rate, channels: [sine]))
        #expect(abs(a.peakDb[0] + 3.01) < 0.01)
        #expect(abs(a.truePeakDb) < 0.1)
    }

    @Test("CTL-002 audio.analyze: silence reads the floor; DC offset, first sound and ranges")
    func silenceAndRanges() throws {
        var samples = [Float](repeating: 0, count: 10_000)
        let silent = try AudioAnalysis.analyze(AudioData(sampleRate: rate, channels: [samples]))
        #expect(silent.peakDb == [AudioAnalysis.floorDb] && silent.lufsIntegrated == AudioAnalysis.floorDb)
        #expect(silent.firstNonSilentSample == -1 && silent.spectrumPeakHz == 0)
        #expect(silent.spectrum.allSatisfy { $0.db == AudioAnalysis.floorDb })

        samples[1234] = 0.5
        let impulse = AudioData(sampleRate: rate, channels: [samples, [Float](repeating: 0.25, count: 10_000)])
        let a = try AudioAnalysis.analyze(impulse, silenceThresholdDb: -7)
        #expect(a.firstNonSilentSample == 1234, "0.25 is below -7 dBFS, 0.5 is not")
        #expect(abs(a.dcOffset - 0.25) < 1e-6)
        let tail = try impulse.slice(FrameRange(start: 2000, end: 20_000))
        #expect(try AudioAnalysis.analyze(tail, rangeStart: 2000, silenceThresholdDb: -7).firstNonSilentSample == -1)
        let around = try impulse.slice(FrameRange(start: 1000, end: 2000))
        let b = try AudioAnalysis.analyze(around, rangeStart: 1000, silenceThresholdDb: -7)
        #expect(b.frames == 1000 && b.firstNonSilentSample == 1234, "reported in file frames")
        #expect(throws: DAWError.self) { try impulse.slice(FrameRange(start: 5, end: 1)) }
        #expect(throws: DAWError.self) { try AudioAnalysis.analyze(impulse, bands: 0) }
    }

    @Test("CTL-002 audio.analyze reads WAV/CAF/AIFF files")
    func files() throws {
        let dir = try TempDir()
        let sine = TestAudio.sine(frequency: 440, amplitude: 0.25, sampleRate: 44_100, frames: 44_100)
        for ext in ["wav", "caf", "aiff"] {
            let url = dir.file("s.\(ext)")
            try TestAudio.write([sine], sampleRate: 44_100, to: url)
            let audio = try AudioData(contentsOf: url)
            #expect(audio.sampleRate == 44_100 && audio.channels.count == 1 && audio.channels[0] == sine,
                    "\(ext): \(audio.sampleRate) Hz, \(audio.channels.count) ch, \(audio.frameCount) frames, \(audio.channels.first?.prefix(3) ?? [])")
        }
        #expect(throws: DAWError.self) { try AudioData(contentsOf: dir.file("none.wav")) }
    }

    @Test("CTL-002 audio.compare: identical files null to the floor and pass (TEST-002)")
    func identical() throws {
        let sine = TestAudio.sine(frequency: 1000, amplitude: 0.5, sampleRate: rate, frames: 9600)
        let a = AudioData(sampleRate: rate, channels: [sine, sine])
        let c = try AudioComparison.compare(a, a)
        #expect(c.nullResidualDb == AudioAnalysis.floorDb && c.pass && c.maxDiffSample == 0 && c.offsetSamples == 0)
        #expect(c.toleranceDb == -100)
    }

    @Test("CTL-002 audio.compare: residual level, where it peaks, and a length mismatch")
    func residual() throws {
        let sine = TestAudio.sine(frequency: 1000, amplitude: 0.5, sampleRate: rate, frames: 9600)
        var b = sine
        b[5000] += 0.001
        let c = try AudioComparison.compare(AudioData(sampleRate: rate, channels: [sine]), AudioData(sampleRate: rate, channels: [b]))
        #expect(abs(c.nullResidualDb + 60) < 0.01 && c.maxDiffSample == 5000 && !c.pass)
        #expect(try AudioComparison.compare(AudioData(sampleRate: rate, channels: [sine]), AudioData(sampleRate: rate, channels: [b]),
                                            toleranceDb: -50).pass)

        let longer = try AudioComparison.compare(AudioData(sampleRate: rate, channels: [sine]),
                                                 AudioData(sampleRate: rate, channels: [sine + [0.5]]))
        #expect(longer.framesA == 9600 && longer.framesB == 9601 && longer.maxDiffSample == 9600)
        #expect(abs(longer.nullResidualDb + 6.02) < 0.01)
    }

    @Test("CTL-002 audio.compare: the cross-correlation finds how far b is shifted", arguments: [37, -37, 0, 1000])
    func offset(shift: Int) throws {
        // Noise correlates only at the true lag.
        var generator = SplitMix(seed: 7)
        let noise = (0..<20_000).map { _ in Float.random(in: -0.5...0.5, using: &generator) }
        let shifted = shift >= 0
            ? [Float](repeating: 0, count: shift) + noise
            : Array(noise.dropFirst(-shift))
        let a = AudioData(sampleRate: rate, channels: [noise])
        let b = AudioData(sampleRate: rate, channels: [shifted])
        #expect(try AudioComparison.compare(a, b).offsetSamples == Int64(shift))
        // A narrower search can't report a lag outside it.
        let narrow = try AudioComparison.compare(a, b, maxOffset: 10).offsetSamples
        #expect(abs(shift) <= 10 ? narrow == Int64(shift) : abs(narrow) <= 10)
    }

    @Test("CTL-002 audio.compare rejects different rates or channel counts")
    func mismatch() {
        let x = AudioData(sampleRate: 48_000, channels: [[0]])
        #expect(throws: DAWError.self) { try AudioComparison.compare(x, AudioData(sampleRate: 44_100, channels: [[0]])) }
        #expect(throws: DAWError.self) { try AudioComparison.compare(x, AudioData(sampleRate: 48_000, channels: [[0], [0]])) }
    }
}

/// Deterministic noise for the correlation tests.
struct SplitMix: RandomNumberGenerator {
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
