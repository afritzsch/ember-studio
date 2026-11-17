#pragma once
// DSP-030: RBJ biquad designs ("Audio EQ Cookbook", R. Bristow-Johnson) and the transposed
// direct form II filter step. Coefficients are normalized by a0.
//
//   H(z) = (b0 + b1·z⁻¹ + b2·z⁻²) / (1 + a1·z⁻¹ + a2·z⁻²)
//
// `freq` must be in (0, rate/2) and `q` > 0; callers clamp them (nodes/Eq.cpp). Everything is
// double: a 20 Hz filter at 96 kHz has poles within 1e-3 of the unit circle, where float
// coefficients and state cost real accuracy and low-level noise.

#include <cmath>
#include <numbers>

#include "core/Realtime.h"

namespace daw {

struct BiquadCoeffs {
    double b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0;

    friend bool operator==(const BiquadCoeffs&, const BiquadCoeffs&) = default;

    // True when H(z) = 1 exactly: b == a term by term, which a peak or shelf at 0 dB gives (their
    // numerator and denominator come out as the same doubles). With zero state such a filter's
    // output is its input, bit for bit, and its state stays 0.
    bool isIdentity() const DAW_RT { return b0 == 1.0 && b1 == a1 && b2 == a2; }

    // this + (to − this)·t, per coefficient. DSP-030: a stable biquad's (a1, a2) lie in the
    // stability triangle, which is convex, so every filter on the line between two stable ones
    // is stable too.
    BiquadCoeffs lerp(const BiquadCoeffs& to, double t) const DAW_RT {
        return {b0 + (to.b0 - b0) * t, b1 + (to.b1 - b1) * t, b2 + (to.b2 - b2) * t, a1 + (to.a1 - a1) * t,
                a2 + (to.a2 - a2) * t};
    }
};

// Shared intermediates of every RBJ design.
struct RbjTerms {
    double cosW, alpha;

