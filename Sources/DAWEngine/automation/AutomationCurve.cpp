#include "automation/AutomationCurve.h"

#include <cmath>

namespace daw {

namespace {

float clamp01(float v) DAW_RT {
    // NaN fails both comparisons and becomes 0.
    return v >= 0.0f ? (v <= 1.0f ? v : 1.0f) : 0.0f;
}

} // namespace

float interpolate(const AutomationPoint& a, const AutomationPoint& b, Tick tick) DAW_RT {
    const float from = clamp01(a.value);
    if (a.curve == AutomationCurve::hold || b.tick <= a.tick || tick <= a.tick) return from;
    const float to = clamp01(b.value);
    if (tick >= b.tick) return to;
    // Ticks fit a double exactly (timeline ≤ 2^40, 07), so f is exact up to one rounding.
    const double f = static_cast<double>(tick - a.tick) / static_cast<double>(b.tick - a.tick);
    double w = f;
    if (a.curve == AutomationCurve::exponential) {
        double s = a.shape;
        if (!(s >= -kMaxShape)) s = -kMaxShape;  // NaN too
        if (s > kMaxShape) s = kMaxShape;
        if (std::fabs(s) >= kLinearShape) w = std::expm1(s * f) / std::expm1(s);
    }
    return clamp01(static_cast<float>(from + (static_cast<double>(to) - from) * w));
}

} // namespace daw
