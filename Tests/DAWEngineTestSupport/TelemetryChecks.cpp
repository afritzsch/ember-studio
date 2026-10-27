// T-006 checks for engine telemetry. Run from Tests/DAWEngineTests/TelemetryTests.swift; see
// TelemetryChecks.h for why they're C++.

#include "TelemetryChecks.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <memory>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <mach/mach_time.h>

#include "RtTrapTestSupport.h"
#include "core/AudioBufferPool.h"
#include "core/Engine.h"
#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ProcessContext.h"
#include "core/Realtime.h"
#include "core/RenderGraph.h"
#include "core/RetireQueue.h"
#include "core/RtTrap.h"
#include "core/Telemetry.h"

using namespace daw;
using namespace std::chrono_literals;

namespace daw::testing {

namespace {

// MARK: Harness

constexpr PrepareInfo kInfo{48000.0, kMaxBlock, 2, 2};

template <class F>
bool eventually(F done, std::chrono::milliseconds timeout = 5000ms) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (!done()) {
        if (std::chrono::steady_clock::now() > deadline) return false;
        std::this_thread::sleep_for(1ms);
    }
    return true;
}

bool near(double a, double b, double tolerance) { return std::fabs(a - b) <= tolerance; }

// Owns the channel memory a RenderTarget points at.
struct TargetBuffers {
    TargetBuffers(uint32_t channels, uint32_t frames, float fill = 0.0f)
        : data(channels, std::vector<float>(frames, fill)) {
        for (auto& channel : data) ptrs.push_back(channel.data());
        target.output = AudioBufferView{ptrs.data(), channels, frames};
    }
    TargetBuffers(const TargetBuffers&) = delete;
    TargetBuffers& operator=(const TargetBuffers&) = delete;

    bool allEqual(uint32_t frames, float value) const {
        for (const auto& channel : data)
            for (uint32_t f = 0; f < frames; ++f)
                if (channel[f] != value) return false;
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

// A one-step graph: `node` writes the master buffer.
std::unique_ptr<RenderGraph> singleNodeGraph(std::shared_ptr<Node> node, uint32_t maxBlock = kMaxBlock) {
    RenderGraphDesc desc;
    desc.sampleRate = 48000.0;
    desc.maxBlock = maxBlock;
    desc.buffers = std::move(AudioBufferPool::create(1, 2, maxBlock)).value();
    RenderStepDesc step;
    step.node = std::move(node);
    step.output = 0;
    desc.steps.push_back(std::move(step));
    desc.master = 0;
    auto graph = RenderGraph::create(std::move(desc));
    return graph ? std::move(graph).value() : nullptr;
}

std::shared_ptr<Node> put(Engine& engine, NodeID id, std::unique_ptr<Node> node) {
    auto result = engine.nodes().put(id, std::move(node), kInfo);
    return result ? std::move(result).value() : nullptr;
}

uint64_t ticksForNanos(uint64_t nanos) {
    mach_timebase_info_data_t timebase{};
    mach_timebase_info(&timebase);
    return nanos * timebase.denom / timebase.numer;
}

// MARK: Test nodes

void fill(const AudioBufferView& view, uint32_t numFrames, float value) DAW_RT {
    for (uint32_t c = 0; c < view.numChannels; ++c)
        for (uint32_t f = 0; f < numFrames; ++f) view.channels[c][f] = value;
}

class ConstSource final : public Node {
public:
    explicit ConstSource(float value) : value_(value) {}
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        fill(io.audioOut, ctx.numFrames, value_);
    }

private:
    float value_;
};

// Busy for at least `spinTicks` per block, measured with the telemetry clock, so the block's
// render time (and its load) has a known lower bound.
class SpinNode final : public Node {
public:
    explicit SpinNode(uint64_t spinTicks) : spinTicks_(spinTicks) {}
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        const uint64_t start = Telemetry::clockTicks();
        // Bounded (CONV-RT-04); the clock ends it long before the bound.
        for (uint64_t i = 0; i < (uint64_t{1} << 32) && Telemetry::clockTicks() - start < spinTicks_;
             ++i)
            __builtin_arm_yield();
        fill(io.audioOut, ctx.numFrames, 0.25f);
    }

private:
    uint64_t spinTicks_;
};

// TEST-004 AllocatingNode: allocates and frees once per block (two violations).
class AllocatingNode final : public Node {
public:
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        // Deliberate (the point of this node): the trap must count it.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
        (void)runProbe(RtProbe::malloc);
#pragma clang diagnostic pop
        fill(io.audioOut, ctx.numFrames, 0.0f);
    }
};

