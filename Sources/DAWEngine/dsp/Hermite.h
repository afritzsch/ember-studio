#pragma once
// DSP-021: 4-point, 3rd-order Hermite interpolation (Catmull-Rom tangents), the Sampler's
// resampler. Reads between x0 and x1 at fraction t ∈ [0, 1) with the neighbours xm1 and x2
// shaping the curve. It passes through the samples (t = 0 gives x0 exactly), so rate 1 plays a
// sample bit-exact, and its first derivative is continuous across sample boundaries.

#include "core/Realtime.h"

namespace daw {

inline float hermite4(float xm1, float x0, float x1, float x2, float t) DAW_RT {
    const float c1 = 0.5f * (x1 - xm1);
    const float c2 = xm1 - 2.5f * x0 + 2.0f * x1 - 0.5f * x2;
    const float c3 = 0.5f * (x2 - xm1) + 1.5f * (x0 - x1);
    return ((c3 * t + c2) * t + c1) * t + x0;
}

} // namespace daw
