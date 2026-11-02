#pragma once
// DSP-002: the equal-power crossfade curve for overlapping clips (06 "later clip wins"; comp
// boundaries reuse it, 09). At fraction f ∈ [0, 1] of a crossfade the incoming side plays at
// sin(f·π/2) and the outgoing side at cos(f·π/2), so the squares of the weights sum to 1 and two
// uncorrelated signals keep their power through the fade.
//
// The outgoing weight is computed as sin((1 − f)·π/2) from the integer frame counts rather than
// as a cosine, so f = 1 gives exactly (1, 0): a finished crossfade leaves no residue of the side
// that faded out.

#include <cmath>
#include <cstdint>
#include <numbers>

#include "core/Realtime.h"

namespace daw {

struct EqualPowerGains {
    float in;   // the side fading in
    float out;  // the side fading out
};

// Frame `k` (0-based) of an `n`-frame crossfade, at fraction f = (k + 1)/n: the first frame is
// already slightly in, the last one is fully in. k >= n (or n == 0) is fully in.
inline EqualPowerGains equalPowerFrame(int64_t k, int64_t n) DAW_RT {
    if (n <= 0 || k + 1 >= n) return {1.0f, 0.0f};
    constexpr double kHalfPi = std::numbers::pi / 2.0;
    const double dn = static_cast<double>(n);
    return {static_cast<float>(std::sin(kHalfPi * static_cast<double>(k + 1) / dn)),
            static_cast<float>(std::sin(kHalfPi * static_cast<double>(n - 1 - k) / dn))};
}

} // namespace daw
