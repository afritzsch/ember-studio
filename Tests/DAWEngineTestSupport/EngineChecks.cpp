// T-004 checks for the node API, RenderGraph, Engine, reclaim, NodePool and FTZ. Run from
// Tests/DAWEngineTests/EngineTests.swift; see EngineChecks.h for why they're C++.

#include "EngineChecks.h"

#include <atomic>
#include <bit>
#include <chrono>
#include <cstdint>
#include <memory>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <pthread.h>

#include "core/AudioBufferPool.h"
#include "core/Denormals.h"
#include "core/Engine.h"
#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/ProcessContext.h"
#include "core/Realtime.h"
#include "core/RenderGraph.h"
#include "core/RtTrap.h"

using namespace daw;
using namespace std::chrono_literals;

namespace daw::testing {

namespace {

// MARK: Harness

constexpr PrepareInfo kInfo{48000.0, kMaxBlock, 2, 2};

std::string currentThreadName() {
    char name[64] = {};
    pthread_getname_np(pthread_self(), name, sizeof name);
    return name;
}

// Polls `done` until it holds or `timeout` passes.
template <class F>
bool eventually(F done, std::chrono::milliseconds timeout = 5000ms) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (!done()) {
        if (std::chrono::steady_clock::now() > deadline) return false;
        std::this_thread::sleep_for(1ms);
    }
    return true;
}

// Waits until daw.reclaim has made `n` more passes than when called.
bool reclaimPasses(const Engine& engine, uint64_t n) {
    const uint64_t start = engine.reclaimer().passes();
    return eventually([&] { return engine.reclaimer().passes() >= start + n; });
}

// Owns the channel memory a RenderTarget points at.
struct TargetBuffers {
    TargetBuffers(uint32_t channels, uint32_t frames, float fill = 0.0f)
        : data(channels, std::vector<float>(frames, fill)) {
        for (auto& channel : data) ptrs.push_back(channel.data());
        target.output = AudioBufferView{ptrs.data(), channels, frames};
    }
    TargetBuffers(const TargetBuffers&) = delete;
    TargetBuffers& operator=(const TargetBuffers&) = delete;

    void fill(float value) {
        for (auto& channel : data) std::fill(channel.begin(), channel.end(), value);
    }
    // Frames [from, to) of `channel` all equal `value`.
    bool equals(uint32_t channel, uint32_t from, uint32_t to, float value) const {
        for (uint32_t f = from; f < to; ++f)
            if (data[channel][f] != value) return false;
        return true;
    }
    bool allEqual(uint32_t frames, float value) const {
        for (uint32_t c = 0; c < data.size(); ++c)
            if (!equals(c, 0, frames, value)) return false;
        return true;
    }

    std::vector<std::vector<float>> data;
    std::vector<float*> ptrs;
    RenderTarget target;
};

// One render inside the caller's own RtScope; returns what that scope counted (DW-019).
uint64_t renderCounted(Engine& engine, RenderTarget& target, uint32_t numFrames) {
    RtScope scope;
    engine.render(target, numFrames);
    return scope.violations();
}

RenderStepDesc step(std::shared_ptr<Node> node, uint32_t output, std::vector<uint32_t> inputs = {},
                    uint32_t gather = kNoBuffer, std::vector<uint32_t> sidechain = {},
                    uint32_t sidechainGather = kNoBuffer) {
    RenderStepDesc s;
    s.node = std::move(node);
    s.output = output;
    s.input = {std::move(inputs), gather};
    s.sidechain = {std::move(sidechain), sidechainGather};
    return s;
}

// A graph over `numBuffers` stereo buffers; null if create() rejects it.
std::unique_ptr<RenderGraph> makeGraph(std::vector<RenderStepDesc> steps, uint32_t numBuffers,
                                       uint32_t master, uint32_t maxBlock = kMaxBlock,
                                       double sampleRate = 48000.0) {
    RenderGraphDesc desc;
    desc.sampleRate = sampleRate;
    desc.maxBlock = maxBlock;
    desc.buffers = std::move(AudioBufferPool::create(numBuffers, 2, maxBlock)).value();
    desc.steps = std::move(steps);
    desc.master = master;
    auto graph = RenderGraph::create(std::move(desc));
    return graph ? std::move(graph).value() : nullptr;
}

// Puts `node` in the pool under `id` (prepared with `info`) and returns the shared instance.
std::shared_ptr<Node> put(Engine& engine, NodeID id, std::unique_ptr<Node> node,
                          const PrepareInfo& info = kInfo) {
    auto result = engine.nodes().put(id, std::move(node), info);
    return result ? std::move(result).value() : nullptr;
}

// MARK: Test nodes (TEST-004 style; test builds only)

void fill(const AudioBufferView& view, float value) DAW_RT {
    for (uint32_t c = 0; c < view.numChannels; ++c)
        for (uint32_t f = 0; f < view.numFrames; ++f) view.channels[c][f] = value;
}

// What happened to a node, readable from the test thread.
struct Lifecycle {
    std::atomic<int> prepares{0}, processes{0}, resets{0}, releases{0}, destroys{0};
    std::atomic<bool> releasedBeforeDestroy{true};
    std::atomic<uint32_t> lastFrames{0};
    std::atomic<double> lastSampleRate{0};
    std::atomic<uint32_t> order{0};  // `clock` value when it last processed

