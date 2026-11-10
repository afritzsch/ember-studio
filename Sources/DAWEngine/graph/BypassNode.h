#pragma once
// PLUG-018 (T-064): host-side bypass. GraphBuilder wraps every node whose NodeDesc has a
// bypassParam (05 GraphDescription, additive) in a BypassNode, made fresh for each graph around
// the pooled node, so the wrapped node itself (a plugin with its state, a built-in with its DSP
// state) is never re-created by a bypass toggle or by being wrapped.
//
// While the bypass slot is >= 0.5 (NaN: not bypassed) the wrapped node isn't processed at all and
// the wrapper outputs its main input delayed by the node's latency, the latency the graph's PDC
// was planned with (MIX-021), so every path keeps its alignment and toggling bypass is a slot
// write, never a rebuild. An instrument has no main input, so bypassed it is silent. MIDI and
// the sidechain only reach the wrapped node while it runs.
//
// The input always goes through the delay line, bypassed or not, so a toggle has the right
// history at once. A toggle crossfades linearly over one block (D-13: per-block ramps, no clicks)
// between the wrapped node's output and the delayed input. The wrapped node's state (tails,
// voices, a plugin's own state) is just paused while bypassed.
//
// The delay line and the toggle state live in a BypassState that GraphBuilder keeps per NodeID
// across builds, like edge delay lines (MIX-022), so a rebuild doesn't glitch a bypassed node. Only
// one graph renders at a time, so the state is the audio thread's alone.

#include <cstdint>
#include <memory>

#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/Realtime.h"
#include "core/RenderGraph.h"

namespace daw {

class BypassState {
public:
    // Non-RT. A delay line long enough for `latency` (it may hold a little more, see DelayLine).
    BypassState(uint32_t latency, uint32_t maxBlock);
    BypassState(const BypassState&) = delete;
    BypassState& operator=(const BypassState&) = delete;

    uint32_t maxDelay() const { return line_.maxDelay(); }
    uint32_t maxBlock() const { return maxBlock_; }

private:
    friend class BypassNode;
    uint32_t maxBlock_;
    DelayLine line_;
    std::unique_ptr<float[]> scratch_;  // 2 × maxBlock: the delayed input of the current block
    // Audio thread only.
    bool primed_ = false;
    bool bypassed_ = false;
};

class BypassNode final : public Node {
public:
    // `latency` is `inner`'s latencySamples() as the build read it (<= state->maxDelay()).
    BypassNode(std::shared_ptr<Node> inner, ParamID bypassParam, uint32_t latency,
               std::shared_ptr<BypassState> state);

    // The wrapped node is prepared by the NodePool before it is wrapped; nothing to do here.
    void prepare(const PrepareInfo&) override {}
    void reset() DAW_RT override { inner_->reset(); }
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;
    uint32_t latencySamples() const override { return latency_; }

    // Non-RT diagnostics and tests.
    const std::shared_ptr<Node>& inner() const { return inner_; }
    ParamID bypassParam() const { return bypassParam_; }
    const std::shared_ptr<BypassState>& state() const { return state_; }

    static bool isBypassed(float slotValue) DAW_RT { return slotValue >= 0.5f; }

private:
    std::shared_ptr<Node> inner_;
    ParamID bypassParam_;
    uint32_t latency_;
    std::shared_ptr<BypassState> state_;
};

} // namespace daw
