// T-010: AudioAsset, SharedAudioAsset, AudioAssetRef, AudioAssetBuilder (IO-032).

#include "AudioFileChecks.h"

#include "core/RtTrap.h"
#include "core/SpscQueue.h"
#include "io/AudioAsset.h"

#include <memory>
#include <thread>
#include <type_traits>
#include <vector>

namespace daw::testing {

namespace {

// IO-032: the RetireHook the engine will point at RetireQueue (ENG-014), stood in for here by
// an SpscQueue the test drains like daw.reclaim would.
struct RetireQueueStub {
    SpscQueue<const SharedAudioAsset*, 64> queue;
    std::atomic<int> retired{0};

    static void push(void* context, const SharedAudioAsset* asset) DAW_RT {
        auto* self = static_cast<RetireQueueStub*>(context);
        self->retired.fetch_add(1, std::memory_order_relaxed);
        DAW_RT_ASSERT(self->queue.push(asset));
    }
    RetireHook hook() { return RetireHook{&push, this}; }

    int drain() {
        int n = 0;
        for (const SharedAudioAsset* asset = nullptr; queue.pop(asset); ++n) SharedAudioAsset::destroy(asset);
        return n;
    }
};

Result<AudioAssetRef> makeAsset(uint64_t id, uint32_t channels, int64_t frames, RetireHook hook) {
    Result<AudioAssetBuilder> builder = AudioAssetBuilder::make(channels, frames);
    if (!builder) return builder.error();
    for (uint32_t c = 0; c < channels; ++c)
        for (int64_t i = 0; i < frames; ++i) builder->channel(c)[i] = static_cast<float>(c * 1000 + i);
    return builder->finish(id, 48000, frames, hook);
}

// What a snapshot does on daw.audio: take extra references, read, drop them, and finally drop
// the one it owned. The compiler checks this body as DAW_RT.
float exerciseRefs(AudioAssetRef& owned) DAW_RT {
    float sum = 0;
    for (int i = 0; i < 100; ++i) {
        AudioAssetRef copy = owned;                 // retain
        AudioAssetRef moved = static_cast<AudioAssetRef&&>(copy);
        const AudioAsset& a = *moved;
        sum += a.data[a.channels - 1][a.frames - 1];
        moved = owned;                              // retain + release
    }                                               // releases
    owned.reset();                                  // the last release → RetireHook
    return sum;
}

} // namespace

CheckResult assetContractLayout() {
    CheckResult checks;
    // 04 Interfaces: exactly these fields, in this order, as a plain struct.
    static_assert(std::is_standard_layout_v<AudioAsset> && std::is_trivially_copyable_v<AudioAsset>);
    static_assert(std::is_same_v<decltype(AudioAsset::assetID), uint64_t>);
    static_assert(std::is_same_v<decltype(AudioAsset::sampleRate), double>);
    static_assert(std::is_same_v<decltype(AudioAsset::channels), uint32_t>);
    static_assert(std::is_same_v<decltype(AudioAsset::frames), int64_t>);
    static_assert(std::is_same_v<decltype(AudioAsset::data), const float* const*>);
    static_assert(offsetof(AudioAsset, assetID) < offsetof(AudioAsset, sampleRate) &&
                  offsetof(AudioAsset, sampleRate) < offsetof(AudioAsset, channels) &&
                  offsetof(AudioAsset, channels) < offsetof(AudioAsset, frames) &&
                  offsetof(AudioAsset, frames) < offsetof(AudioAsset, data));
    // IO-032 immutable: only const access to the view, and the shared object can't be copied.
    static_assert(std::is_same_v<decltype(std::declval<const SharedAudioAsset&>().view()), const AudioAsset&>);
    static_assert(std::is_same_v<decltype(*std::declval<AudioAssetRef&>()), const AudioAsset&>);
    static_assert(!std::is_copy_constructible_v<SharedAudioAsset> && !std::is_copy_assignable_v<SharedAudioAsset>);
    static_assert(!std::is_copy_constructible_v<AudioAssetBuilder>);

    Result<AudioAssetRef> asset = makeAsset(7, 3, 1000, RetireHook::immediate());
    DAW_CHECK(asset.ok());
    if (!asset) return checks;
    const AudioAsset& a = **asset;
    DAW_CHECK(a.assetID == 7 && a.sampleRate == 48000 && a.channels == 3 && a.frames == 1000);
    for (uint32_t c = 0; c < 3; ++c) {
        // Channels are separate, cache-line aligned and hold what the builder wrote.
        DAW_CHECK(reinterpret_cast<uintptr_t>(a.data[c]) % kCacheLineSize == 0);
        DAW_CHECK(a.data[c][0] == static_cast<float>(c * 1000) && a.data[c][999] == static_cast<float>(c * 1000 + 999));
        if (c > 0) DAW_CHECK(a.data[c] >= a.data[c - 1] + 1000);
    }
    return checks;
}

CheckResult assetRefCounting() {
    CheckResult checks;
    RetireQueueStub reclaim;
    Result<AudioAssetRef> made = makeAsset(1, 1, 16, reclaim.hook());
    DAW_CHECK(made.ok());
    if (!made) return checks;
    AudioAssetRef a = std::move(made).value();
    const SharedAudioAsset* shared = a.shared();
    DAW_CHECK(shared->useCount() == 1);
    {
        AudioAssetRef b = a;
        DAW_CHECK(shared->useCount() == 2 && b.shared() == shared);
        AudioAssetRef c = std::move(b);
        DAW_CHECK(shared->useCount() == 2 && !b && c.shared() == shared);
        AudioAssetRef d;
        d = c;
        DAW_CHECK(shared->useCount() == 3);
        d = AudioAssetRef();
        DAW_CHECK(shared->useCount() == 2 && !d && d.get() == nullptr);
    }
    DAW_CHECK(shared->useCount() == 1);
    // detach/adopt hand one reference across, e.g. through a queue, without touching the count.
    AudioAssetRef adopted = AudioAssetRef::adopt(a.detach());
    DAW_CHECK(!a && shared->useCount() == 1 && adopted.shared() == shared);
    DAW_CHECK(reclaim.retired.load() == 0);
    adopted.reset();
    DAW_CHECK(reclaim.retired.load() == 1);
    DAW_CHECK(reclaim.drain() == 1);
    return checks;
}

CheckResult assetRetireThroughHook() {
    CheckResult checks;
    RetireQueueStub reclaim;
    Result<AudioAssetRef> made = makeAsset(2, 2, 4096, reclaim.hook());
    DAW_CHECK(made.ok());
    if (!made) return checks;
    AudioAssetRef owned = std::move(made).value();
    const SharedAudioAsset* shared = owned.shared();
    AudioAssetRef keep = owned;
    {
        RtScope scope;
        (void)exerciseRefs(owned);
    }
    // Not the last reference yet: nothing retired, the samples still readable.
    DAW_CHECK(reclaim.retired.load() == 0 && keep->data[1][4095] == 1000.0f + 4095);
    {
        RtScope scope;
        keep.reset();
    }
    // The last release went to the hook, not to free(): the asset waits in the queue until the
    // reclaim side destroys it.
    DAW_CHECK(reclaim.retired.load() == 1);
    const SharedAudioAsset* queued = nullptr;
    DAW_CHECK(reclaim.queue.pop(queued) && queued == shared);
    if (queued) SharedAudioAsset::destroy(queued);
    return checks;
}

uint64_t assetRetainReleaseViolations() {
    RetireQueueStub reclaim;
    Result<AudioAssetRef> made = makeAsset(3, 2, 512, reclaim.hook());
    if (!made) return UINT64_MAX;
    AudioAssetRef owned = std::move(made).value();
    uint64_t violations;
    {
        // DW-019: this scope's own count.
        RtScope scope;
        volatile float sink = exerciseRefs(owned);
        (void)sink;
        violations = scope.violations();
    }
    // The last release happened in the scope; freeing happens out here, as on daw.reclaim.
    if (reclaim.drain() != 1) return UINT64_MAX;
    return violations;
}

CheckResult assetConcurrentRelease() {
    CheckResult checks;
    RetireQueueStub reclaim;
    Result<AudioAssetRef> made = makeAsset(4, 1, 64, reclaim.hook());
    DAW_CHECK(made.ok());
    if (!made) return checks;
    AudioAssetRef owned = std::move(made).value();
    std::atomic<bool> go{false};
    std::vector<std::thread> threads;
    for (int t = 0; t < 8; ++t) {
        threads.emplace_back([&go, mine = owned]() mutable {
            while (!go.load()) {}
            for (int i = 0; i < 20'000; ++i) {
                AudioAssetRef copy = mine;
                copy.reset();
            }
            mine.reset();
        });
    }
    owned.reset();
    go = true;
    for (std::thread& t : threads) t.join();
    // Whichever thread dropped the count to zero retired it, exactly once.
    DAW_CHECK(reclaim.retired.load() == 1);
    DAW_CHECK(reclaim.drain() == 1);
    return checks;
}

CheckResult assetBuilder() {
    CheckResult checks;
    DAW_CHECK(!AudioAssetBuilder::make(0, 10).ok());
    DAW_CHECK(!AudioAssetBuilder::make(1, -1).ok());

    Result<AudioAssetBuilder> made = AudioAssetBuilder::make(2, 100);
    DAW_CHECK(made.ok());
    if (!made) return checks;
    AudioAssetBuilder builder = std::move(made).value();
    for (int i = 0; i < 100; ++i) {
        builder.channel(0)[i] = static_cast<float>(i);
        builder.channel(1)[i] = static_cast<float>(-i);
    }
    // reserve() grows and keeps what was written.
    DAW_CHECK(builder.reserve(50).ok() && builder.capacity() == 100);
    DAW_CHECK(builder.reserve(1000).ok() && builder.capacity() >= 1000);
    DAW_CHECK(builder.channel(0)[99] == 99.0f && builder.channel(1)[99] == -99.0f);

    DAW_CHECK(!builder.finish(1, 48000, builder.capacity() + 1, RetireHook::immediate()).ok());
    DAW_CHECK(!builder.finish(1, 0, 10, RetireHook::immediate()).ok());
    DAW_CHECK(!builder.finish(1, 48000, 10, RetireHook{}).ok());

    // finish() may keep fewer frames than were reserved; the builder is spent afterwards.
    Result<AudioAssetRef> asset = builder.finish(9, 44100, 100, RetireHook::immediate());
    DAW_CHECK(asset.ok());
    if (asset) DAW_CHECK((*asset)->frames == 100 && (*asset)->data[1][42] == -42.0f);
    DAW_CHECK(builder.capacity() == 0 && !builder.finish(9, 44100, 0, RetireHook::immediate()).ok());

    // A zero-length asset is valid (an empty file).
    Result<AudioAssetBuilder> empty = AudioAssetBuilder::make(1, 0);
    DAW_CHECK(empty.ok());
    if (empty) {
        Result<AudioAssetRef> e = empty->finish(10, 48000, 0, RetireHook::immediate());
        DAW_CHECK(e.ok() && (*e)->frames == 0 && (*e)->data[0] != nullptr);
    }
    return checks;
}

} // namespace daw::testing
