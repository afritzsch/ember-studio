#pragma once
// MIX-005: the −3 dB constant-power pan law. pan −1 … 1 maps to θ = (pan + 1)·π/4, and the
// channel gains are cos θ (left) and sin θ (right), so gL² + gR² = 1 at every position: hard
// left is (1, 0), centre is (√½, √½) ≈ −3.01 dB on each side, hard right is (0, 1).
//
// The strip is stereo throughout (MIX-004), so each gain scales its own input channel. A mono
// source (duplicated to L/R at the clip player) panned to centre therefore comes out 3 dB down
// per channel, which is what the law is for.

#include <cmath>
#include <numbers>

#include "core/Realtime.h"

namespace daw {

struct PanGains {
    float left;
    float right;
};

inline PanGains constantPowerPan(float pan) DAW_RT {
    // Out-of-range (or NaN) slot values are clamped rather than trusted.
    const float p = pan >= -1.0f ? (pan <= 1.0f ? pan : 1.0f) : -1.0f;
    const double theta = (static_cast<double>(p) + 1.0) * (std::numbers::pi / 4.0);
    // Exact at the ends and the centre, so the levels the MIX-005 golden checks don't depend on
    // libm rounding.
    if (p == -1.0f) return {1.0f, 0.0f};
    if (p == 1.0f) return {0.0f, 1.0f};
    if (p == 0.0f) return {static_cast<float>(std::numbers::sqrt2 / 2), static_cast<float>(std::numbers::sqrt2 / 2)};
    return {static_cast<float>(std::cos(theta)), static_cast<float>(std::sin(theta))};
}

} // namespace daw
