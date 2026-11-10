#include "nodes/ChannelStrip.h"

#include <cstddef>
#include <cstring>
#include <initializer_list>

#include "automation/WrapJump.h"
#include "core/ProcessContext.h"
#include "dsp/PanLaw.h"
#include "graph/PassThrough.h"

namespace daw {

namespace {

float clampGain(float gain) DAW_RT {
    // NaN fails both comparisons and becomes silence.
    return gain >= 0.0f ? (gain <= ChannelStrip::kMaxGain ? gain : ChannelStrip::kMaxGain) : 0.0f;
}

// MIX-005 switches (mute, phase): on at ≥ 0.5, like the master's limiter slot (MIX-009). NaN is off.
bool switchOn(float value) DAW_RT { return value >= 0.5f; }

} // namespace

ChannelStrip::ChannelStrip(ParamID firstParam, MeterTarget meter)
    : firstParam_(firstParam), meter_(meter) {}

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
    const float gain = clampGain(ctx.params.get(firstParam_ + kGain));
    const float pan = ctx.params.get(firstParam_ + kPan);  // constantPowerPan clamps
    const float open = switchOn(ctx.params.get(firstParam_ + kMute)) ? 0.0f : 1.0f;
    const float polarity = switchOn(ctx.params.get(firstParam_ + kPhase)) ? -1.0f : 1.0f;
    if (!primed_) {
        gain_.reset(gain);
        pan_.reset(pan);
        mute_.reset(open);
        polarity_.reset(polarity);
        primed_ = true;
    }
    // AUTO-003 (T-074): an automated slot may jump at a loop wrap inside the block; its value
    // after the wrap is mapped like the slot value.
    WrapJump gj = wrapJump(ctx, firstParam_ + kGain);
    WrapJump pj = wrapJump(ctx, firstParam_ + kPan);
    WrapJump mj = wrapJump(ctx, firstParam_ + kMute);
    WrapJump sj = wrapJump(ctx, firstParam_ + kPhase);
    gj.value = clampGain(gj.value);
    mj.value = switchOn(mj.value) ? 0.0f : 1.0f;
    sj.value = switchOn(sj.value) ? -1.0f : 1.0f;

    // ENG-022: ramp from where the previous block ended. Phase, mute and gain are one scalar per
    // block end, combined with the pan law into one linear ramp per channel.
    const ParamRamp g = gain_.next(gain, n, gj);
    const ParamRamp p = pan_.next(pan, n, pj);
    const ParamRamp m = mute_.next(open, n, mj);
    const ParamRamp s = polarity_.next(polarity, n, sj);
    const float startGain = s.start * m.start * g.start;
    const float targetGain = s.target * m.target * g.target;
    const PanGains from = constantPowerPan(p.start);
    const PanGains to = constantPowerPan(p.target);
    // AUTO-003: with any jump, the combined ramp reaches the targets at the wrap and holds the
    // values after it (a param without a jump holds its target).
    uint32_t jumpAt = ParamRamp::kNoJump;
    for (const ParamRamp* r : {&g, &p, &m, &s})
        if (r->jumps() && r->jumpAt < jumpAt) jumpAt = r->jumpAt;
    const float afterGain = s.end() * m.end() * g.end();
    const PanGains after = constantPowerPan(p.end());
    const ParamRamp left{startGain * from.left, targetGain * to.left, n, jumpAt, afterGain * after.left};
    const ParamRamp right{startGain * from.right, targetGain * to.right, n, jumpAt, afterGain * after.right};

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