    std::mutex mutex;
    PrepareInfo prepared{};
    std::string destroyThread;
};

class TestNode : public Node {
public:
    explicit TestNode(std::shared_ptr<Lifecycle> life = nullptr, std::atomic<uint32_t>* clock = nullptr)
        : life_(std::move(life)), lifeRT_(life_.get()), clock_(clock) {}

    ~TestNode() override {
        if (!life_) return;
        if (life_->releases.load() == 0) life_->releasedBeforeDestroy = false;
        {
            std::lock_guard lock(life_->mutex);
            life_->destroyThread = currentThreadName();
        }
        life_->destroys.fetch_add(1);
    }

    void prepare(const PrepareInfo& info) override {
        latency_ = info.maxBlock / 4;  // ENG-002: depends on prepare
        if (!life_) return;
        {
            std::lock_guard lock(life_->mutex);
            life_->prepared = info;
        }
        life_->prepares.fetch_add(1);
    }
    void release() override {
        if (life_) life_->releases.fetch_add(1);
    }
    void reset() DAW_RT override {
        if (lifeRT_) lifeRT_->resets.fetch_add(1, std::memory_order_relaxed);
    }
    uint32_t latencySamples() const override { return latency_; }

    void process(ProcessContext& ctx, NodeIO& io) DAW_RT final {
        if (lifeRT_) {
            lifeRT_->processes.fetch_add(1, std::memory_order_relaxed);
            lifeRT_->lastFrames.store(ctx.numFrames, std::memory_order_relaxed);
            lifeRT_->lastSampleRate.store(ctx.sampleRate, std::memory_order_relaxed);
            if (clock_) lifeRT_->order.store(clock_->fetch_add(1) + 1, std::memory_order_relaxed);
        }
        render(ctx, io);
    }

protected:
    virtual void render(ProcessContext& ctx, NodeIO& io) DAW_RT = 0;

private:
    std::shared_ptr<Lifecycle> life_;
    Lifecycle* lifeRT_;  // RT code touches the plain pointer, not the shared_ptr
    std::atomic<uint32_t>* clock_;
    uint32_t latency_ = 0;
};

// Writes `value` to every output frame.
class ConstSource final : public TestNode {
public:
    explicit ConstSource(float value, std::shared_ptr<Lifecycle> life = nullptr,
                         std::atomic<uint32_t>* clock = nullptr)
        : TestNode(std::move(life), clock), value_(value) {}

protected:
    void render(ProcessContext&, NodeIO& io) DAW_RT override { fill(io.audioOut, value_); }

private:
    float value_;
};

// Writes a running frame counter (the same on every channel), so gaps and repeats show.
class CounterSource final : public TestNode {
public:
    using TestNode::TestNode;

protected:
    void render(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        for (uint32_t c = 0; c < io.audioOut.numChannels; ++c)
            for (uint32_t f = 0; f < ctx.numFrames; ++f)
                io.audioOut.channels[c][f] = static_cast<float>(next_ + f);
        next_ += ctx.numFrames;
    }

private:
    uint32_t next_ = 0;
};

// out = in * gain; silence on channels without input. Remembers the first input sample.
class Gain final : public TestNode {
public:
    explicit Gain(float gain, std::shared_ptr<Lifecycle> life = nullptr,
                  std::atomic<uint32_t>* clock = nullptr)
        : TestNode(std::move(life), clock), gain_(gain) {}

    float firstInput = -1.0f;

protected:
    void render(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        if (!io.audioIn.empty()) firstInput = io.audioIn.channels[0][0];
        for (uint32_t c = 0; c < io.audioOut.numChannels; ++c)
            for (uint32_t f = 0; f < ctx.numFrames; ++f)
                io.audioOut.channels[c][f] =
                    c < io.audioIn.numChannels ? io.audioIn.channels[c][f] * gain_ : 0.0f;
    }

private:
    float gain_;
};

// Records the shape of the NodeIO it was handed (ENG-003) and passes its input through.
class IOProbe final : public TestNode {
public:
    using TestNode::TestNode;