    static RbjTerms make(double freq, double q, double rate) DAW_RT {
        const double w0 = 2.0 * std::numbers::pi * freq / rate;
        return {std::cos(w0), std::sin(w0) / (2.0 * q)};
    }
};

inline BiquadCoeffs normalized(double b0, double b1, double b2, double a0, double a1, double a2) DAW_RT {
    return {b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
}

inline BiquadCoeffs biquadLowPass(double freq, double q, double rate) DAW_RT {
    const auto [c, alpha] = RbjTerms::make(freq, q, rate);
    return normalized((1.0 - c) / 2.0, 1.0 - c, (1.0 - c) / 2.0, 1.0 + alpha, -2.0 * c, 1.0 - alpha);
}

inline BiquadCoeffs biquadHighPass(double freq, double q, double rate) DAW_RT {
    const auto [c, alpha] = RbjTerms::make(freq, q, rate);
    return normalized((1.0 + c) / 2.0, -(1.0 + c), (1.0 + c) / 2.0, 1.0 + alpha, -2.0 * c, 1.0 - alpha);
}

inline BiquadCoeffs biquadPeak(double freq, double q, double gainDb, double rate) DAW_RT {
    const auto [c, alpha] = RbjTerms::make(freq, q, rate);
    const double A = std::pow(10.0, gainDb / 40.0);
    return normalized(1.0 + alpha * A, -2.0 * c, 1.0 - alpha * A, 1.0 + alpha / A, -2.0 * c, 1.0 - alpha / A);
}

inline BiquadCoeffs biquadLowShelf(double freq, double q, double gainDb, double rate) DAW_RT {
    const auto [c, alpha] = RbjTerms::make(freq, q, rate);
    const double A = std::pow(10.0, gainDb / 40.0);
    const double twoSqrtAAlpha = 2.0 * std::sqrt(A) * alpha;
    return normalized(A * ((A + 1.0) - (A - 1.0) * c + twoSqrtAAlpha), 2.0 * A * ((A - 1.0) - (A + 1.0) * c),
                      A * ((A + 1.0) - (A - 1.0) * c - twoSqrtAAlpha), (A + 1.0) + (A - 1.0) * c + twoSqrtAAlpha,
                      -2.0 * ((A - 1.0) + (A + 1.0) * c), (A + 1.0) + (A - 1.0) * c - twoSqrtAAlpha);
}

inline BiquadCoeffs biquadHighShelf(double freq, double q, double gainDb, double rate) DAW_RT {
    const auto [c, alpha] = RbjTerms::make(freq, q, rate);
    const double A = std::pow(10.0, gainDb / 40.0);
    const double twoSqrtAAlpha = 2.0 * std::sqrt(A) * alpha;
    return normalized(A * ((A + 1.0) + (A - 1.0) * c + twoSqrtAAlpha), -2.0 * A * ((A - 1.0) + (A + 1.0) * c),
                      A * ((A + 1.0) + (A - 1.0) * c - twoSqrtAAlpha), (A + 1.0) - (A - 1.0) * c + twoSqrtAAlpha,
                      2.0 * ((A - 1.0) - (A + 1.0) * c), (A + 1.0) - (A - 1.0) * c - twoSqrtAAlpha);
}

// TDF-II state of one channel of one biquad.
struct BiquadState {
    double z1 = 0.0, z2 = 0.0;

    // When both state terms are below this (−240 dBFS) they are stored as exactly 0, so silence
    // reaches exact 0 in finite time and nothing decays into denormals (DSP-040). Both together:
    // in a narrow low-frequency filter the two terms nearly cancel, and zeroing one alone
    // re-excites the filter, which then limit-cycles around 1e-9 instead of decaying.
    static constexpr double kSnap = 1e-12;

    // T-091: ordered so that y → next z1 → next y is short (the recurrence that bounds a
    // cascade's speed): y = b0·x + z1 is one fused multiply-add; then z1 = (b1·x + z2) − a1·y and
    // z2 = b2·x − a2·y, each product rounded on its own (separate statements, so nothing is
    // contracted), which keeps H(z) = 1 exact: with b = a and zero state, y = x and both
    // differences cancel to exactly 0 (BiquadCoeffs::isIdentity).
    double tick(double x, const BiquadCoeffs& c) DAW_RT {
        const double y = std::fma(c.b0, x, z1);
        const double u = c.b1 * x;
        const double v = c.b2 * x;
        const double p1 = c.a1 * y;
        const double p2 = c.a2 * y;
        const double w = u + z2;
        z1 = w - p1;
        z2 = v - p2;
        if (std::fabs(z1) < kSnap && std::fabs(z2) < kSnap) z1 = z2 = 0.0;
        return y;
    }

    bool isZero() const DAW_RT { return z1 == 0.0 && z2 == 0.0; }
};

// T-091 (TEST-008): a stereo pair of TDF-II states, left in lane 0 and right in lane 1, stepped
// together with NEON doubles. Each lane does exactly BiquadState::tick's arithmetic (the same
// fused operations) and snaps to 0 under the same condition, so the result is BiquadState::tick's,
// bit for bit, per channel.
using Double2 = double __attribute__((ext_vector_type(2)));
using Mask2 = long __attribute__((ext_vector_type(2)));

struct BiquadState2 {
    Double2 z1 = 0.0, z2 = 0.0;

    BiquadState2() = default;
    BiquadState2(const BiquadState& left, const BiquadState& right) DAW_RT
        : z1(Double2{left.z1, right.z1}), z2(Double2{left.z2, right.z2}) {}
    void store(BiquadState& left, BiquadState& right) const DAW_RT {
        left = {z1.x, z2.x};
        right = {z1.y, z2.y};
    }

    // One step without the DSP-040 snap; a caller that steps several sections may snap them
    // once per frame (see quietness() and snap()), which gives the same result as tick().
    Double2 step(Double2 x, const BiquadCoeffs& c) DAW_RT {
        const Double2 y = __builtin_elementwise_fma(Double2(c.b0), x, z1);
        const Double2 u = c.b1 * x;
        const Double2 v = c.b2 * x;
        const Double2 p1 = c.a1 * y;
        const Double2 p2 = c.a2 * y;
        const Double2 w = u + z2;
        z1 = w - p1;
        z2 = v - p2;
        return y;
    }

    // Per lane, the larger state term: a lane snaps when this is below BiquadState::kSnap.
    Double2 quietness() const DAW_RT {
        return __builtin_elementwise_max(__builtin_elementwise_abs(z1), __builtin_elementwise_abs(z2));
    }

    // DSP-040 snap, per lane: both terms below kSnap → both exactly 0. Only called on the rare
    // frames where some section may snap; the empty asm makes it recompute |z1| and |z2| here
    // instead of the compiler keeping quietness()'s values alive (spilled) on every frame.
    void snap() DAW_RT {
        __asm__ volatile("" : "+w"(z1), "+w"(z2));
        const Mask2 quiet = (__builtin_elementwise_abs(z1) < BiquadState::kSnap) &
                            (__builtin_elementwise_abs(z2) < BiquadState::kSnap);
        z1 = __builtin_bit_cast(Double2, __builtin_bit_cast(Mask2, z1) & ~quiet);
        z2 = __builtin_bit_cast(Double2, __builtin_bit_cast(Mask2, z2) & ~quiet);
    }

    // BiquadState::tick for both lanes. The snap is a branch, not a select, so it stays off the
    // y → z1 dependency chain: it is rarely taken while a signal plays and steadily taken in
    // silence, so it stays predicted. The test is the quieter lane's larger term; snap() then
    // decides each lane exactly.
    Double2 tick(Double2 x, const BiquadCoeffs& c) DAW_RT {
        const Double2 y = step(x, c);
        if (__builtin_expect(__builtin_reduce_min(quietness()) < BiquadState::kSnap, 0)) snap();
        return y;
    }
};

} // namespace daw
