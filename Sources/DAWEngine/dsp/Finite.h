#pragma once
// DSP-040 NaN guards: does a block hold only finite samples? T-091 (TEST-008): branch-free over the
// whole block (a float is NaN or ±Inf exactly when its exponent bits are all ones), so the loop
// vectorizes; an early-exit loop over isfinite() doesn't, and every effect runs one or two per
// block.

#include <bit>
#include <cstdint>

#include "core/NodeIO.h"
#include "core/Realtime.h"

namespace daw {

// True when samples[0 … n) are all finite.
inline bool allFinite(const float* samples, uint32_t n) DAW_RT {
    constexpr uint32_t kExponent = 0x7F80'0000u;
    uint32_t bad = 0;
    for (uint32_t i = 0; i < n; ++i) bad |= static_cast<uint32_t>((std::bit_cast<uint32_t>(samples[i]) & kExponent) == kExponent);
    return bad == 0;
}

// True when the first `n` frames of every channel of `view` are finite.
inline bool allFinite(const AudioBufferView& view, uint32_t n) DAW_RT {
    for (uint32_t c = 0; c < view.numChannels; ++c)
        if (!allFinite(view.channels[c], n)) return false;
    return true;
}

} // namespace daw
