// T-010: IO-032 wired to T-004's reclaim mechanism (ENG-012..014). An AudioAsset referenced from
// the audio thread is never freed there: a node drops its reference with AudioAssetRef::retire
// into Engine::retireQueue(), and references held by graphs and pooled nodes die on daw.reclaim.

#include "AudioFileChecks.h"

#include "core/AudioBufferPool.h"
#include "core/Engine.h"
#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ProcessContext.h"
#include "core/RenderGraph.h"
#include "core/RetireQueue.h"
#include "core/RtTrap.h"
#include "io/AudioAsset.h"

#include <pthread.h>

#include <atomic>
#include <chrono>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace daw::testing {

namespace {

using namespace std::chrono_literals;

constexpr uint32_t kBlock = 64;
constexpr PrepareInfo kPrepare{48000.0, kBlock, 0, 2};

template <class F>
bool eventually(F done, std::chrono::milliseconds timeout = 5000ms) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (!done()) {
        if (std::chrono::steady_clock::now() > deadline) return false;
        std::this_thread::sleep_for(1ms);
    }
    return true;
}

// Records which thread ran the RetireHook, then frees: stands in for RetireHook::immediate()
// so the test can see that a graph-held reference dies on daw.reclaim.
struct HookRecord {
    std::atomic<int> calls{0};
    char thread[64] = {};
};

void recordAndDestroy(void* context, const SharedAudioAsset* asset) DAW_RT {
    auto* record = static_cast<HookRecord*>(context);
    // Test-only: naming the thread and freeing aren't RT-safe, which is fine here because this
    // hook only ever runs off the audio thread (that is what the test checks).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
    pthread_getname_np(pthread_self(), record->thread, sizeof(record->thread));
    SharedAudioAsset::destroy(asset);
#pragma clang diagnostic pop
    record->calls.fetch_add(1, std::memory_order_release);
}

AudioAssetRef makeAsset(uint64_t id, float value, RetireHook hook) {
    Result<AudioAssetBuilder> builder = AudioAssetBuilder::make(2, 1024);
    for (uint32_t c = 0; c < 2; ++c) std::fill(builder->channel(c), builder->channel(c) + 1024, value);
    return builder->finish(id, 48000, 1024, hook).value();
}

// Plays the first sample of its asset as a constant (enough to prove it reads the samples) and,
// once asked, drops its reference the RT way.
class AssetNode final : public Node {
public:
    AssetNode(AudioAssetRef asset, RetireQueue& queue) : asset_(std::move(asset)), queue_(queue) {}

    std::atomic<bool> dropRequested{false};
    std::atomic<bool> dropped{false};

    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext&, NodeIO& io) DAW_RT override {
        const float value = asset_ ? asset_->data[0][0] : 0.0f;
        for (uint32_t c = 0; c < io.audioOut.numChannels; ++c)
            for (uint32_t f = 0; f < io.audioOut.numFrames; ++f) io.audioOut.channels[c][f] = value;
        // IO-032, ENG-014: the last reference goes to daw.reclaim, never free() here.
        if (dropRequested.load(std::memory_order_acquire) && asset_ && asset_.retire(queue_))
            dropped.store(true, std::memory_order_release);
    }

private:
    AudioAssetRef asset_;
    RetireQueue& queue_;
};

struct Output {
    std::vector<std::vector<float>> data{2, std::vector<float>(kBlock, -1.0f)};
    std::vector<float*> ptrs{data[0].data(), data[1].data()};
    RenderTarget target{AudioBufferView{ptrs.data(), 2, kBlock}, {}};
};

std::unique_ptr<RenderGraph> graphWith(std::shared_ptr<Node> node) {
    RenderGraphDesc desc;
    desc.sampleRate = kPrepare.sampleRate;
    desc.maxBlock = kBlock;
    desc.buffers = AudioBufferPool::create(1, 2, kBlock).value();
    RenderStepDesc step;
    step.node = std::move(node);
    step.output = 0;
    desc.steps.push_back(std::move(step));
    desc.master = 0;
    return RenderGraph::create(std::move(desc)).value();
}

// Renders one block inside this thread's own RtScope (DW-019) and returns its violations.
uint64_t renderBlock(Engine& engine, Output& out) {
    RtScope scope;
    engine.render(out.target, kBlock);
    return scope.violations();
}

} // namespace

CheckResult assetRetiredOnReclaim() {
    CheckResult checks;
    Engine engine;
    HookRecord hook;
    AudioAssetRef model = makeAsset(1, 0.5f, RetireHook{&recordAndDestroy, &hook});
    auto shared = engine.nodes().put(1, std::make_unique<AssetNode>(model, engine.retireQueue()), kPrepare);
    DAW_CHECK(shared.ok());
    if (!shared) return checks;
    auto* node = static_cast<AssetNode*>(shared->get());
    engine.publish(graphWith(*shared));

    Output out;
    DAW_CHECK(renderBlock(engine, out) == 0);
    DAW_CHECK(out.data[0][0] == 0.5f && out.data[1][kBlock - 1] == 0.5f);

    // The model lets go first, so the node's reference is the last one.
    model.reset();
    DAW_CHECK(hook.calls.load() == 0);
    const uint64_t freedBefore = engine.reclaimer().rtObjectsFreed();
    node->dropRequested = true;
    DAW_CHECK(renderBlock(engine, out) == 0); // no free() on the audio thread
    DAW_CHECK(node->dropped.load());
    // daw.reclaim deleted it from the RetireQueue; the hook was bypassed.
    DAW_CHECK(eventually([&] { return engine.reclaimer().rtObjectsFreed() == freedBefore + 1; }));
    DAW_CHECK(hook.calls.load() == 0);
    DAW_CHECK(renderBlock(engine, out) == 0);
    DAW_CHECK(out.data[0][0] == 0.0f);
    return checks;
}