    uint32_t inChannels = 99, inFrames = 99, outChannels = 99, outFrames = 99;
    uint32_t sidechainChannels = 99, sidechainFrames = 99;
    float inSample = -1, sidechainSample = -1;
    std::size_t midiInSize = 99;
    uint32_t midiOutCapacity = 99;
    bool midiOutPushed = true;

protected:
    void render(ProcessContext&, NodeIO& io) DAW_RT override {
        inChannels = io.audioIn.numChannels;
        inFrames = io.audioIn.numFrames;
        outChannels = io.audioOut.numChannels;
        outFrames = io.audioOut.numFrames;
        sidechainChannels = io.sidechain.numChannels;
        sidechainFrames = io.sidechain.numFrames;
        if (!io.audioIn.empty()) inSample = io.audioIn.channels[1][io.audioIn.numFrames - 1];
        if (!io.sidechain.empty()) sidechainSample = io.sidechain.channels[0][0];
        midiInSize = io.midiIn.size();
        midiOutCapacity = io.midiOut.capacity();
        midiOutPushed = io.midiOut.push(MidiEvent{0, 3, {0x90, 60, 100}});
        fill(io.audioOut, 0.0f);
    }
};

// Blocks inside process() until released: an artificially stalled audio thread (ENG-012).
struct StallControl {
    std::atomic<bool> hold{true};
    std::atomic<bool> entered{false};
};

class StallNode final : public TestNode {
public:
    StallNode(StallControl& control, std::shared_ptr<Lifecycle> life)
        : TestNode(std::move(life)), control_(control) {}

protected:
    void render(ProcessContext&, NodeIO&) DAW_RT override {
        control_.entered.store(true, std::memory_order_release);
        // Bounded (CONV-RT-04), though the test releases it long before the bound.
        for (uint64_t i = 0; i < (uint64_t{1} << 36) && control_.hold.load(std::memory_order_acquire);
             ++i)
            __builtin_arm_yield();
    }

private:
    StallControl& control_;
};

// y[n] = x[n] + a·y[n-1], fed one impulse: the tail decays into the subnormal range (ENG-042).
class DecayingIir final : public TestNode {
public:
    using TestNode::TestNode;

    float y = 0.0f;
    bool sawSubnormal = false;
    bool flushActive = false;

protected:
    void render(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        flushActive = ScopedFlushDenormals::active();
        for (uint32_t f = 0; f < ctx.numFrames; ++f) {
            const float x = impulse_ ? 1.0f : 0.0f;
            impulse_ = false;
            y = x + a_ * y;
            const uint32_t bits = std::bit_cast<uint32_t>(y);
            if ((bits & 0x7f800000u) == 0 && (bits & 0x007fffffu) != 0) sawSubnormal = true;
            for (uint32_t c = 0; c < io.audioOut.numChannels; ++c) io.audioOut.channels[c][f] = y;
        }
    }

private:
    float a_ = 0.5f;  // a member, so the compiler can't fold the recursion
    bool impulse_ = true;
};

// A heap object that notes where it was destroyed.
struct DestroyRecord {
    std::atomic<bool> destroyed{false};
    std::mutex mutex;
    std::string thread;
};

struct Tracked {
    explicit Tracked(DestroyRecord& record) : record(record) {}
    ~Tracked() {
        {
            std::lock_guard lock(record.mutex);
            record.thread = currentThreadName();
        }
        record.destroyed = true;
    }
    DestroyRecord& record;
};

// Hands `object` to the RetireQueue from process() (ENG-014).
class RetiringNode final : public TestNode {
public:
    RetiringNode(RetireQueue& queue, Tracked* object) : queue_(queue), object_(object) {}
    ~RetiringNode() override { delete object_; }  // only if never retired

    bool retired = false;

protected:
    void render(ProcessContext&, NodeIO& io) DAW_RT override {
        if (object_ && queue_.retire(object_)) {
            object_ = nullptr;
            retired = true;
        }
        fill(io.audioOut, 0.0f);
    }

private:
    RetireQueue& queue_;
    Tracked* object_;
};

} // namespace

// MARK: Node API

