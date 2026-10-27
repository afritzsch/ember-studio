#pragma once
// Copies a node's (already summed) input to its output; channels the input lacks are silent.
// Shared by the routing nodes that do nothing but carry a sum on (bus, master).

#include <cstddef>
#include <cstring>

#include "core/NodeIO.h"
#include "core/Realtime.h"

namespace daw {

inline void passThrough(const NodeIO& io) DAW_RT {
    const AudioBufferView& in = io.audioIn;
    const AudioBufferView& out = io.audioOut;
    const std::size_t bytes = std::size_t{out.numFrames} * sizeof(float);
    for (uint32_t c = 0; c < out.numChannels; ++c) {
        if (c < in.numChannels && in.numFrames >= out.numFrames)
            std::memcpy(out.channels[c], in.channels[c], bytes);
        else
            std::memset(out.channels[c], 0, bytes);
    }
}

} // namespace daw