// For the RetireQueue-full check: daw.reclaim gets stuck destroying a Blocker until released.
struct BlockerControl {
    std::atomic<bool> entered{false};
    std::atomic<bool> release{false};
};

struct Blocker {
    explicit Blocker(BlockerControl& control) : control(control) {}
    ~Blocker() {
        control.entered = true;
        (void)eventually([&] { return control.release.load(); }, 10000ms);
    }
    BlockerControl& control;
};

struct Filler {
    int payload = 0;
};

// Block 1: retires the blocker. Once `fill` is set: retires fillers until retire() fails.
class RetiringNode final : public Node {
public:
    RetiringNode(RetireQueue& queue, Blocker* blocker, std::vector<Filler*>& fillers)
        : queue_(queue), blocker_(blocker), fillers_(fillers.data()),
          numFillers_(static_cast<uint32_t>(fillers.size())) {}
    ~RetiringNode() override { delete blocker_; }  // only if never retired

    std::atomic<bool> fill{false};
    std::atomic<uint32_t> retiredFillers{0};

    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        if (blocker_ != nullptr) {
            if (queue_.retire(blocker_)) blocker_ = nullptr;
        } else if (fill.load(std::memory_order_acquire)) {
            uint32_t next = retiredFillers.load(std::memory_order_relaxed);
            while (next < numFillers_ && queue_.retire(fillers_[next])) ++next;
            retiredFillers.store(next, std::memory_order_release);
        }
        daw::testing::fill(io.audioOut, ctx.numFrames, 0.0f);
    }

private:
    RetireQueue& queue_;
    Blocker* blocker_;
    Filler** fillers_;
    uint32_t numFillers_;
};

} // namespace

// MARK: Clock and load math