CheckResult nodeLifecycle() {
    CheckResult checks;
    auto life = std::make_shared<Lifecycle>();
    Engine engine;
    const PrepareInfo info{44100.0, 512, 1, 2};

    Node* node = nullptr;
    {
        auto shared = put(engine, 7, std::make_unique<ConstSource>(0.5f, life), info);
        DAW_CHECK(shared != nullptr);
        node = shared.get();
        // ENG-013: prepared before anything can publish it.
        DAW_CHECK(life->prepares == 1);
        {
            std::lock_guard lock(life->mutex);
            DAW_CHECK(life->prepared.sampleRate == 44100.0 && life->prepared.maxBlock == 512 &&
                      life->prepared.numIn == 1 && life->prepared.numOut == 2);
        }
        DAW_CHECK(engine.nodes().get(7) == shared);
        DAW_CHECK(engine.nodes().size() == 1);
        // ENG-002: readable off the audio thread, set by prepare().
        DAW_CHECK(node->latencySamples() == 128);
        engine.publish(makeGraph({step(shared, 0)}, 1, 0, 512, 44100.0));
    }

    TargetBuffers out(2, 512);
    DAW_CHECK(renderCounted(engine, out.target, 300) == 0);
    DAW_CHECK(life->processes == 1);
    DAW_CHECK(life->lastFrames == 300);
    DAW_CHECK(life->lastSampleRate == 44100.0);
    DAW_CHECK(out.allEqual(300, 0.5f));

    node->reset();
    DAW_CHECK(life->resets == 1);

    // Bad prepare info and null nodes are rejected without preparing anything.
    DAW_CHECK(!engine.nodes().put(8, nullptr, info).ok());
    DAW_CHECK(!engine.nodes().put(8, std::make_unique<ConstSource>(0.0f), {48000.0, 0, 2, 2}).ok());
    DAW_CHECK(!engine.nodes().put(8, std::make_unique<ConstSource>(0.0f), {48000.0, kMaxBlock + 1, 2, 2}).ok());
    DAW_CHECK(!engine.nodes().put(8, std::make_unique<ConstSource>(0.0f), {0.0, 512, 2, 2}).ok());

    // ENG-013: removed from the pool, but the published graph still uses it.
    DAW_CHECK(engine.nodes().remove(7));
    DAW_CHECK(!engine.nodes().remove(7));
    DAW_CHECK(engine.nodes().get(7) == nullptr);
    DAW_CHECK(reclaimPasses(engine, 3));
    DAW_CHECK(life->destroys == 0 && life->releases == 0);

    // Unpublishing frees the graph, the graph's reference was the last: release(), then
    // destruction, both on daw.reclaim.
    engine.publish(nullptr);
    DAW_CHECK(eventually([&] { return life->destroys == 1; }));
    DAW_CHECK(life->releases == 1);
    DAW_CHECK(life->releasedBeforeDestroy);
    std::lock_guard lock(life->mutex);
    DAW_CHECK(life->destroyThread == "daw.reclaim");
    return checks;
}

CheckResult nodeReplacedOnlyAfterGraphsReleaseIt() {
    CheckResult checks;
    auto oldLife = std::make_shared<Lifecycle>();
    auto newLife = std::make_shared<Lifecycle>();
    Engine engine;
    TargetBuffers out(2, 64);

    engine.publish(makeGraph({step(put(engine, 1, std::make_unique<ConstSource>(0.25f, oldLife)), 0)}, 1, 0));
    DAW_CHECK(renderCounted(engine, out.target, 64) == 0);
    DAW_CHECK(out.allEqual(64, 0.25f));

    // A config change: a new, prepared instance under the same ID. The old one stays alive while
    // the published graph references it.
    auto replacement = put(engine, 1, std::make_unique<ConstSource>(0.75f, newLife));
    DAW_CHECK(newLife->prepares == 1);
    DAW_CHECK(engine.nodes().get(1) == replacement);
    DAW_CHECK(reclaimPasses(engine, 3));
    DAW_CHECK(oldLife->destroys == 0);
    DAW_CHECK(renderCounted(engine, out.target, 64) == 0);
    DAW_CHECK(out.allEqual(64, 0.25f));

    engine.publish(makeGraph({step(std::move(replacement), 0)}, 1, 0));
    DAW_CHECK(renderCounted(engine, out.target, 64) == 0);
    DAW_CHECK(out.allEqual(64, 0.75f));
    DAW_CHECK(eventually([&] { return oldLife->destroys == 1; }));
    DAW_CHECK(oldLife->releases == 1 && oldLife->releasedBeforeDestroy);
    DAW_CHECK(newLife->destroys == 0 && newLife->releases == 0);
    {
        std::lock_guard lock(oldLife->mutex);
        DAW_CHECK(oldLife->destroyThread == "daw.reclaim");
    }
    return checks;
}

CheckResult nodeIOViews() {
    CheckResult checks;
    Engine engine;
    auto probe = std::make_unique<IOProbe>();
    IOProbe* withInputs = probe.get();
    auto source = std::make_unique<IOProbe>();
    IOProbe* withoutInputs = source.get();

    // Buffers: 0 = A, 1 = B, 2 = probe input (A + B), 3 = probe sidechain (B), 4 = probe out,
    // 5 = output of the input-less probe.
    engine.publish(makeGraph(
        {
            step(put(engine, 1, std::make_unique<ConstSource>(0.25f)), 0),
            step(put(engine, 2, std::make_unique<ConstSource>(0.5f)), 1),
            step(put(engine, 3, std::move(source)), 5),
            step(put(engine, 4, std::move(probe)), 4, {0, 1}, 2, {1}, 3),
        },
        6, 4));

    TargetBuffers out(2, 256);
    DAW_CHECK(renderCounted(engine, out.target, 200) == 0);

    DAW_CHECK(withInputs->inChannels == 2 && withInputs->inFrames == 200);
    DAW_CHECK(withInputs->outChannels == 2 && withInputs->outFrames == 200);
    DAW_CHECK(withInputs->inSample == 0.75f);  // MIX-004: summed
    DAW_CHECK(withInputs->sidechainChannels == 2 && withInputs->sidechainFrames == 200);
    DAW_CHECK(withInputs->sidechainSample == 0.5f);

    DAW_CHECK(withoutInputs->inChannels == 0);
    DAW_CHECK(withoutInputs->sidechainChannels == 0);
    DAW_CHECK(withoutInputs->outChannels == 2 && withoutInputs->outFrames == 200);

    // MIDI isn't routed by the graph yet: nothing comes in, nothing can be written.
    DAW_CHECK(withInputs->midiInSize == 0);
    DAW_CHECK(withInputs->midiOutCapacity == 0);
    DAW_CHECK(!withInputs->midiOutPushed);
    return checks;
}

