#include "io/DeviceRenderer.h"

#include <algorithm>
#include <cstring>

#include "core/Engine.h"
#include "core/Node.h"
#include "core/RenderTarget.h"
#include "core/Telemetry.h"
#include "io/InputCapture.h"

namespace daw {

void DeviceRenderer::configure(uint32_t maxBlock, double sampleRate) {
    maxBlock_ = std::clamp<uint32_t>(maxBlock, 1, kMaxBlock);
    nanosPerFrame_ = sampleRate > 0 ? 1e9 / sampleRate : 0;
    const uint64_t grace = sampleRate > 0 ? static_cast<uint64_t>(sampleRate * kXrunGraceSeconds) : 0;
    graceEndFrame_.store(frames() + grace, std::memory_order_relaxed);
}

void DeviceRenderer::renderCycle(float* const* output, uint32_t outputChannels,
                                 float* const* input, uint32_t inputChannels,
                                 uint32_t numFrames) DAW_RT {
    const uint32_t outCh = outputChannels < kMaxDeviceChannels ? outputChannels : kMaxDeviceChannels;
    const uint32_t inCh = inputChannels < kMaxDeviceChannels ? inputChannels : kMaxDeviceChannels;
    for (uint32_t c = outCh; c < outputChannels; ++c)
        std::memset(output[c], 0, std::size_t{numFrames} * sizeof(float));

    const uint64_t startTicks = Telemetry::clockTicks();  // IO-023

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
        // REC-001: the recorder copies the block's input into its FIFOs.
        if (capture_ != nullptr) capture_->captureBlock(engine_.transport(), target.input, n);
        offset += n;
        ++blocks;
    }

    // IO-023, DW-068: rendering took longer than the audio it made lasts. One writer (this
    // thread) for frames_, so the grace check sees the frames before this cycle.
    if (nanosPerFrame_ > 0 &&
        frames_.load(std::memory_order_relaxed) >= graceEndFrame_.load(std::memory_order_relaxed)) {
        const uint64_t nanos = engine_.telemetry().ticksToNanos(Telemetry::clockTicks() - startTicks);
        if (static_cast<double>(nanos) > nanosPerFrame_ * numFrames) {
            overruns_.fetch_add(1, std::memory_order_relaxed);
            engine_.telemetry().countXrun();
        }
    }

    cycles_.fetch_add(1, std::memory_order_relaxed);
    frames_.fetch_add(numFrames, std::memory_order_relaxed);
    blocks_.fetch_add(blocks, std::memory_order_relaxed);
    if (numFrames > largestCycle_.load(std::memory_order_relaxed))
        largestCycle_.store(numFrames, std::memory_order_relaxed);  // one writer
}

} // namespace daw
