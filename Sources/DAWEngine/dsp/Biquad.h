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

    double tick(double x, const BiquadCoeffs& c) DAW_RT {
        const double y = c.b0 * x + z1;
        z1 = c.b1 * x - c.a1 * y + z2;
        z2 = c.b2 * x - c.a2 * y;
        if (std::fabs(z1) < kSnap && std::fabs(z2) < kSnap) z1 = z2 = 0.0;
        return y;
    }

    bool isZero() const DAW_RT { return z1 == 0.0 && z2 == 0.0; }
};

} // namespace daw