CheckResult midiEventWriter() {
    CheckResult checks;
    MidiEvent storage[4] = {};
    MidiEventWriter writer(storage, 4);
    DAW_CHECK(writer.capacity() == 4 && writer.size() == 0 && writer.written().empty());
    for (uint8_t i = 0; i < 4; ++i) DAW_CHECK(writer.push(MidiEvent{i, 3, {0x90, uint8_t(60 + i), 100}}));
    DAW_CHECK(!writer.push(MidiEvent{9, 1, {0xF8, 0, 0}}));  // full: dropped
    DAW_CHECK(writer.size() == 4);
    MidiEventSpan written = writer.written();
    DAW_CHECK(written.size() == 4);
    for (uint32_t i = 0; i < 4; ++i)
        DAW_CHECK(written[i].frameOffset == i && written[i].data[1] == 60 + i);
    writer.clear();
    DAW_CHECK(writer.size() == 0);
    DAW_CHECK(writer.push(MidiEvent{0, 1, {0xF8, 0, 0}}));

    MidiEventWriter none;
    DAW_CHECK(none.capacity() == 0 && !none.push(MidiEvent{}));
    return checks;
}

CheckResult randomBlockSizes() {
    CheckResult checks;
    auto life = std::make_shared<Lifecycle>();
    Engine engine;
    engine.publish(makeGraph(
        {
            step(put(engine, 1, std::make_unique<CounterSource>(life)), 0),
            step(put(engine, 2, std::make_unique<Gain>(1.0f)), 2, {0}, 1),
        },
        3, 2));

    std::mt19937 rng(0xE4C004);
    std::uniform_int_distribution<uint32_t> size(0, kMaxBlock);
    std::vector<uint32_t> sizes = {0, 1, kMaxBlock, 0, 7};
    for (int i = 0; i < 2000; ++i) sizes.push_back(size(rng));

    // One spare frame, so writes past numFrames show up.
    TargetBuffers out(2, kMaxBlock + 1);
    uint64_t violations = 0;
    uint32_t expected = 0;
    int badBlocks = 0;
    for (uint32_t n : sizes) {
        out.fill(-1.0f);
        violations += renderCounted(engine, out.target, n);
        DAW_CHECK(life->lastFrames == n);
        for (uint32_t c = 0; c < 2; ++c) {
            for (uint32_t f = 0; f < n; ++f)
                if (out.data[c][f] != static_cast<float>(expected + f)) {
                    ++badBlocks;
                    break;
                }
            if (!out.equals(c, n, kMaxBlock + 1, -1.0f)) ++badBlocks;
        }
        expected += n;
    }
    DAW_CHECK(badBlocks == 0);
    DAW_CHECK(violations == 0);
    DAW_CHECK(life->processes == static_cast<int>(sizes.size()));
    DAW_CHECK(engine.blocksRendered() == sizes.size());

    // Larger than the graph's maxBlock: silence, and the nodes don't run.
    const int processes = life->processes;
    out.fill(-1.0f);
    DAW_CHECK(renderCounted(engine, out.target, kMaxBlock + 1) == 0);
    DAW_CHECK(out.allEqual(kMaxBlock + 1, 0.0f));
    DAW_CHECK(life->processes == processes);

    // numFrames beyond the target is clamped to the target (ASan would catch an overrun).
    TargetBuffers small(2, 64, -1.0f);
    DAW_CHECK(renderCounted(engine, small.target, 128) == 0);
    DAW_CHECK(life->lastFrames == 64);
    DAW_CHECK(small.equals(0, 0, 1, static_cast<float>(expected)));
    return checks;
}

// MARK: Snapshots

