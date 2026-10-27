#pragma once
// MIX-009: NodeKind::master, the final node. Its output is the graph's master buffer, which
// Engine::render writes to the RenderTarget. The master's insert chain and channel strip are
// separate nodes upstream of it.
//
// Optional hard-clip safety limiter, off by default. It is switched by the master's first param
// slot (on when >= 0.5), read once per block, so tests and users can toggle it without a
// rebuild; a master with numParams 0 never clips. When on, samples beyond ±1 are clipped to ±1,
// NaNs become 0, and each one counts as an over in clippedSamples(), so a test can render with
// the limiter on and assert that nothing clipped.

#include <atomic>
#include <cstdint>

#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/Realtime.h"

namespace daw {

class MasterNode final : public Node {
public:
    // `firstParam`/`numParams` as in the NodeDesc; param 0 of the range is the limiter switch.
    MasterNode(ParamID firstParam, uint32_t numParams);

    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;

    // Overs the limiter has clipped since construction. Any thread.
    uint64_t clippedSamples() const { return clipped_.load(std::memory_order_relaxed); }

private:
    ParamID limiterParam_;
    bool hasLimiter_;
    std::atomic<uint64_t> clipped_{0};
};

} // namespace daw
