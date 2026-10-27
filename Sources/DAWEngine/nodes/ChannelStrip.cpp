#include "nodes/ChannelStrip.h"

#include <cstddef>
#include <cstring>

#include "core/ProcessContext.h"
#include "dsp/PanLaw.h"
#include "graph/PassThrough.h"

namespace daw {

namespace {

float clampGain(float gain) DAW_RT {
    // NaN fails both comparisons and becomes silence.
    return gain >= 0.0f ? (gain <= ChannelStrip::kMaxGain ? gain : ChannelStrip::kMaxGain) : 0.0f;
}

} // namespace

ChannelStrip::ChannelStrip(ParamID firstParam, MeterTarget meter)
    : gainParam_(firstParam + kGain), panParam_(firstParam + kPan), meter_(meter) {}

void ChannelStrip::prepare(const PrepareInfo& info) {
    window_.prepare(info.sampleRate);
    primed_ = false;
}

void ChannelStrip::process(ProcessContext& ctx, NodeIO& io) DAW_RT {
    passThrough(io);
    const AudioBufferView& out = io.audioOut;
    const uint32_t n = out.numFrames;
    if (n == 0) return;  // ENG-004: a 0-frame block leaves the smoothers as they were

    // ENG-021: one read per slot per block.
    const float gain = clampGain(ctx.params.get(gainParam_));
    const float pan = ctx.params.get(panParam_);  // constantPowerPan clamps
    if (!primed_) {
        gain_.reset(gain);
        pan_.reset(pan);
        primed_ = true;
    }
    // ENG-022: ramp from where the previous block ended.
    const ParamRamp g = gain_.next(gain, n);
    const ParamRamp p = pan_.next(pan, n);
    const PanGains from = constantPowerPan(p.start);
    const PanGains to = constantPowerPan(p.target);
    const ParamRamp left{g.start * from.left, g.target * to.left, n};
    const ParamRamp right{g.start * from.right, g.target * to.right, n};

    if (out.numChannels >= 1) left.multiply(out.channels[0]);
    if (out.numChannels >= 2) right.multiply(out.channels[1]);
    // Stereo throughout (MIX-004); anything beyond L/R is not part of the strip's output.
    for (uint32_t c = 2; c < out.numChannels; ++c)
        std::memset(out.channels[c], 0, std::size_t{n} * sizeof(float));

    if (meter_.telemetry != nullptr && out.numChannels >= 1) {
        const float* l = out.channels[0];
        window_.add(l, out.numChannels >= 2 ? out.channels[1] : l, n);
        const MeterReading r = window_.reading();
        meter_.telemetry->writeMeter(meter_.id, r.peak, r.rms);
    }
}

} // namespace daw