CheckResult publishWhileRendering() {
    CheckResult checks;
    constexpr int kPublishes = 10'000;
    constexpr uint32_t kFrames = 256;
    auto gains = std::make_shared<Lifecycle>();
    auto sourceLife = std::make_shared<Lifecycle>();
    {
        Engine engine;
        auto source = put(engine, 1, std::make_unique<ConstSource>(0.25f, sourceLife));
        auto graphWithGain = [&](int i) {
            auto gain = put(engine, 2, std::make_unique<Gain>(float(1 + i % 4), gains));
            return makeGraph({step(source, 0), step(std::move(gain), 2, {0}, 1)}, 3, 2, kFrames);
        };
        engine.publish(graphWithGain(0));

        std::atomic<bool> stop{false};
        std::atomic<uint64_t> blocks{0}, badBlocks{0}, violations{0};
        std::thread audio([&] {
            TargetBuffers out(2, kFrames);
            RtScope scope;
            while (!stop.load(std::memory_order_relaxed)) {
                engine.render(out.target, kFrames);
                // ENG-011: one graph per block, so every frame of a block has the same gain.
                const float v = out.data[0][0];
                const bool known = v == 0.25f || v == 0.5f || v == 0.75f || v == 1.0f;
                if (!known || !out.allEqual(kFrames, v)) badBlocks.fetch_add(1);
                blocks.fetch_add(1, std::memory_order_relaxed);
            }
            violations = scope.violations();
        });

        DAW_CHECK(eventually([&] { return blocks.load() > 0; }));
        const uint64_t blocksBefore = blocks.load();
        for (int i = 1; i <= kPublishes; ++i) engine.publish(graphWithGain(i));
        const uint64_t blocksDuring = blocks.load() - blocksBefore;
        stop = true;
        audio.join();

        DAW_CHECK(blocksDuring > 0);
        DAW_CHECK(badBlocks == 0);
        DAW_CHECK(violations == 0);

        // Every replaced graph is freed, and with it every replaced gain node.
        engine.publish(nullptr);
        DAW_CHECK(eventually([&] { return engine.reclaimer().graphsFreed() == kPublishes + 1; }));
        DAW_CHECK(engine.reclaimer().pendingGraphs() == 0);
        DAW_CHECK(eventually([&] { return gains->destroys == kPublishes; }));  // all but the pooled one
        DAW_CHECK(sourceLife->destroys == 0);
    }
    // ~Engine frees the rest on daw.reclaim.
    DAW_CHECK(gains->destroys == kPublishes + 1);
    DAW_CHECK(gains->releases == kPublishes + 1);
    DAW_CHECK(sourceLife->destroys == 1);
    std::lock_guard lock(sourceLife->mutex);
    DAW_CHECK(sourceLife->destroyThread == "daw.reclaim");
    return checks;
}

CheckResult stalledRenderKeepsGraphAlive() {
    CheckResult checks;
    constexpr int kLaterGraphs = 100;
    auto stalledLife = std::make_shared<Lifecycle>();
    Engine engine;
    StallControl stall;

    // G1: a node that stalls, then one that writes 0.25 to the master.
    engine.publish(makeGraph(
        {
            step(put(engine, 1, std::make_unique<StallNode>(stall, stalledLife)), kNoBuffer),
            step(put(engine, 2, std::make_unique<ConstSource>(0.25f, stalledLife)), 0),
        },
        1, 0));

    float stalledBlockValue = -1;
    uint64_t violations = 99;
    std::thread audio([&] {
        TargetBuffers out(2, 128);
        violations = renderCounted(engine, out.target, 128);
        stalledBlockValue = out.data[0][0];
    });
    DAW_CHECK(eventually([&] { return stall.entered.load(); }));

    // While the block is stuck inside G1: drop G1's nodes from the pool and publish many newer
    // graphs. The reclaimer keeps running but must free none of them, G1 above all.
    const uint64_t freedBefore = engine.reclaimer().graphsFreed();
    engine.nodes().remove(1);
    engine.nodes().remove(2);
    for (int i = 0; i < kLaterGraphs; ++i)
        engine.publish(makeGraph({step(put(engine, 3, std::make_unique<ConstSource>(0.5f)), 0)}, 1, 0));
    DAW_CHECK(reclaimPasses(engine, 5));
    DAW_CHECK(engine.reclaimer().graphsFreed() == freedBefore);
    DAW_CHECK(engine.reclaimer().pendingGraphs() == kLaterGraphs);  // G1 and all but the current one
    DAW_CHECK(stalledLife->destroys == 0 && stalledLife->releases == 0);

    stall.hold = false;
    audio.join();
    // ENG-011: the block finished with the graph it started with.
    DAW_CHECK(stalledBlockValue == 0.25f);
    DAW_CHECK(violations == 0);

    // The block ended, so everything retired during it can go now; G1's nodes die with it.
    DAW_CHECK(eventually([&] { return engine.reclaimer().graphsFreed() == freedBefore + kLaterGraphs; }));
    DAW_CHECK(eventually([&] { return stalledLife->destroys == 2; }));
    DAW_CHECK(stalledLife->releases == 2);
    {
        std::lock_guard lock(stalledLife->mutex);
        DAW_CHECK(stalledLife->destroyThread == "daw.reclaim");
    }

    TargetBuffers out(2, 128);
    DAW_CHECK(renderCounted(engine, out.target, 128) == 0);
    DAW_CHECK(out.allEqual(128, 0.5f));
    return checks;
}

