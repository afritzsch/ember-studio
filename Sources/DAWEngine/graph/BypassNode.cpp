#include "graph/BypassNode.h"

#include <cstring>

#include "core/ProcessContext.h"

namespace daw {

BypassState::BypassState(uint32_t latency, uint32_t maxBlock)
    : maxBlock_(maxBlock), line_(2, latency, maxBlock), scratch_(new float[std::size_t{2} * maxBlock]()) {}

BypassNode::BypassNode(std::shared_ptr<Node> inner, ParamID bypassParam, uint32_t latency,
                       std::shared_ptr<BypassState> state)
    : inner_(std::move(inner)), bypassParam_(bypassParam), latency_(latency), state_(std::move(state)) {}

void BypassNode::reset() DAW_RT {
    inner_->reset();
    state_->line_.clear();
    state_->primed_ = false;
    state_->bypassed_ = false;
}

void BypassNode::process(ProcessContext& ctx, NodeIO& io) DAW_RT {
    BypassState& s = *state_;
    const uint32_t n = ctx.numFrames;
    DAW_RT_ASSERT(n <= s.maxBlock_ && latency_ <= s.line_.maxDelay());
    const bool bypass = isBypassed(ctx.params.get(bypassParam_));

    if (!s.primed_) {
        s.primed_ = true;
        s.bypassed_ = bypass;  // the first block takes the slot as it is: no fade in from nothing
    }
    const bool was = s.bypassed_;
    s.bypassed_ = bypass;

    // The delayed input (before the wrapped node may overwrite a shared buffer). Every block for
    // a latent node, so its line has the right history at a toggle. DW-280 (T-092, TEST-008): a
    // 0-latency insert's line has no history to keep (maxDelay() 0: its output is the input, and
    // a later build with latency gets a new line), so a block that is neither bypassed nor
    // toggling, where the dry signal isn't used, skips the copy.
    float* dryChannels[2] = {s.scratch_.get(), s.scratch_.get() + s.maxBlock_};
    const AudioBufferView dry{dryChannels, 2, n};
    if (bypass || was || s.line_.maxDelay() != 0) s.line_.process(io.audioIn, dry, latency_, false, n);

    const AudioBufferView& out = io.audioOut;
    if (was && bypass) {
        const std::size_t bytes = std::size_t{n} * sizeof(float);
        for (uint32_t c = 0; c < out.numChannels; ++c) {
            if (c < dry.numChannels) std::memcpy(out.channels[c], dry.channels[c], bytes);
            else std::memset(out.channels[c], 0, bytes);
        }
        return;
    }
    inner_->process(ctx, io);
    if (was == bypass || n == 0) return;

    // A toggle: one block-long linear crossfade, towards the dry signal when bypassing.
    const float step = 1.0f / static_cast<float>(n);
    for (uint32_t c = 0; c < out.numChannels; ++c) {
        float* o = out.channels[c];
        const float* d = c < dry.numChannels ? dry.channels[c] : nullptr;
        for (uint32_t f = 0; f < n; ++f) {
            const float t = static_cast<float>(f + 1) * step;
            const float g = bypass ? t : 1.0f - t;  // weight of the dry signal
            o[f] = o[f] * (1.0f - g) + (d ? d[f] * g : 0.0f);
        }
    }
}

} // namespace daw
