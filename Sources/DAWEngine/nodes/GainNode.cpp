#include "nodes/GainNode.h"

#include "core/ProcessContext.h"
#include "graph/PassThrough.h"

namespace daw {

void GainNode::prepare(const PrepareInfo&) { primed_ = false; }

void GainNode::process(ProcessContext& ctx, NodeIO& io) DAW_RT {
    passThrough(io);
    const AudioBufferView& out = io.audioOut;
    const uint32_t n = out.numFrames;
    if (n == 0) return;  // ENG-004: a 0-frame block leaves the smoother as it was

    // ENG-021: one read per block. NaN fails both comparisons and becomes silence.
    const float raw = ctx.params.get(levelParam_);
    const float level = raw >= 0.0f ? (raw <= kMaxLevel ? raw : kMaxLevel) : 0.0f;
    if (!primed_) {
        level_.reset(level);
        primed_ = true;
    }
    const ParamRamp ramp = level_.next(level, n);  // ENG-022
    for (uint32_t c = 0; c < out.numChannels; ++c) ramp.multiply(out.channels[c]);
}

} // namespace daw
