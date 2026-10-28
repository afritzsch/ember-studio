import Accelerate
import DAWModel
import Foundation

/// `audio.analyze` (CTL-002): what an agent checks a render against (14, Agent verification recipe).
///
/// Levels are dBFS (1.0 = 0 dB). Silence reads `AudioAnalysis.floorDb` instead of -∞, which JSON
/// can't carry.
public struct AudioAnalysis: Codable, Hashable, Sendable {
    /// A log-spaced band of the average spectrum.
    public struct Band: Codable, Hashable, Sendable {
        public var lowHz: Double
        public var highHz: Double
        /// Total power in the band, scaled so a full-scale sine reads 0 dB.
        public var db: Double
    }

    /// The level reported for silence.
    public static let floorDb = -240.0

    public var sampleRate: Double
    public var channels: Int
    /// Frames analyzed.
    public var frames: Int64
    /// Per channel.
    public var peakDb: [Double]
    /// Per channel.
    public var rmsDb: [Double]
    /// ITU-R BS.1770-4 integrated loudness (K-weighted, 400 ms blocks, -70 LUFS absolute and
    /// -10 LU relative gates), every channel weighted 1. `floorDb` if nothing passes the gates.
    public var lufsIntegrated: Double
    /// BS.1770 true peak: the largest sample of a 4× oversampled copy, over all channels.
    public var truePeakDb: Double
    /// The channels' average, Hann-windowed, averaged over half-overlapping frames.
    public var spectrum: [Band]
    /// The strongest frequency above DC (parabolic interpolation between bins); 0 for silence.
    public var spectrumPeakHz: Double
    /// The mean of the channel with the largest DC component (signed, linear).
    public var dcOffset: Double
    /// File frame of the first sample above the silence threshold in any channel; -1 if none.
    public var firstNonSilentSample: Int64

    public static func db(_ amplitude: Double) -> Double {
        amplitude > 0 ? max(20 * log10(amplitude), floorDb) : floorDb
    }

    static func powerDb(_ power: Double) -> Double {
        power > 0 ? max(10 * log10(power), floorDb) : floorDb
    }

    /// `rangeStart` is where `audio` starts in the file, for `firstNonSilentSample`.
    public static func analyze(
        _ audio: AudioData, rangeStart: Int64 = 0, fftSize: Int = 4096, bands: Int = 32,
        silenceThresholdDb: Double = -120
    ) throws(DAWError) -> AudioAnalysis {
        guard fftSize >= 64, fftSize <= 65_536, fftSize & (fftSize - 1) == 0 else {
            throw .invalidArgument("fftSize must be a power of two in 64…65536, got \(fftSize)")
        }
        guard (1...1024).contains(bands) else { throw .invalidArgument("bands must be 1…1024, got \(bands)") }
        guard audio.sampleRate > 0 else { throw .invalidArgument("sample rate \(audio.sampleRate)") }

        var peaks: [Double] = []
        var rmss: [Double] = []
        var dc = 0.0
        for channel in audio.channels {
            var peak: Float = 0
            var meanSquare: Float = 0
            var mean: Float = 0
            if !channel.isEmpty {
                vDSP_maxmgv(channel, 1, &peak, vDSP_Length(channel.count))
                vDSP_measqv(channel, 1, &meanSquare, vDSP_Length(channel.count))
                vDSP_meanv(channel, 1, &mean, vDSP_Length(channel.count))
            }
            peaks.append(db(Double(peak)))
            rmss.append(db(Double(meanSquare).squareRoot()))
            if abs(Double(mean)) > abs(dc) { dc = Double(mean) }
        }

        let threshold = Float(pow(10, silenceThresholdDb / 20))
        let first = (0..<audio.frameCount).first { i in audio.channels.contains { abs($0[i]) > threshold } }
            .map { rangeStart + Int64($0) } ?? -1

        let (spectrum, peakHz) = Self.spectrum(audio, fftSize: fftSize, bands: bands)
        return AudioAnalysis(
            sampleRate: audio.sampleRate, channels: audio.channels.count, frames: Int64(audio.frameCount),
            peakDb: peaks, rmsDb: rmss, lufsIntegrated: integratedLoudness(audio),
            truePeakDb: db(Double(truePeak(audio))), spectrum: spectrum, spectrumPeakHz: peakHz,
            dcOffset: dc, firstNonSilentSample: first)
    }

    // MARK: Loudness (BS.1770-4)

