#include "nodes/Eq.h"

#include <cmath>
#include <cstddef>
#include <cstring>
#include <memory>

#include "core/ProcessContext.h"

namespace daw {

namespace {

bool covers(const AudioBufferView& view, uint32_t n) DAW_RT { return view.numChannels > 0 && view.numFrames >= n; }

bool allFinite(const AudioBufferView& view, uint32_t n) DAW_RT {
    for (uint32_t c = 0; c < view.numChannels; ++c)
        for (uint32_t i = 0; i < n; ++i)
            if (!std::isfinite(view.channels[c][i])) return false;
    return true;
}

// Slot indices of each band's params; kNone for a param the band doesn't have.
constexpr uint32_t kNone = Eq::kNumParams;
struct BandSlots {
    uint32_t on, freq, gain, q;
};
constexpr BandSlots kBandSlots[Eq::kNumBands] = {
    {Eq::kHpOn, Eq::kHpFreq, kNone, Eq::kHpQ},
    {Eq::kLowOn, Eq::kLowFreq, Eq::kLowGain, Eq::kLowQ},
    {Eq::kPeak1On, Eq::kPeak1Freq, Eq::kPeak1Gain, Eq::kPeak1Q},
    {Eq::kPeak2On, Eq::kPeak2Freq, Eq::kPeak2Gain, Eq::kPeak2Q},
    {Eq::kHighOn, Eq::kHighFreq, Eq::kHighGain, Eq::kHighQ},
    {Eq::kLpOn, Eq::kLpFreq, kNone, Eq::kLpQ},
};

} // namespace

NodeKindInfo Eq::kindInfo(Telemetry* telemetry) {
    NodeKindInfo info{[telemetry](const NodeCreateInfo& create) -> Result<std::unique_ptr<Node>> {
        return std::unique_ptr<Node>(std::make_unique<Eq>(create.desc.firstParam, create.desc.numParams, telemetry));
    }};
    info.paramInfo = kParamInfo;  // DSP-041
    return info;
}

void Eq::prepare(const PrepareInfo& info) {
    sampleRate_ = info.sampleRate > 0.0 ? info.sampleRate : 48000.0;
    clearState();
    coeffs_.fill(BiquadCoeffs{});
    primed_ = false;
}

void Eq::clearState() DAW_RT {
    for (auto& channel : state_) channel.fill(BiquadState{});
}

float Eq::param(const ProcessContext& ctx, uint32_t index) const DAW_RT {
    const ParamInfo& info = kParamInfo[index];
    if (index >= numParams_) return info.def;
    const float v = ctx.params.get(firstParam_ + index);
    if (std::isnan(v)) return info.def;
    return v < info.min ? info.min : v > info.max ? info.max : v;
}

Eq::BandParams Eq::readBand(const ProcessContext& ctx, uint32_t band) const DAW_RT {
    const BandSlots& slots = kBandSlots[band];
    return {param(ctx, slots.on) >= 0.5f, param(ctx, slots.freq), slots.gain == kNone ? 0.0f : param(ctx, slots.gain),
            param(ctx, slots.q)};
}

BiquadCoeffs Eq::design(uint32_t band, const BandParams& p) const DAW_RT {
    if (!p.on) return BiquadCoeffs{};
    const double freq = std::fmin(double{p.freq}, kMaxFreqRatio * sampleRate_);
    switch (band) {
        case kHighPass: return biquadHighPass(freq, p.q, sampleRate_);
        case kLowShelf: return biquadLowShelf(freq, p.q, p.gain, sampleRate_);
        case kPeak1:
        case kPeak2: return biquadPeak(freq, p.q, p.gain, sampleRate_);
        case kHighShelf: return biquadHighShelf(freq, p.q, p.gain, sampleRate_);
        case kLowPass: return biquadLowPass(freq, p.q, sampleRate_);
        default: return BiquadCoeffs{};
    }
}

void Eq::silence(const NodeIO& io, uint32_t n) DAW_RT {
    for (uint32_t c = 0; c < io.audioOut.numChannels; ++c)
        std::memset(io.audioOut.channels[c], 0, std::size_t{n} * sizeof(float));
    clearState();
    nanBlocks_.fetch_add(1, std::memory_order_relaxed);
    if (telemetry_ != nullptr) telemetry_->countNanBlock();  // DW-142
}

void Eq::process(ProcessContext& ctx, NodeIO& io) DAW_RT {
    const AudioBufferView& in = io.audioIn;
    const AudioBufferView& out = io.audioOut;
    const uint32_t n = out.numFrames;
    if (n == 0) return;  // ENG-004: a 0-frame block leaves every state as it was

    // ENG-021: one read per slot per block. DSP-030: redesign only the bands that changed; the
    // block ramps from where the previous one ended to the new coefficients.
    std::array<BiquadCoeffs, kNumBands> from = coeffs_;
    bool ramping[kNumBands];
    for (uint32_t b = 0; b < kNumBands; ++b) {
        const BandParams p = readBand(ctx, b);
        if (!primed_ || !(p == params_[b])) {
            params_[b] = p;
            coeffs_[b] = design(b, p);
        }
        if (!primed_) from[b] = coeffs_[b];  // the first block jumps
        ramping[b] = !(from[b] == coeffs_[b]);
    }
    primed_ = true;

    const bool hasInput = covers(in, n);
    if (hasInput && !allFinite(in, n)) {  // DSP-040
        silence(io, n);
        return;
    }
    const float* inL = hasInput ? in.channels[0] : nullptr;
    const float* inR = hasInput ? in.channels[in.numChannels > 1 ? 1 : 0] : nullptr;

    // Bands that can't change the signal this block are skipped; they keep their zero state
    // (see BiquadCoeffs::isIdentity), so the result is the same.
    uint32_t active[kNumBands];
    uint32_t numActive = 0;
    for (uint32_t b = 0; b < kNumBands; ++b)
        if (ramping[b] || !coeffs_[b].isIdentity() || !state_[0][b].isZero() || !state_[1][b].isZero())
            active[numActive++] = b;

    const uint32_t outChannels = out.numChannels < 2 ? out.numChannels : 2;
    float* outL = outChannels > 0 ? out.channels[0] : nullptr;
    float* outR = outChannels > 1 ? out.channels[1] : nullptr;
    const double invFrames = 1.0 / n;
    for (uint32_t i = 0; i < n; ++i) {
        double l = inL != nullptr ? double{inL[i]} : 0.0;
        double r = inR != nullptr ? double{inR[i]} : 0.0;
        for (uint32_t k = 0; k < numActive; ++k) {
            const uint32_t b = active[k];
            // ENG-022's ramp shape: the block's last frame is exactly on the new coefficients.
            const BiquadCoeffs c = !ramping[b] || i + 1 == n
                                       ? coeffs_[b]
                                       : from[b].lerp(coeffs_[b], static_cast<double>(i + 1) * invFrames);
            l = state_[0][b].tick(l, c);
            r = state_[1][b].tick(r, c);
        }
        if (outL != nullptr) outL[i] = static_cast<float>(l);
        if (outR != nullptr) outR[i] = static_cast<float>(r);
    }
    for (uint32_t c = 2; c < out.numChannels; ++c) std::memset(out.channels[c], 0, std::size_t{n} * sizeof(float));

    // A blow-up (a filter or a float conversion going non-finite) is treated like a bad input.
    if (!allFinite(out, n)) silence(io, n);
}

} // namespace daw
