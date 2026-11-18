#include "nodes/Delay.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <memory>
#include <numbers>

#include "automation/WrapJump.h"
#include "core/ProcessContext.h"
#include "time/TransportSegments.h"

namespace daw {

namespace {

bool covers(const AudioBufferView& view, uint32_t n) DAW_RT { return view.numChannels > 0 && view.numFrames >= n; }

bool allFinite(const AudioBufferView& view, uint32_t n) DAW_RT {
    for (uint32_t c = 0; c < view.numChannels; ++c)
        for (uint32_t i = 0; i < n; ++i)
            if (!std::isfinite(view.channels[c][i])) return false;
    return true;
}

uint32_t nextPowerOfTwo(uint32_t n) {
    uint32_t p = 1;
    while (p < n) p *= 2;
    return p;
}

uint32_t maxDelayFrames(double rate) DAW_RT {
    return static_cast<uint32_t>(std::round(Delay::kMaxSeconds * rate));
}

float snap(float x) DAW_RT { return std::fabs(x) < Delay::kSnap ? 0.0f : x; }

} // namespace

uint32_t Delay::delayFrames(float timeMs, bool sync, float note, double bpm, double rate) DAW_RT {
    double frames = 0.0;
    if (sync) {
        const auto index = static_cast<uint32_t>(std::clamp(std::round(double{note}), 0.0, double{kNumNotes - 1}));
        if (!(bpm > 0.0) || !std::isfinite(bpm)) bpm = kFallbackBpm;
        frames = std::round(kNotes[index].beats * 60.0 * rate / bpm);
    } else {
        frames = std::round(double{timeMs} * rate / 1000.0);
    }
    const double longest = static_cast<double>(maxDelayFrames(rate));
    return static_cast<uint32_t>(std::clamp(frames, 1.0, std::max(1.0, longest)));
}

uint32_t Delay::crossfadeFrames(double rate) DAW_RT {
    const double n = std::round(kCrossfadeMs * rate / 1000.0);
    return n < 1.0 ? 1u : static_cast<uint32_t>(n);
}

NodeKindInfo Delay::kindInfo(Telemetry* telemetry) {
    NodeKindInfo info{[telemetry](const NodeCreateInfo& create) -> Result<std::unique_ptr<Node>> {
        return std::unique_ptr<Node>(
            std::make_unique<Delay>(create.desc.firstParam, create.desc.numParams, telemetry));
    }};
    info.paramInfo = kParamInfo;  // DSP-041
    return info;
}

void Delay::prepare(const PrepareInfo& info) {
    sampleRate_ = info.sampleRate > 0.0 ? info.sampleRate : 48000.0;
    maxDelay_ = std::max(1u, maxDelayFrames(sampleRate_));
    xfadeLen_ = crossfadeFrames(sampleRate_);
    cap_ = nextPowerOfTwo(maxDelay_ + 1);
    mask_ = cap_ - 1;
    line_.assign(std::size_t{cap_} * 2, 0.0f);
    write_ = 0;
    lp_.fill(0.0f);
    delay_ = target_ = xfadeTo_ = 1;
    xfadePos_ = 0;
    primed_ = false;
}

void Delay::reset() DAW_RT {
    // DW-063: prepare()'s state without allocating (the line keeps its size).
    std::fill(line_.begin(), line_.end(), 0.0f);
    write_ = 0;
    lp_.fill(0.0f);
    delay_ = target_ = xfadeTo_ = 1;
    xfadePos_ = 0;
    primed_ = false;
}

bool Delay::isSilent() const {
    return std::all_of(line_.begin(), line_.end(), [](float x) { return x == 0.0f; }) && lp_[0] == 0.0f &&
           lp_[1] == 0.0f;
}

void Delay::clear() DAW_RT {
    if (!line_.empty()) std::memset(line_.data(), 0, line_.size() * sizeof(float));
    lp_.fill(0.0f);
}

float Delay::param(const ProcessContext& ctx, uint32_t index, bool afterWrap) const DAW_RT {
    const ParamInfo& info = kParamInfo[index];
    if (index >= numParams_) return info.def;
    const float v = afterWrap ? afterWrapOr(ctx, firstParam_ + index) : ctx.params.get(firstParam_ + index);
    if (std::isnan(v)) return info.def;
    return v < info.min ? info.min : v > info.max ? info.max : v;
}

void Delay::process(ProcessContext& ctx, NodeIO& io) DAW_RT {
    const AudioBufferView& in = io.audioIn;
    const AudioBufferView& out = io.audioOut;
    const uint32_t n = out.numFrames;
    if (n == 0) return;  // ENG-004: a 0-frame block leaves every state as it was

    // ENG-021: one read per slot per block.
    const float time = param(ctx, kTime);
    const bool sync = param(ctx, kSync) >= 0.5f;
    const float note = param(ctx, kNote);
    const float feedback = param(ctx, kFeedback);
    const float lowpass = param(ctx, kLowpass);
    const bool pingPongNow = param(ctx, kPingPong) >= 0.5f;
    const float mix = param(ctx, kMix);

    const bool hasInput = covers(in, n);
    // DSP-040: NaN guard. Also covers a node that was never prepared.
    if ((hasInput && !allFinite(in, n)) || cap_ == 0) {
        for (uint32_t c = 0; c < out.numChannels; ++c) std::memset(out.channels[c], 0, std::size_t{n} * sizeof(float));
        clear();
        if (cap_ != 0) {
            nanBlocks_.fetch_add(1, std::memory_order_relaxed);
            if (telemetry_ != nullptr) telemetry_->countNanBlock();  // DW-142
        }
        return;
    }

    // DSP-032: the synced time follows the tempo at the block's start (TIME-007), while stopped
    // too (the transport's position is in seg[0] even without segments).
    const double bpm = ctx.transport.tempo ? tempoAtStart(ctx.transport) : kFallbackBpm;
    target_ = delayFrames(time, sync, note, bpm, sampleRate_);

    // The loop's lowpass for a `lowpass` value: on, a, b.
    struct Lowpass {
        bool on;
        float a, b;
    };
    auto lowpassFor = [&](float hz) DAW_RT {
        const double cutoff = std::min(double{hz}, 0.45 * sampleRate_);
        const auto a = static_cast<float>(std::exp(-2.0 * std::numbers::pi * cutoff / sampleRate_));
        return Lowpass{double{hz} < kLowpassOff, a, 1.0f - a};
    };
    Lowpass lp = lowpassFor(lowpass);
    bool pingPong = pingPongNow;

    // AUTO-003 (T-092): a loop wrap that automation jumps at. From its frame on, every param
    // holds its after-wrap value: feedback and mix through the smoothers' jump, the latched ones
    // and T below.
    const uint32_t wrap = wrapFrame(ctx, firstParam_, numParams_ < kNumParams ? numParams_ : kNumParams, n);
    WrapJump fbJump, mixJump;
    if (wrap > 0) {
        fbJump = WrapJump{wrap, param(ctx, kFeedback, true)};
        mixJump = WrapJump{wrap, param(ctx, kMix, true)};
    }

    if (!primed_) {
        delay_ = xfadeTo_ = target_;
        xfadePos_ = 0;
        feedback_.reset(feedback);
        mix_.reset(mix);
        primed_ = true;
    }
    // ENG-022: feedback and mix ramp from where the previous block ended.
    const ParamRamp fbRamp = feedback_.next(feedback, n, fbJump);
    const ParamRamp mixRamp = mix_.next(mix, n, mixJump);
    const auto xfadeLen = static_cast<float>(xfadeLen_);

    const float* inL = hasInput ? in.channels[0] : nullptr;
    const float* inR = hasInput ? in.channels[in.numChannels > 1 ? 1 : 0] : nullptr;
    float* outL = out.numChannels > 0 ? out.channels[0] : nullptr;
    float* outR = out.numChannels > 1 ? out.channels[1] : nullptr;
    float* lineL = line_.data();
    float* lineR = line_.data() + cap_;

    for (uint32_t s = 0; s < n; ++s) {
        if (s == wrap && wrap > 0) {  // AUTO-003: the latched params and T after the wrap
            lp = lowpassFor(param(ctx, kLowpass, true));
            pingPong = param(ctx, kPingPong, true) >= 0.5f;
            target_ = delayFrames(param(ctx, kTime, true), param(ctx, kSync, true) >= 0.5f, param(ctx, kNote, true),
                                  bpm, sampleRate_);
        }
        const float dryL = inL ? inL[s] : 0.0f;
        const float dryR = inR ? inR[s] : 0.0f;

        // Taps (D ≥ 1: read before this frame's write). A new T starts a crossfade once the
        // running one (if any) has ended.
        if (xfadeTo_ == delay_ && target_ != delay_) {
            xfadeTo_ = target_;
            xfadePos_ = 0;
        }
        float xL = lineL[(write_ - delay_) & mask_];
        float xR = lineR[(write_ - delay_) & mask_];
        if (xfadeTo_ != delay_) {
            ++xfadePos_;
            const float w = static_cast<float>(xfadePos_) / xfadeLen;
            const float toL = lineL[(write_ - xfadeTo_) & mask_];
            const float toR = lineR[(write_ - xfadeTo_) & mask_];
            xL = (1.0f - w) * xL + w * toL;
            xR = (1.0f - w) * xR + w * toR;
            if (xfadePos_ >= xfadeLen_) {
                delay_ = xfadeTo_;
                xfadePos_ = 0;
            }
        }

        // Lowpass in the loop.
        if (lp.on) {
            lp_[0] = snap(lp.b * xL + lp.a * lp_[0]);
            lp_[1] = snap(lp.b * xR + lp.a * lp_[1]);
        } else {
            lp_[0] = snap(xL);
            lp_[1] = snap(xR);
        }
        const float fb = fbRamp.at(s);
        if (pingPong) {
            lineL[write_] = snap(0.5f * (dryL + dryR) + fb * lp_[1]);
            lineR[write_] = snap(fb * lp_[0]);
        } else {
            lineL[write_] = snap(dryL + fb * lp_[0]);
            lineR[write_] = snap(dryR + fb * lp_[1]);
        }
        write_ = (write_ + 1) & mask_;

        const float m = mixRamp.at(s);
        if (outL) outL[s] = (1.0f - m) * dryL + m * xL;
        if (outR) outR[s] = (1.0f - m) * dryR + m * xR;
    }
    // Channels beyond stereo are silent.
    for (uint32_t c = 2; c < out.numChannels; ++c) std::memset(out.channels[c], 0, std::size_t{n} * sizeof(float));
}

} // namespace daw
