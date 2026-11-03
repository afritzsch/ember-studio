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

// Gain change in dB (≤ 0) for detector level `x` dB. `ratio` ≥ 1, `knee` ≥ 0.
inline double compressorGainDb(double x, double threshold, double ratio, double knee) DAW_RT {
    const double over = x - threshold;
    if (2.0 * over <= -knee) return 0.0;
    const double slope = 1.0 / ratio - 1.0;  // ≤ 0
    if (2.0 * over < knee) {
        const double d = over + knee / 2.0;
        return slope * d * d / (2.0 * knee);
    }
    return slope * over;
}

} // namespace daw