CheckResult idleEngineFreesReplacedGraphs() {
    CheckResult checks;
    Engine engine;
    auto source = put(engine, 1, std::make_unique<ConstSource>(0.5f));
    for (int i = 0; i < 50; ++i) engine.publish(makeGraph({step(source, 0)}, 1, 0));
    DAW_CHECK(eventually([&] { return engine.reclaimer().graphsFreed() == 49; }));

    TargetBuffers out(2, 64);
    DAW_CHECK(renderCounted(engine, out.target, 64) == 0);
    for (int i = 0; i < 50; ++i) engine.publish(makeGraph({step(source, 0)}, 1, 0));
    DAW_CHECK(eventually([&] { return engine.reclaimer().graphsFreed() == 99; }));
    DAW_CHECK(engine.reclaimer().pendingGraphs() == 0);
    return checks;
}

CheckResult rtRetireQueue() {
    CheckResult checks;
    DestroyRecord record;
    Engine engine;
    auto node = std::make_unique<RetiringNode>(engine.retireQueue(), new Tracked(record));
    RetiringNode* retiring = node.get();
    engine.publish(makeGraph({step(put(engine, 1, std::move(node)), 0)}, 1, 0));

    TargetBuffers out(2, 64);
    {
        RtScope scope;
        engine.render(out.target, 64);
        DAW_CHECK(scope.violations(RtViolationKind::deallocation) == 0);
        DAW_CHECK(scope.violations() == 0);
    }
    DAW_CHECK(retiring->retired);
    DAW_CHECK(eventually([&] { return record.destroyed.load(); }));
    DAW_CHECK(engine.reclaimer().rtObjectsFreed() == 1);
    std::lock_guard lock(record.mutex);
    DAW_CHECK(record.thread == "daw.reclaim");
    return checks;
}

CheckResult silenceWithoutGraph() {
    CheckResult checks;
    Engine engine;
    TargetBuffers out(2, 256, 1.0f);

    // ENG-015
    DAW_CHECK(engine.blocksRendered() == 0);
    DAW_CHECK(renderCounted(engine, out.target, 256) == 0);
    DAW_CHECK(out.allEqual(256, 0.0f));
    DAW_CHECK(engine.blocksRendered() == 1);

    // ENG-040/041: a stereo master into a 3-channel target; the extra channel is silent.
    engine.publish(makeGraph({step(put(engine, 1, std::make_unique<ConstSource>(0.5f)), 0)}, 1, 0));
    TargetBuffers wide(3, 256, 1.0f);
    DAW_CHECK(renderCounted(engine, wide.target, 256) == 0);
    DAW_CHECK(wide.equals(0, 0, 256, 0.5f) && wide.equals(1, 0, 256, 0.5f));
    DAW_CHECK(wide.equals(2, 0, 256, 0.0f));

    // A graph without a master is silent too.
    engine.publish(makeGraph({step(engine.nodes().get(1), 0)}, 1, kNoBuffer));
    out.fill(1.0f);
    DAW_CHECK(renderCounted(engine, out.target, 256) == 0);
    DAW_CHECK(out.allEqual(256, 0.0f));

    // Unpublished again.
    engine.publish(nullptr);
    out.fill(1.0f);
    DAW_CHECK(renderCounted(engine, out.target, 256) == 0);
    DAW_CHECK(out.allEqual(256, 0.0f));
    DAW_CHECK(engine.blocksRendered() == 4);
    return checks;
}

CheckResult renderOrderAndSumming() {
    CheckResult checks;
    std::atomic<uint32_t> clock{0};
    auto a = std::make_shared<Lifecycle>();
    auto b = std::make_shared<Lifecycle>();
    auto c = std::make_shared<Lifecycle>();
    Engine engine;
    auto gainNode = std::make_unique<Gain>(2.0f, c, &clock);
    Gain* gain = gainNode.get();

    // A → 0, B → 1, (0 + 1) → gather 2 → C (×2) → 3 = master.
    engine.publish(makeGraph(
        {
            step(put(engine, 1, std::make_unique<ConstSource>(0.25f, a, &clock)), 0),
            step(put(engine, 2, std::make_unique<ConstSource>(0.5f, b, &clock)), 1),
            step(put(engine, 3, std::move(gainNode)), 3, {0, 1}, 2),
        },
        4, 3));

    TargetBuffers out(2, 128);
    for (uint64_t block = 1; block <= 3; ++block) {
        out.fill(-1.0f);
        DAW_CHECK(renderCounted(engine, out.target, 128) == 0);
        DAW_CHECK(gain->firstInput == 0.75f);  // summed afresh each block, not accumulated
        DAW_CHECK(out.allEqual(128, 1.5f));
        DAW_CHECK(engine.blocksRendered() == block);
        DAW_CHECK(a->order < b->order && b->order < c->order);
        DAW_CHECK(c->order == 3 * block);
    }
    return checks;
}