CheckResult assetRetireNotLast() {
    CheckResult checks;
    Engine engine;
    HookRecord hook;
    AudioAssetRef model = makeAsset(2, 0.25f, RetireHook{&recordAndDestroy, &hook});
    auto shared = engine.nodes().put(1, std::make_unique<AssetNode>(model, engine.retireQueue()), kPrepare);
    DAW_CHECK(shared.ok());
    if (!shared) return checks;
    auto* node = static_cast<AssetNode*>(shared->get());
    engine.publish(graphWith(*shared));
    DAW_CHECK(model.shared()->useCount() == 2);

    node->dropRequested = true;
    Output out;
    DAW_CHECK(renderBlock(engine, out) == 0);
    DAW_CHECK(node->dropped.load());
    // Only the count dropped: nothing queued, and the model's handle still reads the samples.
    const uint64_t passes = engine.reclaimer().passes();
    DAW_CHECK(eventually([&] { return engine.reclaimer().passes() >= passes + 3; }));
    DAW_CHECK(engine.reclaimer().rtObjectsFreed() == 0);
    DAW_CHECK(model.shared()->useCount() == 1 && model->data[1][1023] == 0.25f);

    // Off the audio thread, the last release goes to the hook on the releasing thread.
    model.reset();
    DAW_CHECK(hook.calls.load() == 1);
    return checks;
}

CheckResult assetGraphReferenceDiesOnReclaim() {
    CheckResult checks;
    HookRecord hook;
    {
        Engine engine;
        AudioAssetRef model = makeAsset(3, 0.75f, RetireHook{&recordAndDestroy, &hook});
        auto shared = engine.nodes().put(1, std::make_unique<AssetNode>(model, engine.retireQueue()), kPrepare);
        DAW_CHECK(shared.ok());
        if (!shared) return checks;
        engine.publish(graphWith(std::move(*shared)));
        Output out;
        DAW_CHECK(renderBlock(engine, out) == 0);

        // The model and the pool let go; the published graph still holds the node, so the asset
        // stays alive and playable.
        model.reset();
        DAW_CHECK(engine.nodes().remove(1));
        DAW_CHECK(renderBlock(engine, out) == 0);
        DAW_CHECK(out.data[0][0] == 0.75f && hook.calls.load() == 0);

        // Unpublishing retires the graph; daw.reclaim destroys it, the node, and the last asset
        // reference, so the hook runs there and never on the audio thread.
        engine.publish(nullptr);
        DAW_CHECK(renderBlock(engine, out) == 0);
        DAW_CHECK(eventually([&] { return hook.calls.load(std::memory_order_acquire) == 1; }));
    }
    DAW_CHECK(hook.calls.load() == 1);
    DAW_CHECK(std::string(hook.thread) == "daw.reclaim");
    return checks;
}

CheckResult assetRetireQueueFull() {
    CheckResult checks;
    // A standalone queue that nothing drains, filled to capacity.
    auto queue = std::make_unique<RetireQueue>();
    for (size_t i = 0; i < RetireQueue::kCapacity; ++i) DAW_CHECK(queue->retire(new int(0)));

    HookRecord hook;
    AudioAssetRef ref = makeAsset(4, 1.0f, RetireHook{&recordAndDestroy, &hook});
    const SharedAudioAsset* shared = ref.shared();
    {
        RtScope scope;
        // Full: the handle keeps its reference (RetireQueue contract: retry on a later block).
        DAW_CHECK(!ref.retire(*queue));
        DAW_CHECK(scope.violations() == 0);
    }
    DAW_CHECK(ref && ref.shared() == shared && shared->useCount() == 1 && ref->data[0][0] == 1.0f);

    RetireQueue::Item item;
    DAW_CHECK(queue->pop(item));
    item.destroy(item.object);
    {
        RtScope scope;
        DAW_CHECK(ref.retire(*queue));
        DAW_CHECK(scope.violations() == 0);
    }
    DAW_CHECK(!ref && hook.calls.load() == 0);

    // What daw.reclaim does: the asset is the last item, deleted through the queue.
    size_t drained = 0;
    while (queue->pop(item)) {
        item.destroy(item.object);
        ++drained;
    }
    DAW_CHECK(drained == RetireQueue::kCapacity);
    DAW_CHECK(hook.calls.load() == 0);
    return checks;
}

} // namespace daw::testing
