#pragma once
// DSP-031: the compressor's static curve (gain computer), in the log domain with a quadratic soft
// knee (Giannoulis, Massberg & Reiss, "Digital Dynamic Range Compressor Design", JAES 2012,
// eq. 4). For a detector level x (dB), threshold T (dB), ratio R (≥ 1) and knee width W (dB):
//
//   2(x − T) < −W        y = x                                       (below the knee)
//   2|x − T| ≤ W         y = x + (1/R − 1)·(x − T + W/2)² / (2W)     (inside the knee)
//   2(x − T) > W         y = T + (x − T)/R                           (above the knee)
//
// The gain is y − x ≤ 0 dB. The curve and its slope are continuous at both knee edges; W = 0 is
// the hard knee (the middle case then only holds at x = T, where both formulas give 0).

#include "core/Realtime.h"

namespace daw {

// The curve for one setting, with its per-setting terms worked out once (T-091: the compressor
// keeps one across a block whose threshold, ratio and knee don't ramp, and the knee divides by a
// precomputed reciprocal instead of per sample).
struct GainCurve {
    double threshold, knee, halfKnee, invTwoKnee, slope;

    // `ratio` ≥ 1, `knee` ≥ 0.
    GainCurve(double threshold_, double ratio, double knee_) DAW_RT
        : threshold(threshold_), knee(knee_), halfKnee(knee_ / 2.0), invTwoKnee(1.0 / (2.0 * knee_)),
          slope(1.0 / ratio - 1.0) {}  // slope ≤ 0; invTwoKnee is +Inf for the hard knee

    // Gain change in dB (≤ 0) for detector level `x` dB. Branch-free (all three pieces, then a
    // select), so a loop over a block vectorizes; with knee 0 the middle piece is Inf or NaN, but
    // it is never selected then.
    double gainDb(double x) const DAW_RT {
        const double over = x - threshold;
        const double d = over + halfKnee;
        const double inside = slope * d * d * invTwoKnee;
        const double above = slope * over;
        const double twoOver = 2.0 * over;
        return twoOver <= -knee ? 0.0 : twoOver < knee ? inside : above;
    }
};

// Gain change in dB (≤ 0) for detector level `x` dB. `ratio` ≥ 1, `knee` ≥ 0.
inline double compressorGainDb(double x, double threshold, double ratio, double knee) DAW_RT {
    return GainCurve(threshold, ratio, knee).gainDb(x);
}

} // namespace daw
