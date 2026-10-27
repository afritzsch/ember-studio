#include "graph/MasterNode.h"

#include "core/ProcessContext.h"
#include "graph/PassThrough.h"

namespace daw {

MasterNode::MasterNode(ParamID firstParam, uint32_t numParams)
    : limiterParam_(firstParam), hasLimiter_(numParams > 0) {}

void MasterNode::process(ProcessContext& ctx, NodeIO& io) DAW_RT {
    passThrough(io);
    if (!hasLimiter_ || ctx.params.get(limiterParam_) < 0.5f) return;

    // MIX-009: hard clip, a safety net rather than a mastering limiter.
    uint64_t overs = 0;
    const AudioBufferView& out = io.audioOut;
    for (uint32_t c = 0; c < out.numChannels; ++c) {
        float* samples = out.channels[c];
        for (uint32_t f = 0; f < out.numFrames; ++f) {
            const float x = samples[f];
            if (x >= -1.0f && x <= 1.0f) continue;
            samples[f] = x > 1.0f ? 1.0f : x < -1.0f ? -1.0f : 0.0f;  // the last case is NaN
            ++overs;
        }
    }
    if (overs > 0) clipped_.fetch_add(overs, std::memory_order_relaxed);
}

} // namespace daw