CheckResult telemetryClock() {
    CheckResult checks;
    Telemetry telemetry;
    const uint64_t a = Telemetry::clockTicks();
    std::this_thread::sleep_for(20ms);
    const uint64_t b = Telemetry::clockTicks();
    DAW_CHECK(b > a);
    const uint64_t nanos = telemetry.ticksToNanos(b - a);
    DAW_CHECK(nanos >= 19'000'000);
    DAW_CHECK(nanos < 5'000'000'000);  // generous: a loaded CI machine may oversleep
    // The conversion agrees with the timebase it was built from.
    DAW_CHECK(near(static_cast<double>(telemetry.ticksToNanos(ticksForNanos(1'000'000'000))),
                   1e9, 1e3));
    return checks;
}

CheckResult telemetryDspLoadMath() {
    CheckResult checks;
    Telemetry telemetry;
    // No rate known yet: the block counts (epoch) but the load stays 0.
    telemetry.recordBlock(1'000'000, 480, 0.0, 0, 2);
    DAW_CHECK(telemetry.snapshot().dspLoadPercent == 0.0f);
    DAW_CHECK(telemetry.snapshot().graphEpoch == 2);

    // 480 frames at 48 kHz = 10 ms. 5 ms of render → 50 %; the first value seeds the EMA.
    telemetry.recordBlock(5'000'000, 480, 48000.0, 0, 4);
    auto s = telemetry.snapshot();
    DAW_CHECK(near(s.lastBlockLoadPercent, 50.0, 1e-3));
    DAW_CHECK(near(s.dspLoadPercent, 50.0, 1e-3));

    // 10 ms → 100 %; EMA moves by alpha = dt / (tau + dt).
    telemetry.recordBlock(10'000'000, 480, 48000.0, 0, 6);
    s = telemetry.snapshot();
    const double alpha = 0.01 / (Telemetry::kDspLoadTimeConstant + 0.01);
    DAW_CHECK(near(s.lastBlockLoadPercent, 100.0, 1e-3));
    DAW_CHECK(near(s.dspLoadPercent, 50.0 + alpha * 50.0, 1e-3));

    // sampleRate 0 (no graph) reuses the last rate: 2.5 ms of a 10 ms block.
    telemetry.recordBlock(2'500'000, 480, 0.0, 0, 8);
    DAW_CHECK(near(telemetry.snapshot().lastBlockLoadPercent, 25.0, 1e-3));

    // 0-frame blocks leave the load alone.
    const float before = telemetry.snapshot().dspLoadPercent;
    telemetry.recordBlock(9'000'000, 0, 48000.0, 0, 10);
    DAW_CHECK(telemetry.snapshot().dspLoadPercent == before);
    DAW_CHECK(telemetry.snapshot().graphEpoch == 10);

    // The time constant is in seconds, not blocks: 3 s of 100 % (10 tau) from ~50 % ends within
    // 0.01 % of 100 whether it comes in 128- or 4096-frame blocks.
    for (uint32_t frames : {128u, 4096u}) {
        Telemetry t;
        t.recordBlock(0, frames, 48000.0, 0, 2);  // seed at 0 %
        const uint64_t blockNanos = uint64_t{frames} * 1'000'000'000 / 48000;
        const uint32_t blocks = static_cast<uint32_t>(3.0 * 48000.0 / frames);
        for (uint32_t i = 0; i < blocks; ++i) t.recordBlock(blockNanos, frames, 48000.0, 0, 2);
        DAW_CHECK(t.snapshot().dspLoadPercent > 99.9f);
        DAW_CHECK(t.snapshot().dspLoadPercent <= 100.001f);
    }

    // Violations accumulate; the epoch is the latest.
    telemetry.recordBlock(0, 480, 48000.0, 3, 12);
    telemetry.recordBlock(0, 480, 48000.0, 4, 14);
    DAW_CHECK(telemetry.snapshot().rtViolations == 7);
    DAW_CHECK(telemetry.snapshot().graphEpoch == 14);
    return checks;
}

// MARK: Engine

CheckResult engineTelemetryPerBlock() {
    CheckResult checks;
    Engine engine;
    TargetBuffers out(2, 128);

    // No graph yet: blocks are published, no rate is known so the load stays 0.
    for (int i = 0; i < 3; ++i) DAW_CHECK(renderCounted(engine, out.target, 128) == 0);
    auto s = engine.telemetry().snapshot();
    DAW_CHECK(s.graphEpoch == 6);
    DAW_CHECK(s.dspLoadPercent == 0.0f);
    DAW_CHECK(s.rtViolations == 0);

    // 128 frames at 48 kHz = 2.667 ms; the node is busy ≥ 1 ms, so every block's load is
    // ≥ 37.5 % (and so is the EMA, which starts at the first such block). No upper bound: a
    // loaded machine may take longer.
    auto spin = put(engine, 1, std::make_unique<SpinNode>(ticksForNanos(1'000'000)));
    DAW_CHECK(spin != nullptr);
    engine.publish(singleNodeGraph(spin));
    // The first block with a graph inherits nothing (the rate was unknown), so it seeds the EMA.
    for (int i = 0; i < 20; ++i) DAW_CHECK(renderCounted(engine, out.target, 128) == 0);
    s = engine.telemetry().snapshot();
    DAW_CHECK(out.allEqual(128, 0.25f));
    DAW_CHECK(s.graphEpoch == 2 * 23);
    DAW_CHECK(s.graphEpoch == 2 * engine.blocksRendered());
    DAW_CHECK(s.lastBlockLoadPercent >= 37.5f);
    DAW_CHECK(s.dspLoadPercent >= 37.5f);
    DAW_CHECK(s.rtViolations == 0);  // DW-024: the engine's own render scope
    DAW_CHECK(s.oversizeBlocks == 0);
    DAW_CHECK(s.retireQueueFullBlocks == 0);
    return checks;
}

CheckResult engineCountsOversizeBlocks() {
    CheckResult checks;
    Engine engine;
    TargetBuffers out(2, 1024, 1.0f);

    // Without a graph there's no maxBlock to exceed: silence, but not an oversize block.
    DAW_CHECK(renderCounted(engine, out.target, 1024) == 0);
    DAW_CHECK(engine.telemetry().snapshot().oversizeBlocks == 0);

    engine.publish(singleNodeGraph(put(engine, 1, std::make_unique<ConstSource>(0.5f)), 256));
    DAW_CHECK(renderCounted(engine, out.target, 256) == 0);
    DAW_CHECK(out.allEqual(256, 0.5f));
    DAW_CHECK(engine.telemetry().snapshot().oversizeBlocks == 0);

    DAW_CHECK(renderCounted(engine, out.target, 1024) == 0);
    DAW_CHECK(out.allEqual(1024, 0.0f));  // rendered as silence
    DAW_CHECK(renderCounted(engine, out.target, 257) == 0);
    DAW_CHECK(renderCounted(engine, out.target, 256) == 0);
    const auto s = engine.telemetry().snapshot();
    DAW_CHECK(s.oversizeBlocks == 2);
    DAW_CHECK(s.graphEpoch == 2 * 5);
    DAW_CHECK(s.rtViolations == 0);
    return checks;
}

CheckResult engineCountsRetireQueueFull() {
    CheckResult checks;
    BlockerControl control;
    std::vector<Filler*> fillers;
    for (std::size_t i = 0; i < RetireQueue::kCapacity + 64; ++i) fillers.push_back(new Filler);
    RetiringNode* node = nullptr;
    uint32_t retired = 0;
    {
        Engine engine;
        auto shared = put(engine, 1, std::make_unique<RetiringNode>(engine.retireQueue(),
                                                                     new Blocker(control), fillers));
        node = static_cast<RetiringNode*>(shared.get());
        engine.publish(singleNodeGraph(shared));
        TargetBuffers out(2, 64);

        // Block 1 retires the blocker; daw.reclaim pops it and is stuck in its destructor.
        DAW_CHECK(renderCounted(engine, out.target, 64) == 0);
        DAW_CHECK(eventually([&] { return control.entered.load(); }));
        DAW_CHECK(engine.telemetry().snapshot().retireQueueFullBlocks == 0);

        // Block 2 fills the queue (nothing drains it now); blocks 2 and 3 end with it full.
        node->fill = true;
        DAW_CHECK(renderCounted(engine, out.target, 64) == 0);
        retired = node->retiredFillers.load();
        DAW_CHECK(retired == RetireQueue::kCapacity);
        DAW_CHECK(engine.telemetry().snapshot().retireQueueFullBlocks == 1);
        node->fill = false;
        DAW_CHECK(renderCounted(engine, out.target, 64) == 0);
        DAW_CHECK(engine.telemetry().snapshot().retireQueueFullBlocks == 2);

        // Reclaim catches up: the count stops growing.
        control.release = true;
        DAW_CHECK(eventually([&] { return engine.reclaimer().rtObjectsFreed() >= 1 + retired; }));
        DAW_CHECK(renderCounted(engine, out.target, 64) == 0);
        const auto s = engine.telemetry().snapshot();
        DAW_CHECK(s.retireQueueFullBlocks == 2);
        DAW_CHECK(s.rtViolations == 0);
    }
    control.release = true;  // in case a check above failed early
    // The queue owned (and reclaim freed) the first `retired`; the rest are still ours.
    for (std::size_t i = retired; i < fillers.size(); ++i) delete fillers[i];
    return checks;
}

// MARK: Producer paths

CheckResult telemetryProducerPaths() {
    CheckResult checks;
    Telemetry telemetry;

    // Xruns: several producers at once (the overload listener and the render callback, IO-023).
    {
        constexpr int kThreads = 4, kPerThread = 10'000;
        std::atomic<uint64_t> violations{0};
        std::vector<std::thread> threads;
        for (int t = 0; t < kThreads; ++t)
            threads.emplace_back([&] {
                RtScope scope;
                for (int i = 0; i < kPerThread; ++i) telemetry.countXrun();
                violations += scope.violations();
            });
        for (auto& thread : threads) thread.join();
        DAW_CHECK(violations == 0);
        DAW_CHECK(telemetry.snapshot().xruns == uint64_t{kThreads} * kPerThread);
    }

    // Latencies: device + graph = output; the table round-trips.
    const NodeLatency table[] = {{10, 0}, {11, 64}, {12, 512}};
    uint64_t violations = 0;
    {
        RtScope scope;
        telemetry.setDeviceOutputLatency(300);
        telemetry.publishNodeLatencies(table, 3, 576);
        telemetry.writeMeter(0, 0.9f, 0.4f);
        telemetry.writeMeter(Telemetry::kMaxMeters - 1, 0.5f, 0.25f);
        telemetry.writeMeter(Telemetry::kMaxMeters, 1.0f, 1.0f);  // out of range: ignored
        (void)telemetry.meter(0);
        telemetry.recordBlock(1000, 128, 48000.0, 0, 2);
        telemetry.countOversizeBlock();
        telemetry.countRetireQueueFull();
        violations = scope.violations();
    }
    DAW_CHECK(violations == 0);  // CONV §5.3: every writer is RT-safe

    auto s = telemetry.snapshot();
    DAW_CHECK(s.deviceOutputLatency == 300);
    DAW_CHECK(s.graphLatency == 576);
    DAW_CHECK(s.outputLatency == 876);
    DAW_CHECK(s.numNodeLatencies == 3);
    DAW_CHECK(s.oversizeBlocks == 1);
    DAW_CHECK(s.retireQueueFullBlocks == 1);

    NodeLatency copy[8] = {};
    DAW_CHECK(telemetry.nodeLatencies(copy, 8) == 3);
    DAW_CHECK(copy[0].node == 10 && copy[0].samples == 0);
    DAW_CHECK(copy[1].node == 11 && copy[1].samples == 64);
    DAW_CHECK(copy[2].node == 12 && copy[2].samples == 512);
    DAW_CHECK(telemetry.nodeLatencies(copy, 2) == 2);  // the reader's max

    // A smaller table replaces the whole thing.
    telemetry.publishNodeLatencies(table + 2, 1, 512);
    DAW_CHECK(telemetry.nodeLatencies(copy, 8) == 1);
    DAW_CHECK(copy[0].node == 12);
    DAW_CHECK(telemetry.snapshot().outputLatency == 812);

    // More than the table holds: truncated to kMaxNodeLatencies.
    std::vector<NodeLatency> big(Telemetry::kMaxNodeLatencies + 10);
    for (uint32_t i = 0; i < big.size(); ++i) big[i] = {i + 1, i};
    telemetry.publishNodeLatencies(big.data(), static_cast<uint32_t>(big.size()), 0);
    std::vector<NodeLatency> all(big.size());
    DAW_CHECK(telemetry.nodeLatencies(all.data(), static_cast<uint32_t>(all.size())) ==
              Telemetry::kMaxNodeLatencies);
    DAW_CHECK(all[Telemetry::kMaxNodeLatencies - 1].node == Telemetry::kMaxNodeLatencies);

    // Meters.
    DAW_CHECK(telemetry.meter(0).peak == 0.9f && telemetry.meter(0).rms == 0.4f);
    DAW_CHECK(telemetry.meter(Telemetry::kMaxMeters - 1).peak == 0.5f);
    DAW_CHECK(telemetry.meter(Telemetry::kMaxMeters - 1).rms == 0.25f);
    DAW_CHECK(telemetry.meter(1).peak == 0.0f && telemetry.meter(1).rms == 0.0f);  // never written
    DAW_CHECK(telemetry.meter(Telemetry::kMaxMeters).peak == 0.0f);                // out of range
    return checks;
}

CheckResult telemetryConcurrentReadersSeeConsistentValues() {
    CheckResult checks;
    Telemetry telemetry;
    std::atomic<bool> stop{false};
    std::atomic<uint64_t> writerViolations{0}, writes{0};

    // Writer (stands in for the audio thread): table k has (k % 64) + 1 entries, all with
    // samples == k, and graph latency k; meter 7 gets (k, k).
    std::thread writer([&] {
        RtScope scope;
        NodeLatency entries[64];
        for (uint32_t k = 1; k < 2'000'000 && !stop.load(std::memory_order_relaxed); ++k) {
            const uint32_t count = (k % 64) + 1;
            for (uint32_t i = 0; i < count; ++i) entries[i] = {i, k};
            telemetry.publishNodeLatencies(entries, count, k);
            telemetry.writeMeter(7, static_cast<float>(k), static_cast<float>(k));
            writes.store(k, std::memory_order_relaxed);
        }
        writerViolations = scope.violations();
    });

    uint64_t reads = 0, torn = 0;
    NodeLatency copy[64];
    const auto deadline = std::chrono::steady_clock::now() + 300ms;
    while (std::chrono::steady_clock::now() < deadline) {
        const uint32_t n = telemetry.nodeLatencies(copy, 64);
        if (n > 0) {
            const uint32_t k = copy[0].samples;
            if (n != (k % 64) + 1) ++torn;
            for (uint32_t i = 0; i < n; ++i)
                if (copy[i].samples != k || copy[i].node != i) ++torn;
        }
        const auto s = telemetry.snapshot();
        if (s.numNodeLatencies != 0 && s.numNodeLatencies != (s.graphLatency % 64) + 1) ++torn;
        const MeterReading m = telemetry.meter(7);
        if (m.peak != m.rms) ++torn;
        ++reads;
    }
    stop = true;
    writer.join();

    DAW_CHECK(torn == 0);
    DAW_CHECK(reads > 100);
    DAW_CHECK(writes.load() > 100);  // the two really overlapped
    DAW_CHECK(writerViolations == 0);
    return checks;
}

TelemetrySnapshot snapshotAfterRendering(uint32_t blocks) {
    Engine engine;
    engine.telemetry().setDeviceOutputLatency(256);
    engine.publish(singleNodeGraph(put(engine, 1, std::make_unique<ConstSource>(0.5f))));
    TargetBuffers out(2, 256);
    for (uint32_t i = 0; i < blocks; ++i) engine.render(out.target, 256);
    return engine.telemetry().snapshot();
}

// MARK: Process-wide trap state (RtTrapTests only)

CheckResult engineRtViolationsFromRenderScope() {
    CheckResult checks;
    Engine engine;
    RtTrap::resetViolations();
    DAW_CHECK(!engine.telemetry().firstViolation().has_value());

    engine.publish(singleNodeGraph(put(engine, 1, std::make_unique<AllocatingNode>())));
    TargetBuffers out(2, 128);
    // malloc + free per block. The outer scope sees the same violations the engine's does.
    DAW_CHECK(renderCounted(engine, out.target, 128) == 2);
    DAW_CHECK(engine.telemetry().snapshot().rtViolations == 2);
    DAW_CHECK(renderCounted(engine, out.target, 128) == 2);
    DAW_CHECK(engine.telemetry().snapshot().rtViolations == 4);

    // DW-011: the first one's backtrace, symbolized off the audio thread, reaches the node.
    const auto first = engine.telemetry().firstViolation();
    DAW_CHECK(first.has_value());
    if (first) {
        DAW_CHECK(first->kind == RtViolationKind::allocation);
        bool reachesNode = false;
        for (const auto& frame : first->frames)
            if (frame.find("AllocatingNode") != std::string::npos) reachesNode = true;
        DAW_CHECK(reachesNode);
    }
    return checks;
}

CheckResult engineRtViolationsIgnoreOtherScopes() {
    CheckResult checks;
    Engine engine;
    engine.publish(singleNodeGraph(put(engine, 1, std::make_unique<ConstSource>(0.5f))));
    TargetBuffers out(2, 128);
    const uint64_t globalBefore = RtTrap::violationCount();

    // Violations in other scopes, on this thread and another, between the engine's blocks.
    DAW_CHECK(renderCounted(engine, out.target, 128) == 0);
    DAW_CHECK(runProbeInScope(RtProbe::malloc).total() == 2);
    DAW_CHECK(runProbeOnRtThread(RtProbe::pthreadMutex).total() == 1);
    DAW_CHECK(renderCounted(engine, out.target, 128) == 0);

    DAW_CHECK(RtTrap::violationCount() - globalBefore == 3);  // the process-wide count saw them
    DAW_CHECK(engine.telemetry().snapshot().rtViolations == 0);  // DW-024: this engine didn't
    return checks;
}

} // namespace daw::testing
