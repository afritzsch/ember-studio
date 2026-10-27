#pragma once
// ENG-061: the scratch audio buffers a RenderGraph renders through. GraphBuilder decides how
// many buffers a graph needs and which node uses which (MIX-003); the pool allocates them all up
// front, and the RenderGraph owns it, so it's freed on daw.reclaim with the graph. On the audio
// thread a buffer is only ever looked up by index; nothing is allocated or handed out there.

#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>

#include "AudioBufferView.h"
#include "Realtime.h"
#include "Result.h"

namespace daw {

class AudioBufferPool {
public:
    // Channel data is aligned to this, and each channel's stride is a multiple of it, so
    // channels can be processed with aligned SIMD loads.
    static constexpr std::size_t kAlignment = kCacheLineSize;

    // Non-RT. Buffer i gets channelsPerBuffer[i] channels of `maxFrames` samples, zeroed.
    static Result<AudioBufferPool> create(std::span<const uint32_t> channelsPerBuffer,
                                          uint32_t maxFrames);
    // Non-RT. `numBuffers` buffers of `numChannels` channels each.
    static Result<AudioBufferPool> create(uint32_t numBuffers, uint32_t numChannels,
                                          uint32_t maxFrames);

    AudioBufferPool() = default;  // no buffers
    // A moved-from pool has no buffers. Views into the moved pool stay valid: the storage
    // moves with it, it isn't copied.
    AudioBufferPool(AudioBufferPool&& other) noexcept;
    AudioBufferPool& operator=(AudioBufferPool&& other) noexcept;
    AudioBufferPool(const AudioBufferPool&) = delete;
    AudioBufferPool& operator=(const AudioBufferPool&) = delete;
    ~AudioBufferPool() = default;  // non-RT: frees the storage

    uint32_t numBuffers() const DAW_RT { return numBuffers_; }
    uint32_t maxFrames() const DAW_RT { return maxFrames_; }
    uint32_t numChannels(uint32_t buffer) const DAW_RT {
        DAW_RT_ASSERT(buffer < numBuffers_);
        return channelStart_[buffer + 1] - channelStart_[buffer];
    }

    // view() and clear() are const because the owning RenderGraph is immutable once published;
    // the samples themselves are scratch and always writable.
    //
    // The first `numFrames` frames of `buffer`. Requires buffer < numBuffers() and
    // numFrames <= maxFrames(). Contents persist between blocks; callers clear when needed.
    AudioBufferView view(uint32_t buffer, uint32_t numFrames) const DAW_RT;

    // Zeroes the first `numFrames` frames of every channel of `buffer`.
    void clear(uint32_t buffer, uint32_t numFrames) const DAW_RT;

private:
    struct AlignedFree {
        void operator()(float* p) const noexcept;
    };

    std::unique_ptr<float[], AlignedFree> samples_;
    std::unique_ptr<float*[]> channelPtrs_;      // one per channel, all buffers back to back
    std::unique_ptr<uint32_t[]> channelStart_;   // numBuffers_ + 1 offsets into channelPtrs_
    uint32_t numBuffers_ = 0;
    uint32_t maxFrames_ = 0;
};

} // namespace daw
