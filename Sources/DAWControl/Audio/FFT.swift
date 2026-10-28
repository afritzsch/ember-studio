import Accelerate

/// An unscaled radix-2 complex FFT over split-complex arrays (vDSP), for spectra and
/// cross-correlation. Not for real-time use.
final class FFT {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    /// `size` must be a power of two ≥ 2.
    init?(size: Int) {
        let log2n = vDSP_Length(size.trailingZeroBitCount)
        guard size >= 2, size & (size - 1) == 0, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        self.size = size
        self.log2n = log2n
        self.setup = setup
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// In place: X[k] = Σ x[n]·e^(∓2πikn/N), no scaling either way.
    func transform(real: inout [Float], imag: inout [Float], inverse: Bool = false) {
        precondition(real.count == size && imag.count == size)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(inverse ? kFFTDirection_Inverse : kFFTDirection_Forward))
            }
        }
    }

    static func nextPowerOfTwo(atLeast n: Int) -> Int {
        var size = 1
        while size < n { size <<= 1 }
        return size
    }
}