    /// The K-weighting pre-filter and RLB high-pass as biquads at `sampleRate`, from their analog
    /// prototypes (the coefficients BS.1770 tabulates for 48 kHz come out of this).
    static func kWeighting(sampleRate fs: Double) -> [Biquad] {
        var f0 = 1681.974450955533
        let gainDb = 3.999843853973347
        var q = 0.7071752369554196
        var k = tan(Double.pi * f0 / fs)
        let vh = pow(10, gainDb / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = Biquad(
            b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
            a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(Double.pi * f0 / fs)
        a0 = 1 + k / q + k * k
        let highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        return [shelf, highPass]
    }

    static func integratedLoudness(_ audio: AudioData) -> Double {
        let block = Int((0.4 * audio.sampleRate).rounded())
        let hop = Int((0.1 * audio.sampleRate).rounded())
        let n = audio.frameCount
        guard block > 0, hop > 0, n >= block else { return floorDb }

        // Prefix sums of the K-weighted squares make each block's mean square O(1).
        var prefix = [[Double]]()
        for channel in audio.channels {
            var filters = kWeighting(sampleRate: audio.sampleRate)
            var sums = [Double](repeating: 0, count: n + 1)
            for i in 0..<n {
                var y = Double(channel[i])
                for f in filters.indices { y = filters[f].process(y) }
                sums[i + 1] = sums[i] + y * y
            }
            prefix.append(sums)
        }
        var powers: [Double] = []
        var start = 0
        while start + block <= n {
            var power = 0.0
            for sums in prefix { power += (sums[start + block] - sums[start]) / Double(block) }
            powers.append(power)
            start += hop
        }
        func loudness(_ power: Double) -> Double { -0.691 + 10 * log10(power) }
        let absolute = powers.filter { $0 > 0 && loudness($0) > -70 }
        guard !absolute.isEmpty else { return floorDb }
        let relativeGate = loudness(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { loudness($0) > relativeGate }
        guard !gated.isEmpty else { return floorDb }
        return max(loudness(gated.reduce(0, +) / Double(gated.count)), floorDb)
    }

    struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0
        var z2 = 0.0

        init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
            (self.b0, self.b1, self.b2, self.a1, self.a2) = (b0, b1, b2, a1, a2)
        }

        /// Transposed direct form II.
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    // MARK: True peak

    /// Taps each side of the interpolation point.
    static let truePeakHalfWidth = 16

    /// Hann-windowed sinc taps that interpolate at `fraction` (0…1) between two samples.
    static func interpolationTaps(fraction: Double) -> [Float] {
        let k = truePeakHalfWidth
        return (0..<(2 * k)).map { j in
            let t = Double(j - (k - 1)) - fraction
            let sinc = t == 0 ? 1 : sin(Double.pi * t) / (Double.pi * t)
            let window = 0.5 * (1 + cos(Double.pi * t / Double(k)))
            return Float(sinc * window)
        }
    }

    /// The largest magnitude of the signal oversampled 4× (the samples themselves are phase 0).
    static func truePeak(_ audio: AudioData) -> Float {
        let k = truePeakHalfWidth
        let phases = [0.25, 0.5, 0.75].map(interpolationTaps)
        var peak: Float = 0
        for channel in audio.channels where !channel.isEmpty {
            var m: Float = 0
            vDSP_maxmgv(channel, 1, &m, vDSP_Length(channel.count))
            peak = max(peak, m)
            let padded = [Float](repeating: 0, count: k - 1) + channel + [Float](repeating: 0, count: k)
            var out = [Float](repeating: 0, count: channel.count)
            for taps in phases {
                vDSP_conv(padded, 1, taps, 1, &out, 1, vDSP_Length(channel.count), vDSP_Length(taps.count))
                vDSP_maxmgv(out, 1, &m, vDSP_Length(out.count))
                peak = max(peak, m)
            }
        }
        return peak
    }

    // MARK: Spectrum

    static func spectrum(_ audio: AudioData, fftSize n: Int, bands: Int) -> ([Band], Double) {
        let fs = audio.sampleRate
        let nyquist = fs / 2
        let mono = audio.mono()
        // Periodic Hann.
        let window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        let windowPower = window.reduce(0.0) { $0 + Double($1 * $1) }
        let fft = FFT(size: n)!

        var power = [Double](repeating: 0, count: n / 2 + 1)
        var frames = 0
        var start = 0
        repeat {
            var real = [Float](repeating: 0, count: n)
            let count = max(0, min(n, mono.count - start))
            for i in 0..<count { real[i] = mono[start + i] * window[i] }
            var imag = [Float](repeating: 0, count: n)
            fft.transform(real: &real, imag: &imag)
            for k in power.indices { power[k] += Double(real[k] * real[k] + imag[k] * imag[k]) }
            frames += 1
            start += n / 2
        } while start + n <= mono.count
        // A sine of amplitude A puts N·Σw²·A²/4 into the positive bins, so this makes it read A².
        let scale = 4 / (Double(n) * windowPower * Double(frames))
        for k in power.indices { power[k] *= scale }

        let binHz = fs / Double(n)
        let low = min(20, nyquist / 2)
        let ratio = pow(nyquist / low, 1 / Double(bands))
        var result: [Band] = []
        for b in 0..<bands {
            let lo = low * pow(ratio, Double(b))
            let hi = b == bands - 1 ? nyquist : low * pow(ratio, Double(b + 1))
            let first = Int((lo / binHz).rounded(.up))
            let last = b == bands - 1 ? n / 2 : Int((hi / binHz).rounded(.up)) - 1
            var sum = 0.0
            if first <= last {
                for k in first...last { sum += power[k] }
            } else {
                // Narrower than a bin: read the bin nearest the band's centre.
                sum = power[min(n / 2, Int((sqrt(lo * hi) / binHz).rounded()))]
            }
            result.append(Band(lowHz: lo, highHz: hi, db: powerDb(sum)))
        }

        var peakBin = 0
        var peakPower = 0.0
        for k in 1..<power.count where power[k] > peakPower {
            peakBin = k
            peakPower = power[k]
        }
        guard peakBin > 0 else { return (result, 0) }
        var offset = 0.0
        if peakBin < power.count - 1 {
            let (l, c, r) = (powerDb(power[peakBin - 1]), powerDb(power[peakBin]), powerDb(power[peakBin + 1]))
            let denominator = l - 2 * c + r
            if denominator < 0 { offset = 0.5 * (l - r) / denominator }
        }
        return (result, (Double(peakBin) + offset) * binHz)
    }
}

/// `audio.compare` (CTL-002): a null test of two files (TEST-002), and how far one is shifted
/// against the other.
public struct AudioComparison: Codable, Hashable, Sendable {
    /// The largest |a − b| over all channels and frames, in dBFS (the shorter file is padded with
    /// silence). `AudioAnalysis.floorDb` when they are identical.
    public var nullResidualDb: Double
    public var rmsResidualDb: Double
    /// The frame of the largest difference; 0 when identical.
    public var maxDiffSample: Int64
    /// From cross-correlating the channel averages: b ≈ a delayed by this many frames (negative:
    /// b is early). 0 when either is silent.
    public var offsetSamples: Int64
    public var pass: Bool
    public var toleranceDb: Double
    public var framesA: Int64
    public var framesB: Int64
    public var sampleRate: Double

    /// The cross-correlation reads at most this many frames of each file.
    public static let maxCorrelationFrames = 1 << 20

    public static func compare(
        _ a: AudioData, _ b: AudioData, toleranceDb: Double = -100, maxOffset: Int64? = nil
    ) throws(DAWError) -> AudioComparison {
        guard a.sampleRate == b.sampleRate else {
            throw .invalidArgument("sample rates differ: \(a.sampleRate) vs \(b.sampleRate)")
        }
        guard a.channels.count == b.channels.count else {
            throw .invalidArgument("channel counts differ: \(a.channels.count) vs \(b.channels.count)")
        }
        let frames = max(a.frameCount, b.frameCount)
        var maxDiff: Float = 0
        var maxIndex = 0
        var sumSquares = 0.0
        for c in a.channels.indices {
            let x = a.channels[c]
            let y = b.channels[c]
            for i in 0..<frames {
                let d = abs((i < x.count ? x[i] : 0) - (i < y.count ? y[i] : 0))
                sumSquares += Double(d * d)
                if d > maxDiff {
                    maxDiff = d
                    maxIndex = i
                }
            }
        }
        let samples = Double(max(1, frames * a.channels.count))
        let residual = AudioAnalysis.db(Double(maxDiff))
        let maxLag = maxOffset ?? Int64(a.sampleRate)
        return AudioComparison(
            nullResidualDb: residual, rmsResidualDb: AudioAnalysis.db((sumSquares / samples).squareRoot()),
            maxDiffSample: Int64(maxIndex), offsetSamples: offset(a.mono(), b.mono(), maxLag: max(0, maxLag)),
            pass: residual <= toleranceDb, toleranceDb: toleranceDb, framesA: Int64(a.frameCount),
            framesB: Int64(b.frameCount), sampleRate: a.sampleRate)
    }

    /// The lag (|lag| ≤ maxLag) maximising Σ a[n]·b[n+lag], via FFT; the smallest |lag| on ties.
    static func offset(_ a: [Float], _ b: [Float], maxLag: Int64) -> Int64 {
        let x = Array(a.prefix(maxCorrelationFrames))
        let y = Array(b.prefix(maxCorrelationFrames))
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        let size = FFT.nextPowerOfTwo(atLeast: x.count + y.count)
        guard let fft = FFT(size: size) else { return 0 }
        var xr = x + [Float](repeating: 0, count: size - x.count)
        var xi = [Float](repeating: 0, count: size)
        var yr = y + [Float](repeating: 0, count: size - y.count)
        var yi = [Float](repeating: 0, count: size)
        fft.transform(real: &xr, imag: &xi)
        fft.transform(real: &yr, imag: &yi)
        // conj(X)·Y
        var cr = [Float](repeating: 0, count: size)
        var ci = [Float](repeating: 0, count: size)
        for k in 0..<size {
            cr[k] = xr[k] * yr[k] + xi[k] * yi[k]
            ci[k] = xr[k] * yi[k] - xi[k] * yr[k]
        }
        fft.transform(real: &cr, imag: &ci, inverse: true)

        let limit = Int(min(maxLag, Int64(max(x.count, y.count) - 1)))
        var best: Float = 0
        var bestLag = 0
        for magnitude in 0...max(0, limit) {
            for lag in magnitude == 0 ? [0] : [magnitude, -magnitude] {
                let r = cr[lag >= 0 ? lag : size + lag]
                if r > best {
                    best = r
                    bestLag = lag
                }
            }
        }
        return Int64(bestLag)
    }
}
