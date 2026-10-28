#pragma once
// TEST-004: the test-only nodes (private to DAWEngineTestSupport, never in Sources/DAWEngine).
// Golden tests reach them through makeTestFacade (include/GoldenEngineSupport.h); C++ checks
// construct them directly (TestNodeChecks.cpp). All process() bodies are DAW_RT and checked by
// -Wfunction-effects, except AllocatingNode's deliberate violation.

#include <cstdint>
#include <memory>
#include <vector>

#include "GoldenEngineSupport.h"
#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ProcessContext.h"
#include "core/Result.h"
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

// An unprepared node for `spec` (its kind is not used here).
std::unique_ptr<Node> makeTestNode(const TestNodeSpec& spec);

// Registers `spec` under spec.kind (see TestNodeSpec for audioClipPlayer). invalidArgument if
// `registry` has no audioClipPlayer to fall back to.
Result<void> registerTestNode(NodeRegistry& registry, const TestNodeSpec& spec);

} // namespace daw::testing