CheckResult flushDenormalsInRender() {
    CheckResult checks;
    DAW_CHECK(!ScopedFlushDenormals::active());

    // Control: outside render the IIR's tail does go subnormal, so the check below means something.
    {
        DecayingIir iir;
        iir.prepare(kInfo);
        ParamSlotTable params(16);
        TransportBlock transport{};
        std::vector<float> samples(256);
        float* channels[1] = {samples.data()};
        for (int block = 0; block < 4; ++block) {
            ProcessContext ctx{256, 48000.0, transport, params};
            NodeIO io;
            io.audioOut = AudioBufferView{channels, 1, 256};
            iir.process(ctx, io);
        }
        DAW_CHECK(iir.sawSubnormal);
        DAW_CHECK(!iir.flushActive);
    }

    Engine engine;
    auto node = std::make_unique<DecayingIir>();
    DecayingIir* iir = node.get();
    engine.publish(makeGraph({step(put(engine, 1, std::move(node)), 0)}, 1, 0));
    TargetBuffers out(2, 256);
    for (int block = 0; block < 4; ++block) DAW_CHECK(renderCounted(engine, out.target, 256) == 0);
    DAW_CHECK(iir->flushActive);
    DAW_CHECK(!iir->sawSubnormal);
    DAW_CHECK(iir->y == 0.0f);
    // The caller's float mode is restored after render…
    DAW_CHECK(!ScopedFlushDenormals::active());
    // …and left alone if it already flushed.
    {
        ScopedFlushDenormals callerFlushes;
        DAW_CHECK(renderCounted(engine, out.target, 256) == 0);
        DAW_CHECK(ScopedFlushDenormals::active());
    }
    DAW_CHECK(!ScopedFlushDenormals::active());
    return checks;
}

CheckResult renderGraphValidation() {
    CheckResult checks;
    auto node = std::shared_ptr<Node>(new ConstSource(0.0f));
    auto create = [&](std::vector<RenderStepDesc> steps, uint32_t numBuffers, uint32_t master,
                      uint32_t maxBlock = 512, uint32_t poolFrames = 512, double sampleRate = 48000.0) {
        RenderGraphDesc desc;
        desc.sampleRate = sampleRate;
        desc.maxBlock = maxBlock;
        desc.buffers = std::move(AudioBufferPool::create(numBuffers, 2, poolFrames)).value();
        desc.steps = std::move(steps);
        desc.master = master;
        return RenderGraph::create(std::move(desc));
    };

    auto ok = create({step(node, 0), step(node, 2, {0}, 1, {0}, 3)}, 4, 2);
    DAW_CHECK(ok.ok());
    if (ok) {
        const RenderGraph& graph = *ok.value();
        DAW_CHECK(graph.buffers().numBuffers() == 4);  // ENG-061: the graph owns its pool
        DAW_CHECK(graph.numSteps() == 2 && graph.node(0) == node.get());
        DAW_CHECK(graph.maxBlock() == 512 && graph.sampleRate() == 48000.0);
        DAW_CHECK(graph.master(64).numChannels == 2 && graph.master(64).numFrames == 64);
    }
    DAW_CHECK(create({}, 0, kNoBuffer).ok());  // empty graph: silence

    DAW_CHECK(!create({step(nullptr, 0)}, 1, 0).ok());                   // null node
    DAW_CHECK(!create({step(node, 1)}, 1, 0).ok());                      // output out of range
    DAW_CHECK(!create({step(node, 0)}, 1, 1).ok());                      // master out of range
    DAW_CHECK(!create({step(node, 0, {5}, 1)}, 2, 0).ok());              // source out of range
    DAW_CHECK(!create({step(node, 0, {1})}, 2, 0).ok());                 // sources but no gather buffer
    DAW_CHECK(!create({step(node, 0, {1}, 0)}, 2, 0).ok());              // gather buffer is the output
    DAW_CHECK(!create({step(node, 0, {1}, 1)}, 2, 0).ok());              // source is the gather buffer
    DAW_CHECK(!create({step(node, 0, {1}, 2, {1}, 2)}, 3, 0).ok());      // input and sidechain share
    DAW_CHECK(!create({step(node, 0, {}, 5)}, 1, 0).ok());               // unused gather out of range
    DAW_CHECK(!create({step(node, 0)}, 1, 0, 0).ok());                   // maxBlock 0
    DAW_CHECK(!create({step(node, 0)}, 1, 0, kMaxBlock + 1, kMaxBlock + 1).ok());  // ENG-004
    DAW_CHECK(!create({step(node, 0)}, 1, 0, 1024, 512).ok());           // buffers too short
    DAW_CHECK(!create({step(node, 0)}, 1, 0, 512, 512, 0.0).ok());       // sample rate
    return checks;
}

bool engineInstallsRtTrap() {
    Engine engine;
    return RtTrap::installed();
}

} // namespace daw::testing
