#pragma once
// Non-owning view of non-interleaved float32 audio (ENG-003): `numChannels` channel pointers,
// each valid for `numFrames` samples. A default-constructed view is empty (e.g. no sidechain).

#include <cstdint>

#include "core/Realtime.h"

namespace daw {

struct AudioBufferView {
    float* const* channels = nullptr;
    uint32_t numChannels = 0;
    uint32_t numFrames = 0;

    bool empty() const DAW_RT { return numChannels == 0 || numFrames == 0; }

    float* channel(uint32_t index) const DAW_RT {
        DAW_RT_ASSERT(index < numChannels);
        return channels[index];
    }
};

} // namespace daw
