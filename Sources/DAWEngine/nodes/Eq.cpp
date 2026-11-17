#include "nodes/Eq.h"

#include <cmath>
#include <cstddef>
#include <cstring>
#include <limits>
#include <memory>

#include "core/ProcessContext.h"
#include "dsp/Finite.h"

namespace daw {

namespace {

bool covers(const AudioBufferView& view, uint32_t n) DAW_RT { return view.numChannels > 0 && view.numFrames >= n; }

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

// The EQ's stereo input and output: a null input reads as silence, a null output is skipped.
struct StereoIO {
    const float *inL, *inR;
    float *outL, *outR;

    Double2 in(uint32_t i) const DAW_RT {
        return Double2{inL != nullptr ? double{inL[i]} : 0.0, inR != nullptr ? double{inR[i]} : 0.0};
    }
    void out(uint32_t i, Double2 y) const DAW_RT {
        if (outL != nullptr) outL[i] = static_cast<float>(y.x);
        if (outR != nullptr) outR[i] = static_cast<float>(y.y);
    }
};

// T-091: N bands with fixed coefficients over a block. N is a constant, so the chain unrolls and
// its coefficients and state stay in registers instead of going through memory every frame.
template <uint32_t N>
void runSteady(const StereoIO& io, uint32_t n, const BiquadCoeffs* coeffs, BiquadState2* state) DAW_RT {
    BiquadCoeffs c[N > 0 ? N : 1];
    BiquadState2 s[N > 0 ? N : 1];
    for (uint32_t k = 0; k < N; ++k) {
        c[k] = coeffs[k];
        s[k] = state[k];
    }
    for (uint32_t i = 0; i < n; ++i) {
        Double2 x = io.in(i);
        // DSP-040: one test per frame for every section's snap (a section's snap only has to
        // happen before its next frame, so this is tick()'s result).
        Double2 quietest = std::numeric_limits<double>::infinity();
        for (uint32_t k = 0; k < N; ++k) {
            x = s[k].step(x, c[k]);
            quietest = __builtin_elementwise_min(quietest, s[k].quietness());
        }
        if (__builtin_expect(__builtin_reduce_min(quietest) < BiquadState::kSnap, 0)) {
            __asm__ volatile("");  // keep it a branch (see BiquadState2::tick)
            for (uint32_t k = 0; k < N; ++k) s[k].snap();
        }
        io.out(i, x);
    }
    for (uint32_t k = 0; k < N; ++k) state[k] = s[k];
}

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

void Eq::reset() DAW_RT {
    // DW-063: prepare()'s state.
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

    // T-091 (TEST-008): both channels run together, one NEON lane each (BiquadState2: the same
    // arithmetic as BiquadState::tick, bit for bit). A block where no active band ramps, the
    // usual case, runs the chain with coefficients and state in registers (runSteady); a ramp
    // interpolates the coefficients per frame as before.
    BiquadState2 st[kNumBands];
    BiquadCoeffs steady[kNumBands];
    bool anyRamp = false;
    for (uint32_t k = 0; k < numActive; ++k) {
        const uint32_t b = active[k];
        st[k] = BiquadState2(state_[0][b], state_[1][b]);
        steady[k] = coeffs_[b];
        anyRamp = anyRamp || ramping[b];
    }
    const StereoIO stereo{inL, inR, outL, outR};
    if (!anyRamp) {
        switch (numActive) {
            case 0: runSteady<0>(stereo, n, steady, st); break;
            case 1: runSteady<1>(stereo, n, steady, st); break;
            case 2: runSteady<2>(stereo, n, steady, st); break;
            case 3: runSteady<3>(stereo, n, steady, st); break;
            case 4: runSteady<4>(stereo, n, steady, st); break;
            case 5: runSteady<5>(stereo, n, steady, st); break;
            default: runSteady<kNumBands>(stereo, n, steady, st); break;
        }
    } else {
        const double invFrames = 1.0 / n;
        for (uint32_t i = 0; i < n; ++i) {
            Double2 x = stereo.in(i);
            for (uint32_t k = 0; k < numActive; ++k) {
                const uint32_t b = active[k];
                // ENG-022's ramp shape: the block's last frame is exactly on the new coefficients.
                const BiquadCoeffs c = !ramping[b] || i + 1 == n
                                           ? coeffs_[b]
                                           : from[b].lerp(coeffs_[b], static_cast<double>(i + 1) * invFrames);
                x = st[k].tick(x, c);
            }
            stereo.out(i, x);
        }
    }
    for (uint32_t k = 0; k < numActive; ++k) st[k].store(state_[0][active[k]], state_[1][active[k]]);
    for (uint32_t c = 2; c < out.numChannels; ++c) std::memset(out.channels[c], 0, std::size_t{n} * sizeof(float));

    // A blow-up (a filter or a float conversion going non-finite) is treated like a bad input.
    if (!allFinite(out, n)) silence(io, n);
}

} // namespace daw
