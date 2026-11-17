#pragma once
// T-091 (TEST-008): block-wise decibel conversions for the compressor (DSP-031). The compressor
// needs a log for every detector sample and an exp for every gain; libm's scalar log10/exp calls
// were most of its cost. These are plain arithmetic on doubles (no calls, no tables, no
// branches), so a loop over a block auto-vectorizes, and every element goes through the same
// operations wherever it sits in the block: results don't depend on block size or position
// (ENG-004).
//
// Accuracy: ln within 1e-12 absolute (1e-11 dB), exp within 1e-12 relative, over the whole range
// the compressor uses. A float output resolves 6e-8 relative, so the compressor's output stays
// the same as with libm except for rare last-bit roundings (dsp/FastDbTests in DAWEngineTests).
//
//   log: x = 2^e · m with m in [√½, √2); ln m = 2·atanh(s), s = (m − 1)/(m + 1), |s| < 0.172,
//        the odd series to s^13 (truncation < 5e-13).
//   exp: e^z = 2^n · e^r, n = rint(z / ln 2), r = z − n·ln 2 (Cody–Waite, two-part ln 2),
//        |r| ≤ ½ ln 2, Taylor to r^10 (truncation < 3e-13); 2^n goes into the exponent bits.

#include <bit>
#include <cmath>
#include <cstdint>
#include <numbers>

#include "core/Realtime.h"

namespace daw::fastdb {

// ln x for a positive, normal, finite x (callers floor their inputs; 0, denormals, Inf and NaN
// are not handled).
inline double ln(double x) DAW_RT {
    const uint64_t bits = std::bit_cast<uint64_t>(x);
    double e = static_cast<double>(static_cast<int64_t>(bits >> 52) - 1023);
    double m = std::bit_cast<double>((bits & 0x000F'FFFF'FFFF'FFFFull) | 0x3FF0'0000'0000'0000ull);  // [1, 2)
    const bool high = m > std::numbers::sqrt2;
    m = high ? m * 0.5 : m;
    e = high ? e + 1.0 : e;
    const double s = (m - 1.0) / (m + 1.0);
    const double s2 = s * s;
    // 2·atanh(s) = 2s · Σ s^(2k) / (2k + 1), k = 0 … 6
    double p = 1.0 / 13.0;
    p = p * s2 + 1.0 / 11.0;
    p = p * s2 + 1.0 / 9.0;
    p = p * s2 + 1.0 / 7.0;
    p = p * s2 + 1.0 / 5.0;
    p = p * s2 + 1.0 / 3.0;
    const double lnM = 2.0 * s + 2.0 * s * s2 * p;
    return e * std::numbers::ln2 + lnM;
}

// e^z for z in [−700, 700] (clamped there; the compressor's gains stay far inside).
inline double exp(double z) DAW_RT {
    constexpr double kLn2Hi = 0x1.62e42fefa3800p-1;   // ln 2, upper bits (n · kLn2Hi is exact)
    constexpr double kLn2Lo = 0x1.ef35793c76730p-45;  // ln 2 − kLn2Hi
    z = z < -700.0 ? -700.0 : z > 700.0 ? 700.0 : z;
    const double n = std::rint(z * (1.0 / std::numbers::ln2));
    const double r = (z - n * kLn2Hi) - n * kLn2Lo;
    // Taylor to r^10, Horner.
    double p = 1.0 / 3628800.0;         // 1/10!
    p = p * r + 1.0 / 362880.0;         // 1/9!
    p = p * r + 1.0 / 40320.0;          // 1/8!
    p = p * r + 1.0 / 5040.0;           // 1/7!
    p = p * r + 1.0 / 720.0;            // 1/6!
    p = p * r + 1.0 / 120.0;            // 1/5!
    p = p * r + 1.0 / 24.0;             // 1/4!
    p = p * r + 1.0 / 6.0;
    p = p * r + 0.5;
    p = p * r * r + r;                  // e^r − 1, small part first
    const double er = 1.0 + p;
    // 2^n: |n| ≤ 1010, so adding n to the exponent field of e^r (in [0.70, 1.42]) stays normal.
    const int64_t shift = static_cast<int64_t>(n) << 52;
    return std::bit_cast<double>(std::bit_cast<uint64_t>(er) + static_cast<uint64_t>(shift));
}

inline constexpr double kDbPerNeper = 20.0 / std::numbers::ln10;  // 20·log10(x) = ln(x) · this
inline constexpr double kNeperPerDb = std::numbers::ln10 / 20.0;  // 10^(x/20) = e^(x · this)

// 20·log10(x) for a positive, normal x.
inline double amplitudeToDb(double x) DAW_RT { return ln(x) * kDbPerNeper; }
// 10^(db/20).
inline double dbToAmplitude(double db) DAW_RT { return exp(db * kNeperPerDb); }

} // namespace daw::fastdb
