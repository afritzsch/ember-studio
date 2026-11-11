#include "nodes/Compressor.h"

#include <cmath>
#include <cstddef>
#include <cstring>
#include <memory>
#include <numbers>

#include "core/ProcessContext.h"
#include "dsp/GainComputer.h"

namespace daw {

namespace {

// A block's audio is usable as `view` only if it has channels and covers the block.
bool covers(const AudioBufferView& view, uint32_t n) DAW_RT { return view.numChannels > 0 && view.numFrames >= n; }

bool allFinite(const AudioBufferView& view, uint32_t n) DAW_RT {
    for (uint32_t c = 0; c < view.numChannels; ++c)
        for (uint32_t i = 0; i < n; ++i)
            if (!std::isfinite(view.channels[c][i])) return false;
    return true;
}

// α for a one-pole with time constant `ms` (exp(−1/(τ·rate))); 0 ms is instant.
double onePole(double ms, double rate) DAW_RT { return ms > 0.0 ? std::exp(-1000.0 / (ms * rate)) : 0.0; }

// A ParamRamp's value at frame i, with the step computed once per block (ParamRamp::at).
struct Ramp {
    double start, step, target;
    uint32_t last;
    explicit Ramp(const ParamRamp& r) DAW_RT
        : start(r.start), step(r.numFrames ? (double{r.target} - r.start) / r.numFrames : 0.0), target(r.target),
          last(r.numFrames ? r.numFrames - 1 : 0) {}
    double at(uint32_t i) const DAW_RT { return i == last ? target : start + step * static_cast<double>(i + 1); }
};

constexpr double kDbToNat = std::numbers::ln10 / 20.0;  // 10^(x/20) = exp(x · kDbToNat)

} // namespace

NodeKindInfo Compressor::kindInfo(Telemetry* telemetry) {
    NodeKindInfo info{[telemetry](const NodeCreateInfo& create) -> Result<std::unique_ptr<Node>> {
        const MeterTarget meter =
            telemetry && create.meter != kNoMeter ? MeterTarget{telemetry, create.meter} : MeterTarget{};
        return std::unique_ptr<Node>(
            std::make_unique<Compressor>(create.desc.firstParam, create.desc.numParams, meter, telemetry));
    }};
    info.meters = true;  // DSP-031: the gain-reduction meter
    info.paramInfo = kParamInfo;  // DSP-041
    return info;
}

void Compressor::reset() DAW_RT {
    // DW-063: prepare()'s state.
    env_ = 0.0;
    ms_ = 0.0;
    primed_ = false;
}

void Compressor::prepare(const PrepareInfo& info) {
    sampleRate_ = info.sampleRate > 0.0 ? info.sampleRate : 48000.0;
    rmsCoeff_ = onePole(kRmsMs, sampleRate_);
    env_ = 0.0;
    ms_ = 0.0;
    primed_ = false;
}

float Compressor::param(const ProcessContext& ctx, uint32_t index) const DAW_RT {
    const ParamInfo& info = kParamInfo[index];
    if (index >= numParams_) return info.def;
    const float v = ctx.params.get(firstParam_ + index);
    if (std::isnan(v)) return info.def;
    return v < info.min ? info.min : v > info.max ? info.max : v;
}

void Compressor::process(ProcessContext& ctx, NodeIO& io) DAW_RT {
    const AudioBufferView& in = io.audioIn;
    const AudioBufferView& out = io.audioOut;
    const uint32_t n = out.numFrames;
    if (n == 0) return;  // ENG-004: a 0-frame block leaves every state as it was

    // ENG-021: one read per slot per block.
    const float threshold = param(ctx, kThreshold);
    const float ratio = param(ctx, kRatio);
    const float knee = param(ctx, kKnee);
    const float makeup = param(ctx, kMakeup);
    const double attack = onePole(param(ctx, kAttack), sampleRate_);
    const double release = onePole(param(ctx, kRelease), sampleRate_);
    const bool rms = param(ctx, kDetector) >= 0.5f;
    if (!primed_) {
        threshold_.reset(threshold);
        ratio_.reset(ratio);
        knee_.reset(knee);
        makeup_.reset(makeup);
        primed_ = true;
    }
    // ENG-022: ramp from where the previous block ended.
    const Ramp t(threshold_.next(threshold, n));
    const Ramp r(ratio_.next(ratio, n));
    const Ramp w(knee_.next(knee, n));
    const Ramp g(makeup_.next(makeup, n));

    // MIX-008: the routed sidechain keys the detector; without one the input does.
    const bool hasInput = covers(in, n);
    const AudioBufferView* key = covers(io.sidechain, n) ? &io.sidechain : hasInput ? &in : nullptr;

    // DSP-040: NaN guard.
    if ((hasInput && !allFinite(in, n)) || (key != nullptr && !allFinite(*key, n))) {
        for (uint32_t c = 0; c < out.numChannels; ++c) std::memset(out.channels[c], 0, std::size_t{n} * sizeof(float));
        env_ = 0.0;
        ms_ = 0.0;
        nanBlocks_.fetch_add(1, std::memory_order_relaxed);
        if (telemetry_ != nullptr) telemetry_->countNanBlock();  // DW-142
        if (meter_.telemetry != nullptr) meter_.telemetry->writeMeter(meter_.id, 1.0f, 1.0f);
        return;
    }

    const uint32_t keyChannels = key != nullptr ? key->numChannels : 0;
    const uint32_t gainChannels = hasInput ? (in.numChannels < out.numChannels ? in.numChannels : out.numChannels) : 0;
    const double invKeyChannels = keyChannels > 0 ? 1.0 / keyChannels : 0.0;
    double deepest = 0.0;  // the block's deepest e, for the meter
    for (uint32_t i = 0; i < n; ++i) {
        double x = kFloorDb;
        if (rms) {
            double sum = 0.0;
            for (uint32_t c = 0; c < keyChannels; ++c) {
                const double k = key->channels[c][i];
                sum += k * k;
            }
            ms_ = rmsCoeff_ * ms_ + (1.0 - rmsCoeff_) * sum * invKeyChannels;
            if (ms_ < kSnapMs) ms_ = 0.0;
            if (ms_ > 0.0) x = 10.0 * std::log10(ms_);
        } else {
            double peak = 0.0;
            for (uint32_t c = 0; c < keyChannels; ++c) {
                const double k = std::fabs(double{key->channels[c][i]});
                if (k > peak) peak = k;
            }
            if (peak > 0.0) x = 20.0 * std::log10(peak);
        }
        if (x < kFloorDb) x = kFloorDb;

        const double c = compressorGainDb(x, t.at(i), r.at(i), w.at(i));
        const double a = c < env_ ? attack : release;
        env_ = a * env_ + (1.0 - a) * c;
        if (env_ > -kSnapDb) env_ = 0.0;
        if (env_ < deepest) deepest = env_;

        const double totalDb = env_ + g.at(i);
        const float gain = totalDb == 0.0 ? 1.0f : static_cast<float>(std::exp(totalDb * kDbToNat));
        for (uint32_t ch = 0; ch < gainChannels; ++ch) out.channels[ch][i] = in.channels[ch][i] * gain;
    }
    // Channels the input lacks are silent.
    for (uint32_t c = gainChannels; c < out.numChannels; ++c)
        std::memset(out.channels[c], 0, std::size_t{n} * sizeof(float));

    if (meter_.telemetry != nullptr)
        meter_.telemetry->writeMeter(meter_.id, static_cast<float>(std::exp(deepest * kDbToNat)),
                                     static_cast<float>(std::exp(env_ * kDbToNat)));
}

} // namespace daw
