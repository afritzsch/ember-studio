#include "nodes/GainNode.h"

#include "automation/WrapJump.h"
#include "core/ProcessContext.h"
#include "graph/PassThrough.h"

namespace daw {

void GainNode::prepare(const PrepareInfo&) { primed_ = false; }

void GainNode::process(ProcessContext& ctx, NodeIO& io) DAW_RT {
    passThrough(io);
    const AudioBufferView& out = io.audioOut;
    const uint32_t n = out.numFrames;
    if (n == 0) return;  // ENG-004: a 0-frame block leaves the smoothers as they were

    // ENG-021: one read per slot per block. NaN fails both comparisons and becomes silence.
    const float raw = ctx.params.get(firstParam_ + kLevel);
    const float level = raw >= 0.0f ? (raw <= kMaxLevel ? raw : kMaxLevel) : 0.0f;
    // MIX-007: on at ≥ 0.5, like the strip's mute; NaN is off.
    const float open = hasMute_ && ctx.params.get(firstParam_ + kMute) >= 0.5f ? 0.0f : 1.0f;
    if (!primed_) {
        level_.reset(level);
        mute_.reset(open);
        primed_ = true;
    }
    // AUTO-003 (T-074): an automated level or mute may jump at a loop wrap inside the block.
    WrapJump lj = wrapJump(ctx, firstParam_ + kLevel);
    lj.value = lj.value >= 0.0f ? (lj.value <= kMaxLevel ? lj.value : kMaxLevel) : 0.0f;
    WrapJump mj = hasMute_ ? wrapJump(ctx, firstParam_ + kMute) : WrapJump{};
    mj.value = mj.value >= 0.5f ? 0.0f : 1.0f;

    // ENG-022: level and mute combined into one linear ramp.
    const ParamRamp l = level_.next(level, n, lj);
    const ParamRamp m = mute_.next(open, n, mj);
    const uint32_t jumpAt = l.jumps() ? l.jumpAt : (m.jumps() ? m.jumpAt : ParamRamp::kNoJump);
    const ParamRamp ramp{l.start * m.start, l.target * m.target, n, jumpAt, l.end() * m.end()};
    for (uint32_t c = 0; c < out.numChannels; ++c) ramp.multiply(out.channels[c]);
}

} // namespace daw
