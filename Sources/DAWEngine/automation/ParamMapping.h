#pragma once
// AUTO-008 (T-074): how a lane's normalized value (0…1) becomes the value its param slot holds.
// GraphBuilder resolves one per lane from the target's range (AutomationCompiler.h):
//   - linear: min + v·(max − min)
//   - log:    min·(max/min)^v  (min, max > 0; otherwise linear)
//   - db:     the range is a linear amplitude (strip gain, send level, metronome level). With
//             min > 0, dB-linear from min to max. With min ≤ 0 (a fader that reaches silence),
//             v = 0 is min and v in (0, 1] runs dB-linear from kDbFloor to 20·log10(max): for
//             the strip's 0…+12 dB fader, v = 5/6 is unity gain.
// map() is RT-safe and clamps v to 0…1.

#include <cmath>
#include <cstdint>

#include "core/Realtime.h"
#include "dsp/ParamInfo.h"

namespace daw {

struct ParamMapping {
    enum class Scale : uint8_t { linear, log, db };

    static constexpr double kDbFloor = -60.0;

    float min = 0.0f;
    float max = 1.0f;
    Scale scale = Scale::linear;

    static ParamMapping identity() { return {}; }
    static ParamMapping from(const ParamInfo& info) {
        Scale scale = Scale::linear;
        if (info.curve == ParamInfo::Curve::log) scale = Scale::log;
        if (info.curve == ParamInfo::Curve::db) scale = Scale::db;
        return {info.min, info.max, scale};
    }

    float map(float normalized) const DAW_RT {
        // NaN fails both comparisons and becomes 0.
        const double v = normalized >= 0.0f ? (normalized <= 1.0f ? normalized : 1.0f) : 0.0f;
        const double lo = min, hi = max;
        switch (scale) {
        case Scale::log:
            if (lo > 0 && hi > 0) return static_cast<float>(lo * std::pow(hi / lo, v));
            break;
        case Scale::db:
            if (hi > 0) {
                if (lo > 0) return static_cast<float>(lo * std::pow(hi / lo, v));  // dB-linear
                if (v <= 0) return min;
                const double top = 20.0 * std::log10(hi);
                return static_cast<float>(std::pow(10.0, (kDbFloor + v * (top - kDbFloor)) / 20.0));
            }
            break;
        case Scale::linear:
            break;
        }
        return static_cast<float>(lo + v * (hi - lo));
    }
};

} // namespace daw
