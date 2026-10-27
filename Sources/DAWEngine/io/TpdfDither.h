#pragma once
// IO-035: TPDF dither for 16/24-bit file output. The noise is the difference of two independent
// uniform values in [0, 1), so it is triangular over (−1, +1) LSB with variance 1/6 LSB², which
// makes the quantization error independent of the signal.
//
// IO-011: an offline render must be bit-identical across runs, so the generator is seeded and
// never touches the clock. splitmix64 is used instead of <random> because the standard
// distributions aren't specified bit for bit; this is the same on every platform and library.

#include <cstdint>

namespace daw {

// The seed AudioFileWriter uses unless the caller picks another one.
inline constexpr uint64_t kDefaultDitherSeed = 0x6d61'6344'4157'0035ull;

class TpdfDither {
public:
    explicit TpdfDither(uint64_t seed = kDefaultDitherSeed) : state_(seed) {}

    // The next noise value in LSB, in (−1, +1).
    double next() { return uniform() - uniform(); }

private:
    uint64_t nextBits() {
        uint64_t z = (state_ += 0x9e37'79b9'7f4a'7c15ull);
        z = (z ^ (z >> 30)) * 0xbf58'476d'1ce4'e5b9ull;
        z = (z ^ (z >> 27)) * 0x94d0'49bb'1331'11ebull;
        return z ^ (z >> 31);
    }
    // [0, 1) with 53 random bits, exact in a double.
    double uniform() { return static_cast<double>(nextBits() >> 11) * 0x1.0p-53; }

    uint64_t state_;
};

} // namespace daw
