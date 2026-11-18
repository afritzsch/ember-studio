#pragma once
// TEST-004: the test-only nodes (private to DAWEngineTestSupport, never in Sources/DAWEngine).
// Golden tests reach them through makeTestFacade (include/GoldenEngineSupport.h); C++ checks
// construct them directly (TestNodeChecks.cpp). All process() bodies are DAW_RT and checked by
// -Wfunction-effects, except AllocatingNode's deliberate violation.

#include <atomic>
#include <cstdint>
#include <memory>
#include <vector>

#include "GoldenEngineSupport.h"
#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ProcessContext.h"
#include "core/Result.h"
#include "graph/LatencyReporter.h"
#include "graph/NodeRegistry.h"

namespace daw::testing {

// level · sin(2π · hz · n / rate), the same on every channel. n counts frames since prepare()
// or the last reset() (a locate, TIME-008, when registered under a timeline kind), so a render
// from any position starts at phase 0 and is reproducible.
class SineNode final : public Node {
public:
    SineNode(double hz, float level) : hz_(hz), level_(level) {}
    void prepare(const PrepareInfo& info) override;
    void reset() DAW_RT override { frame_ = 0; }
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;

private:
    double hz_;
    float level_;
    double rate_ = 48000.0;
    uint64_t frame_ = 0;
};

// `level` at frames first, first + period, … since prepare() or the last reset(); period 0
// gives a single impulse.
class ImpulseNode final : public Node {
public:
    ImpulseNode(uint32_t period, float level, uint32_t first = 0) : period_(period), first_(first), level_(level) {}
    void prepare(const PrepareInfo&) override { frame_ = 0; }
    void reset() DAW_RT override { frame_ = 0; }
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;

private:
    uint64_t period_;
    uint64_t first_;
    float level_;
    uint64_t frame_ = 0;
};

// Its main input delayed by `latency` frames (up to 2 channels; further channels are silent),
// reporting the delay as latencySamples() (ENG-002), so PDC (MIX-021) has something to align.
class FakeLatencyNode final : public Node {
public:
    explicit FakeLatencyNode(uint32_t latency) : latency_(latency) {}
    void prepare(const PrepareInfo& info) override;
    void reset() DAW_RT override;
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;
    uint32_t latencySamples() const override { return latency_; }

private:
    uint32_t latency_;
    uint32_t capacity_ = 0;  // a power of two > latency_
    uint32_t write_ = 0;
    std::vector<float> ring_;  // 2 × capacity_
};

// T-064 (PLUG-018): silence, while reporting `latency` frames as latencySamples(): a latent device
// whose own output is easy to tell from its (bypassed) input.
class LatentMuteNode final : public Node {
public:
    explicit LatentMuteNode(uint32_t latency) : latency_(latency) {}
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;
    uint32_t latencySamples() const override { return latency_; }

private:
    uint32_t latency_;
};

// Silence, and one malloc + free per non-empty block: the RT trap (ENG-030..032) must count two
// violations per block. Only for tests about the trap.
class AllocatingNode final : public Node {
public:
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;
};

// Quiet NaN on every channel, for tests of what the engine does with non-finite audio.
class NaNNode final : public Node {
public:
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;
};

// MIX-008 (T-023): a node that reads its sidechain input, standing in for the built-in
// compressor (DSP-031, T-071) until it exists. out = in + level · sidechain per channel; channels
// the sidechain lacks, and every channel when the sidechain is empty (nothing routed, ENG-003),
// pass the main input alone (an empty main input counts as silence). It counts the blocks it ran
// and those with a routed (non-empty) sidechain, so a check can tell an empty port from a silent
// one; the counters are single-writer atomics (audio thread), readable from any thread.
class SidechainMixNode final : public Node {
public:
    explicit SidechainMixNode(float level) : level_(level) {}
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;

    uint64_t blocks() const { return blocks_.load(std::memory_order_relaxed); }
    uint64_t routedBlocks() const { return routed_.load(std::memory_order_relaxed); }

private:
    float level_;
    std::atomic<uint64_t> blocks_{0};
    std::atomic<uint64_t> routed_{0};
};

// DW-138 (MIX-024): FakeLatencyNode whose latency may change after prepare. It delays its main
// input (up to 2 channels) by latencySamples() from the next block and tells the engine through
// the LatencyReporter its factory got. Delays up to kCapacity - 1 frames.
class ReportingLatencyNode final : public Node {
public:
    static constexpr uint32_t kCapacity = 1u << 16;

    ReportingLatencyNode(uint32_t latency, LatencyReporter reporter)
        : latency_(latency), reporter_(std::move(reporter)) {}

    void prepare(const PrepareInfo&) override { ring_.assign(2 * kCapacity, 0.0f); }
    uint32_t latencySamples() const override { return latency_.load(std::memory_order_relaxed); }

    // Non-RT, test thread.
    void setLatency(uint32_t latency) {
        latency_.store(latency, std::memory_order_relaxed);
        reporter_.changed();
    }

    void process(ProcessContext&, NodeIO& io) DAW_RT override {
        const uint32_t delay = latency_.load(std::memory_order_relaxed) & (kCapacity - 1);
        const AudioBufferView& out = io.audioOut;
        for (uint32_t c = 0; c < out.numChannels && c < 2; ++c) {
            float* ring = ring_.data() + std::size_t{c} * kCapacity;
            const float* in = c < io.audioIn.numChannels ? io.audioIn.channels[c] : nullptr;
            for (uint32_t f = 0; f < out.numFrames; ++f) {
                const uint32_t at = write_ + f;
                ring[at & (kCapacity - 1)] = in ? in[f] : 0.0f;
                out.channels[c][f] = ring[(at - delay) & (kCapacity - 1)];
            }
        }
        write_ += out.numFrames;
    }

private:
    std::atomic<uint32_t> latency_;
    LatencyReporter reporter_;
    std::vector<float> ring_;
    uint32_t write_ = 0;
};

// An unprepared node for `spec` (its kind is not used here).
std::unique_ptr<Node> makeTestNode(const TestNodeSpec& spec);

// Registers `spec` under spec.kind (see TestNodeSpec for audioClipPlayer). invalidArgument if
// `registry` has no audioClipPlayer to fall back to.
Result<void> registerTestNode(NodeRegistry& registry, const TestNodeSpec& spec);

} // namespace daw::testing
