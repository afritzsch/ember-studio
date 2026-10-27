#include "AudioBufferPool.h"

#include <algorithm>
#include <cstring>
#include <limits>
#include <new>
#include <string>
#include <utility>

namespace daw {

namespace {

constexpr std::size_t kFloatsPerAlignment = AudioBufferPool::kAlignment / sizeof(float);

// Upper bound on one pool's sample storage. Far beyond any real graph (a 4096-frame block is
// 16 KiB per channel); it turns a GraphBuilder bug into an error instead of a huge allocation.
constexpr uint64_t kMaxPoolBytes = uint64_t{1} << 32;

} // namespace

void AudioBufferPool::AlignedFree::operator()(float* p) const noexcept {
    ::operator delete(p, std::align_val_t{kAlignment});
}

Result<AudioBufferPool> AudioBufferPool::create(std::span<const uint32_t> channelsPerBuffer,
                                                uint32_t maxFrames) {
    if (maxFrames == 0) return makeError(ErrorCode::invalidArgument, "maxFrames must be > 0");
    if (channelsPerBuffer.size() > std::numeric_limits<uint32_t>::max() - 1)
        return makeError(ErrorCode::invalidArgument, "too many buffers");

    uint64_t totalChannels = 0;
    for (uint32_t n : channelsPerBuffer) totalChannels += n;
    if (totalChannels > std::numeric_limits<uint32_t>::max())
        return makeError(ErrorCode::invalidArgument, "too many channels");

    // Each channel starts on an alignment boundary.
    const uint64_t stride =
        (uint64_t{maxFrames} + kFloatsPerAlignment - 1) / kFloatsPerAlignment * kFloatsPerAlignment;
    const uint64_t bytes = totalChannels * stride * sizeof(float);
    if (bytes > kMaxPoolBytes)
        return makeError(ErrorCode::invalidArgument,
                         "pool of " + std::to_string(bytes) + " bytes exceeds the limit");

    AudioBufferPool pool;
    pool.numBuffers_ = static_cast<uint32_t>(channelsPerBuffer.size());
    pool.maxFrames_ = maxFrames;
    pool.channelStart_ = std::make_unique<uint32_t[]>(channelsPerBuffer.size() + 1);
    pool.channelPtrs_ = std::make_unique<float*[]>(totalChannels);
    if (bytes > 0) {
        void* raw = ::operator new(bytes, std::align_val_t{kAlignment}, std::nothrow);
        if (!raw) return makeError(ErrorCode::outOfMemory, "audio buffer pool");
        pool.samples_.reset(static_cast<float*>(raw));
        // Zeroing also touches every page now, so the audio thread doesn't take the first
        // page faults.
        std::memset(raw, 0, bytes);
    }

    uint32_t channel = 0;
    for (std::size_t b = 0; b < channelsPerBuffer.size(); ++b) {
        pool.channelStart_[b] = channel;
        for (uint32_t c = 0; c < channelsPerBuffer[b]; ++c, ++channel)
            pool.channelPtrs_[channel] = pool.samples_.get() + uint64_t{channel} * stride;
    }
    pool.channelStart_[channelsPerBuffer.size()] = channel;
    return pool;
}

Result<AudioBufferPool> AudioBufferPool::create(uint32_t numBuffers, uint32_t numChannels,
                                                uint32_t maxFrames) {
    auto counts = std::make_unique<uint32_t[]>(numBuffers);
    std::fill_n(counts.get(), numBuffers, numChannels);
    return create(std::span<const uint32_t>(counts.get(), numBuffers), maxFrames);
}

AudioBufferPool::AudioBufferPool(AudioBufferPool&& other) noexcept
    : samples_(std::move(other.samples_)),
      channelPtrs_(std::move(other.channelPtrs_)),
      channelStart_(std::move(other.channelStart_)),
      numBuffers_(std::exchange(other.numBuffers_, 0)),
      maxFrames_(std::exchange(other.maxFrames_, 0)) {}

AudioBufferPool& AudioBufferPool::operator=(AudioBufferPool&& other) noexcept {
    samples_ = std::move(other.samples_);
    channelPtrs_ = std::move(other.channelPtrs_);
    channelStart_ = std::move(other.channelStart_);
    numBuffers_ = std::exchange(other.numBuffers_, 0);
    maxFrames_ = std::exchange(other.maxFrames_, 0);
    return *this;
}

AudioBufferView AudioBufferPool::view(uint32_t buffer, uint32_t numFrames) const DAW_RT {
    DAW_RT_ASSERT(buffer < numBuffers_);
    DAW_RT_ASSERT(numFrames <= maxFrames_);
    const uint32_t first = channelStart_[buffer];
    return AudioBufferView{channelPtrs_.get() + first, channelStart_[buffer + 1] - first,
                           numFrames};
}

void AudioBufferPool::clear(uint32_t buffer, uint32_t numFrames) const DAW_RT {
    const AudioBufferView v = view(buffer, numFrames);
    for (uint32_t c = 0; c < v.numChannels; ++c)
        std::memset(v.channels[c], 0, std::size_t{numFrames} * sizeof(float));
}

} // namespace daw
