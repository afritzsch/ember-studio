#pragma once
// AUTO-004 (T-074): a lane's points and how the value runs between two of them.
//
// Values are normalized 0…1 (11 Model). The curve of a point shapes the segment that starts at
// it, up to the next point:
//   - linear:      v(t) = a + (b − a)·f, f = (t − ta) / (tb − ta)
//   - hold:        v(t) = a (a step at the next point)
//   - exponential: v(t) = a + (b − a)·w(f), w(f) = (e^(s·f) − 1) / (e^s − 1) with shape s, clamped
//                  to ±kMaxShape. s > 0 starts slowly and ends fast, s < 0 the other way round;
//                  |s| < kLinearShape is linear (w(f) → f as s → 0).
// Before the first point a lane holds the first value, after the last point the last value.
// Everything here is RT-safe (no allocation); AutomationPlayer evaluates it once per segment.

#include <cstdint>

#include "core/Realtime.h"
#include "time/TempoMap.h"

namespace daw {

// Wire values of AutomationPointDesc::curve (include/daw/GraphDescription.h).
enum class AutomationCurve : uint8_t { linear = 0, hold = 1, exponential = 2 };

struct AutomationPoint {
    Tick tick = 0;
    float value = 0.0f;  // normalized 0…1
    AutomationCurve curve = AutomationCurve::linear;
    float shape = 0.0f;  // exponential only
};

inline constexpr float kMaxShape = 50.0f;
inline constexpr float kLinearShape = 1e-4f;

// The normalized value at `tick` of the segment from `a` to `b` (a.tick <= tick < b.tick, the
// caller's choice of segment), shaped by a's curve. Clamped to 0…1.
float interpolate(const AutomationPoint& a, const AutomationPoint& b, Tick tick) DAW_RT;

} // namespace daw
