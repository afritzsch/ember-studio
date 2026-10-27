#include "io/AudioAsset.h"

#include <algorithm>
#include <cstring>
#include <new>
#include <utility>

namespace daw {

namespace {

constexpr std::align_val_t kSampleAlignment{kCacheLineSize};
constexpr size_t kFloatsPerLine = kCacheLineSize / sizeof(float);

void retireImmediately(void*, const SharedAudioAsset* asset) DAW_RT {
    // RetireHook::immediate() frees on the releasing thread by definition, which the effect
    // analysis rightly rejects in a DAW_RT function. Engine-owned assets use a RetireQueue hook
    // instead; if this one ever runs inside an RtScope, the Debug RT trap reports it.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
    SharedAudioAsset::destroy(asset);
#pragma clang diagnostic pop
}

size_t strideFor(int64_t frames) {
    const size_t n = static_cast<size_t>(std::max<int64_t>(frames, 1));
    return (n + kFloatsPerLine - 1) / kFloatsPerLine * kFloatsPerLine;
}

float* allocateSamples(uint32_t channels, size_t stride) {
    if (channels == 0) return nullptr;
    if (stride > SIZE_MAX / sizeof(float) / channels) return nullptr;
    return static_cast<float*>(
        ::operator new(stride * channels * sizeof(float), kSampleAlignment, std::nothrow));
}

void freeSamples(float* samples) {
    if (samples) ::operator delete(samples, kSampleAlignment);
}

} // namespace

RetireHook RetireHook::immediate() { return RetireHook{&retireImmediately, nullptr}; }

// MARK: SharedAudioAsset

SharedAudioAsset::SharedAudioAsset(AudioAsset view, float* samples, const float** channels,
                                   RetireHook hook)
    : view_(view), samples_(samples), channels_(channels), hook_(hook) {}

SharedAudioAsset::~SharedAudioAsset() {
    freeSamples(samples_);
    delete[] channels_;
}

void SharedAudioAsset::retain() const DAW_RT {
    // Relaxed, as in shared_ptr: a new reference can only come from an existing one.
    refs_.fetch_add(1, std::memory_order_relaxed);
}

void SharedAudioAsset::release() const DAW_RT {
    // acq_rel: every holder's reads of the samples happen before the retire hook sees the asset.
    if (refs_.fetch_sub(1, std::memory_order_acq_rel) == 1) hook_.fn(hook_.context, this);
}

void SharedAudioAsset::destroy(const SharedAudioAsset* asset) { delete asset; }

// MARK: AudioAssetBuilder

Result<AudioAssetBuilder> AudioAssetBuilder::make(uint32_t channels, int64_t capacityFrames) {
    if (channels == 0) return makeError(ErrorCode::invalidArgument, "audio asset needs ≥ 1 channel");
    if (capacityFrames < 0) return makeError(ErrorCode::invalidArgument, "negative frame count");

    AudioAssetBuilder builder;
    builder.channels_ = channels;
    builder.capacity_ = capacityFrames;
    builder.stride_ = strideFor(capacityFrames);
    builder.samples_ = allocateSamples(channels, builder.stride_);
    builder.channelPtrs_ = new (std::nothrow) const float*[channels];
    if (!builder.samples_ || !builder.channelPtrs_)
        return makeError(ErrorCode::outOfMemory, "audio asset allocation failed");
    return builder;
}

AudioAssetBuilder::AudioAssetBuilder(AudioAssetBuilder&& other) noexcept
    : samples_(std::exchange(other.samples_, nullptr)),
      channelPtrs_(std::exchange(other.channelPtrs_, nullptr)),
      channels_(std::exchange(other.channels_, 0)), capacity_(std::exchange(other.capacity_, 0)),
      stride_(std::exchange(other.stride_, 0)) {}

AudioAssetBuilder& AudioAssetBuilder::operator=(AudioAssetBuilder&& other) noexcept {
    if (this != &other) {
        free();
        samples_ = std::exchange(other.samples_, nullptr);
        channelPtrs_ = std::exchange(other.channelPtrs_, nullptr);
        channels_ = std::exchange(other.channels_, 0);
        capacity_ = std::exchange(other.capacity_, 0);
        stride_ = std::exchange(other.stride_, 0);
    }
    return *this;
}

AudioAssetBuilder::~AudioAssetBuilder() { free(); }

void AudioAssetBuilder::free() {
    freeSamples(samples_);
    delete[] channelPtrs_;
    samples_ = nullptr;
    channelPtrs_ = nullptr;
}

Result<void> AudioAssetBuilder::reserve(int64_t frames) {
    if (frames <= capacity_) return {};
    if (!samples_) return makeError(ErrorCode::invalidArgument, "builder already finished");
    // Grow geometrically so repeated low estimates stay linear overall.
    const int64_t newCapacity = std::max(frames, capacity_ + capacity_ / 2);
    const size_t newStride = strideFor(newCapacity);
    float* grown = allocateSamples(channels_, newStride);
    if (!grown) return makeError(ErrorCode::outOfMemory, "audio asset allocation failed");
    for (uint32_t c = 0; c < channels_; ++c)
        std::memcpy(grown + c * newStride, samples_ + c * stride_,
                    static_cast<size_t>(capacity_) * sizeof(float));
    freeSamples(samples_);
    samples_ = grown;
    stride_ = newStride;
    capacity_ = newCapacity;
    return {};
}

Result<AudioAssetRef> AudioAssetBuilder::finish(uint64_t assetID, double sampleRate, int64_t frames,
                                                RetireHook hook) {
    if (!samples_) return makeError(ErrorCode::invalidArgument, "builder already finished");
    if (frames < 0 || frames > capacity_)
        return makeError(ErrorCode::invalidArgument, "frame count exceeds builder capacity");
    if (!(sampleRate > 0)) return makeError(ErrorCode::invalidArgument, "sample rate must be > 0");
    if (!hook.fn) return makeError(ErrorCode::invalidArgument, "audio asset needs a retire hook");

    for (uint32_t c = 0; c < channels_; ++c) channelPtrs_[c] = channel(c);
    const AudioAsset view{assetID, sampleRate, channels_, frames, channelPtrs_};
    auto* asset = new (std::nothrow) SharedAudioAsset(view, samples_, channelPtrs_, hook);
    if (!asset) return makeError(ErrorCode::outOfMemory, "audio asset allocation failed");
    samples_ = nullptr; // now owned by the asset
    channelPtrs_ = nullptr;
    channels_ = 0;
    capacity_ = 0;
    stride_ = 0;
    return AudioAssetRef::adopt(asset);
}

} // namespace daw
