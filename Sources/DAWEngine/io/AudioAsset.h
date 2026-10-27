#pragma once
// Decoded audio in RAM (D-10, 04-audio-io-devices IO-031/032).
//
//   AudioAsset        the POD view from the 04 Interfaces contract. Nodes read samples through it.
//   SharedAudioAsset  owns the samples and the view. Immutable once built, intrusively ref-counted.
//   AudioAssetRef     smart handle: copying retains, destroying releases.
//   AudioAssetBuilder the only way to write samples; finish() freezes them into a SharedAudioAsset.
//
// IO-032: the last release never frees directly. It hands the asset to a RetireHook, which the
// engine points at its RetireQueue (ENG-014) so the samples are freed on daw.reclaim, never on
// daw.audio. retain() and release() are DAW_RT, so a snapshot may drop a reference anywhere.

#include "core/Realtime.h"
#include "core/Result.h"

#include <atomic>
#include <cstddef>
#include <cstdint>

namespace daw {

// 04 Interfaces (contract). Non-interleaved float32 at `sampleRate` (the session rate, IO-031).
// data[c][i] is frame i of channel c; every channel has `frames` samples.
struct AudioAsset {
    uint64_t assetID;
    double sampleRate;
    uint32_t channels;
    int64_t frames;
    const float* const* data;
};

class SharedAudioAsset;

// IO-032: where a SharedAudioAsset goes when its last reference is released. `fn` runs on the
// releasing thread, which may be daw.audio, so it is DAW_RT (the type system enforces it) and
// must only enqueue. Whoever drains the queue calls SharedAudioAsset::destroy off the audio thread.
struct RetireHook {
    using Fn = void (*)(void* context, const SharedAudioAsset* asset) DAW_RT;
    Fn fn = nullptr;
    void* context = nullptr;

    // Frees on the releasing thread. Only for assets that are never released on daw.audio:
    // tests, tools, and assets no snapshot references. In Debug the RT trap flags misuse.
    static RetireHook immediate();
};

class SharedAudioAsset {
public:
    SharedAudioAsset(const SharedAudioAsset&) = delete;
    SharedAudioAsset& operator=(const SharedAudioAsset&) = delete;

    const AudioAsset& view() const DAW_RT { return view_; }

    void retain() const DAW_RT;
    // The release that drops the count to zero calls the RetireHook (IO-032).
    void release() const DAW_RT;
    // Diagnostics and tests; racy by nature while other threads hold references.
    uint32_t useCount() const DAW_RT { return refs_.load(std::memory_order_relaxed); }

    // Non-RT. Frees an asset whose count reached zero. Called by the RetireHook's consumer.
    static void destroy(const SharedAudioAsset* asset);

private:
    friend class AudioAssetBuilder;
    SharedAudioAsset(AudioAsset view, float* samples, const float** channels, RetireHook hook);
    ~SharedAudioAsset();

    AudioAsset view_;
    float* samples_;         // one aligned block, channel-major
    const float** channels_; // view_.data
    RetireHook hook_;
    mutable std::atomic<uint32_t> refs_{1};
};

// Owning handle. Moves are free; copies retain. Not thread-safe per handle (like shared_ptr):
// threads share an asset by holding their own handles.
class AudioAssetRef {
public:
    AudioAssetRef() = default;
    // Adopts one reference the caller already owns (no retain).
    static AudioAssetRef adopt(const SharedAudioAsset* asset) DAW_RT {
        AudioAssetRef ref;
        ref.asset_ = asset;
        return ref;
    }

    AudioAssetRef(const AudioAssetRef& other) DAW_RT : asset_(other.asset_) {
        if (asset_) asset_->retain();
    }
    AudioAssetRef(AudioAssetRef&& other) DAW_RT : asset_(other.asset_) { other.asset_ = nullptr; }
    AudioAssetRef& operator=(AudioAssetRef other) DAW_RT {
        const SharedAudioAsset* old = asset_;
        asset_ = other.asset_;
        other.asset_ = old;
        return *this;
    }
    ~AudioAssetRef() DAW_RT { reset(); }

    void reset() DAW_RT {
        if (asset_) asset_->release();
        asset_ = nullptr;
    }

    // Gives up ownership of one reference without releasing it (pairs with adopt()).
    const SharedAudioAsset* detach() DAW_RT {
        const SharedAudioAsset* asset = asset_;
        asset_ = nullptr;
        return asset;
    }

    const SharedAudioAsset* shared() const DAW_RT { return asset_; }
    const AudioAsset* get() const DAW_RT { return asset_ ? &asset_->view() : nullptr; }
    const AudioAsset* operator->() const DAW_RT { return &asset_->view(); }
    const AudioAsset& operator*() const DAW_RT { return asset_->view(); }
    explicit operator bool() const DAW_RT { return asset_ != nullptr; }

private:
    const SharedAudioAsset* asset_ = nullptr;
};

// Non-RT. Allocates the sample storage up front, lets the loader write it, then freezes it.
// Once finish() returns, nothing can write the samples again (IO-032: immutable).
class AudioAssetBuilder {
public:
    static Result<AudioAssetBuilder> make(uint32_t channels, int64_t capacityFrames);

    AudioAssetBuilder(AudioAssetBuilder&& other) noexcept;
    AudioAssetBuilder& operator=(AudioAssetBuilder&& other) noexcept;
    AudioAssetBuilder(const AudioAssetBuilder&) = delete;
    AudioAssetBuilder& operator=(const AudioAssetBuilder&) = delete;
    ~AudioAssetBuilder();

    uint32_t channels() const { return channels_; }
    int64_t capacity() const { return capacity_; }
    float* channel(uint32_t c) { return samples_ + static_cast<size_t>(c) * stride_; }

    // Grows the storage to at least `frames`, keeping what was written. For decoders whose
    // length estimate was low (VBR MP3, for example).
    Result<void> reserve(int64_t frames);

    // Freezes the first `frames` frames (≤ capacity) into an asset with one reference.
    // The builder is empty afterwards.
    Result<AudioAssetRef> finish(uint64_t assetID, double sampleRate, int64_t frames,
                                 RetireHook hook);

private:
    AudioAssetBuilder() = default;
    void free();

    float* samples_ = nullptr;
    const float** channelPtrs_ = nullptr;
    uint32_t channels_ = 0;
    int64_t capacity_ = 0;
    size_t stride_ = 0; // floats between channel starts (capacity rounded up to a cache line)
};

} // namespace daw
