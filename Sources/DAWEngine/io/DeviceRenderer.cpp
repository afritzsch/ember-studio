#include "io/DeviceRenderer.h"

#include <algorithm>
#include <cstring>

#include "core/Engine.h"
#include "core/Node.h"
#include "core/RenderTarget.h"

namespace daw {

void DeviceRenderer::configure(uint32_t maxBlock) {
    maxBlock_ = std::clamp<uint32_t>(maxBlock, 1, kMaxBlock);
}

void DeviceRenderer::renderCycle(float* const* output, uint32_t outputChannels,
                                 float* const* input, uint32_t inputChannels,
                                 uint32_t numFrames) DAW_RT {
    const uint32_t outCh = outputChannels < kMaxDeviceChannels ? outputChannels : kMaxDeviceChannels;
    const uint32_t inCh = inputChannels < kMaxDeviceChannels ? inputChannels : kMaxDeviceChannels;
    for (uint32_t c = outCh; c < outputChannels; ++c)
        std::memset(output[c], 0, std::size_t{numFrames} * sizeof(float));

    // Per-block views into the cycle's buffers (CONV-RT-01: on the stack).
    float* outBlock[kMaxDeviceChannels];
    float* inBlock[kMaxDeviceChannels];
    uint64_t blocks = 0;
    // CONV-RT-04: bounded by numFrames / maxBlock_.
    for (uint32_t offset = 0; offset < numFrames;) {
        const uint32_t n = std::min(numFrames - offset, maxBlock_);
        for (uint32_t c = 0; c < outCh; ++c) outBlock[c] = output[c] + offset;
        for (uint32_t c = 0; c < inCh; ++c) inBlock[c] = input[c] + offset;
        RenderTarget target{AudioBufferView{outBlock, outCh, n}, AudioBufferView{inBlock, inCh, n}};
        engine_.render(target, n);
        offset += n;
        ++blocks;
    }

    cycles_.fetch_add(1, std::memory_order_relaxed);
    frames_.fetch_add(numFrames, std::memory_order_relaxed);
    blocks_.fetch_add(blocks, std::memory_order_relaxed);
    if (numFrames > largestCycle_.load(std::memory_order_relaxed))
        largestCycle_.store(numFrames, std::memory_order_relaxed);  // one writer
}

} // namespace daw
