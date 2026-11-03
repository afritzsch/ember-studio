#include "nodes/Reverb.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <memory>
#include <numbers>

#include "core/ProcessContext.h"
#include "dsp/Hadamard.h"

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

std::array<uint32_t, Reverb::kLines> lengthsFor(double size, double rate) DAW_RT {
    const double s = Reverb::kMinScale + (1.0 - Reverb::kMinScale) * std::clamp(size, 0.0, 1.0);
    std::array<uint32_t, Reverb::kLines> out{};
    for (uint32_t i = 0; i < Reverb::kLines; ++i) {
        const double frames = std::round(static_cast<double>(Reverb::kBaseFrames[i]) * s * rate / Reverb::kBaseRate);
        out[i] = frames < 1.0 ? 1u : static_cast<uint32_t>(frames);
    }
    return out;
}

// P in frames for a pre-delay of `ms`.
float predelayFrames(double ms, double rate) DAW_RT { return static_cast<float>(std::round(ms * rate / 1000.0)); }

// One step of a delay time towards its (whole-frame) target: by kGlide, landing on it exactly
// (every value is a multiple of kGlide, a power of two).
float glide(float current, float target) DAW_RT {
    const float d = target - current;
    if (d > Reverb::kGlide) return current + Reverb::kGlide;
    if (d < -Reverb::kGlide) return current - Reverb::kGlide;
    return target;
}

// The sample `delay` frames before `write` in a ring (`mask` = capacity − 1), linearly
// interpolated between whole frames.
float readAt(const float* ring, uint32_t mask, uint32_t write, float delay) DAW_RT {
    const auto k = static_cast<uint32_t>(delay);
    const float frac = delay - static_cast<float>(k);
    const float a = ring[(write - k) & mask];
    if (frac == 0.0f) return a;
    const float b = ring[(write - k - 1) & mask];
    return a + frac * (b - a);
}

float snap(float x) DAW_RT { return std::fabs(x) < Reverb::kSnap ? 0.0f : x; }

} // namespace

std::array<uint32_t, Reverb::kLines> Reverb::lineLengths(double size, double rate) { return lengthsFor(size, rate); }

NodeKindInfo Reverb::kindInfo() {
    return NodeKindInfo{[](const NodeCreateInfo& create) -> Result<std::unique_ptr<Node>> {
        return std::unique_ptr<Node>(std::make_unique<Reverb>(create.desc.firstParam, create.desc.numParams));
    }};
}

void Reverb::prepare(const PrepareInfo& info) {
    sampleRate_ = info.sampleRate > 0.0 ? info.sampleRate : 48000.0;
    // Room for the longest line (size 1) and pre-delay (200 ms) at this rate, plus the frame
    // linear interpolation reads past them.
    const uint32_t longest = lengthsFor(1.0, sampleRate_)[kLines - 1];
    lineCap_ = nextPowerOfTwo(longest + 2);
    lineMask_ = lineCap_ - 1;
    preCap_ = nextPowerOfTwo(static_cast<uint32_t>(predelayFrames(kMaxPredelayMs, sampleRate_)) + 2);
    preMask_ = preCap_ - 1;
    lines_.assign(std::size_t{lineCap_} * kLines, 0.0f);
    pre_.assign(std::size_t{preCap_} * 2, 0.0f);
    lineWrite_ = 0;
    preWrite_ = 0;
    damp_.fill(0.0f);
    size_ = -1.0f;
    primed_ = false;
}

bool Reverb::isSilent() const {
    auto zero = [](float x) { return x == 0.0f; };
    return std::all_of(lines_.begin(), lines_.end(), zero) && std::all_of(pre_.begin(), pre_.end(), zero) &&
           std::all_of(damp_.begin(), damp_.end(), zero);
}

void Reverb::clear() DAW_RT {
    if (!lines_.empty()) std::memset(lines_.data(), 0, lines_.size() * sizeof(float));
    if (!pre_.empty()) std::memset(pre_.data(), 0, pre_.size() * sizeof(float));
    damp_.fill(0.0f);
}

float Reverb::param(const ProcessContext& ctx, uint32_t index) const DAW_RT {
    const ParamInfo& info = kParamInfo[index];
    if (index >= numParams_) return info.def;
    const float v = ctx.params.get(firstParam_ + index);
    if (std::isnan(v)) return info.def;
    return v < info.min ? info.min : v > info.max ? info.max : v;
}

void Reverb::process(ProcessContext& ctx, NodeIO& io) DAW_RT {
    const AudioBufferView& in = io.audioIn;
    const AudioBufferView& out = io.audioOut;
    const uint32_t n = out.numFrames;
    if (n == 0) return;  // ENG-004: a 0-frame block leaves every state as it was

    // ENG-021: one read per slot per block.
    const float size = param(ctx, kSize);
    const float decay = param(ctx, kDecay);
    const float damping = param(ctx, kDamping);
    const float predelay = param(ctx, kPredelay);
    const float mix = param(ctx, kMix);

    const bool hasInput = covers(in, n);
    // DSP-040: NaN guard. Also covers a node that was never prepared.
    if ((hasInput && !allFinite(in, n)) || lineCap_ == 0) {
        for (uint32_t c = 0; c < out.numChannels; ++c) std::memset(out.channels[c], 0, std::size_t{n} * sizeof(float));
        clear();
        if (lineCap_ != 0) nanBlocks_.fetch_add(1, std::memory_order_relaxed);
        return;
    }

    if (size != size_) {
        const auto lengths = lengthsFor(size, sampleRate_);
        for (uint32_t i = 0; i < kLines; ++i) target_[i] = static_cast<float>(lengths[i]);
        size_ = size;
    }
    predelayTarget_ = predelayFrames(predelay, sampleRate_);
    std::array<float, kLines> gains{};
    for (uint32_t i = 0; i < kLines; ++i)
        gains[i] = static_cast<float>(std::pow(10.0, -3.0 * double{target_[i]} / (double{decay} * sampleRate_)));
    const double cutoff =
        std::min(kDampMaxHz * std::pow(kDampMinHz / kDampMaxHz, double{damping}), 0.45 * sampleRate_);
    const auto a = static_cast<float>(std::exp(-2.0 * std::numbers::pi * cutoff / sampleRate_));
    const float b = 1.0f - a;

    if (!primed_) {
        delay_ = target_;
        predelay_ = predelayTarget_;
        gains_ = gains;
        mix_.reset(mix);
        primed_ = true;
    }
    // ENG-022: decay and mix ramp from where the previous block ended.
    const ParamRamp mixRamp = mix_.next(mix, n);
    const bool gainsRamp = gains != gains_;
    std::array<float, kLines> gainStep{};
    if (gainsRamp)
        for (uint32_t i = 0; i < kLines; ++i) gainStep[i] = (gains[i] - gains_[i]) / static_cast<float>(n);

    const float* inL = hasInput ? in.channels[0] : nullptr;
    const float* inR = hasInput ? in.channels[in.numChannels > 1 ? 1 : 0] : nullptr;
    float* outL = out.numChannels > 0 ? out.channels[0] : nullptr;
    float* outR = out.numChannels > 1 ? out.channels[1] : nullptr;
    float* preL = pre_.data();
    float* preR = pre_.data() + preCap_;
    float* lines = lines_.data();
    constexpr float kNorm = 0.35355339059327373f;  // 1/√8

    for (uint32_t s = 0; s < n; ++s) {
        const float dryL = inL ? inL[s] : 0.0f;
        const float dryR = inR ? inR[s] : 0.0f;

        // Pre-delay: write, then read P frames back (P = 0 is this frame).
        preL[preWrite_] = dryL;
        preR[preWrite_] = dryR;
        predelay_ = glide(predelay_, predelayTarget_);
        const float pL = readAt(preL, preMask_, preWrite_, predelay_);
        const float pR = readAt(preR, preMask_, preWrite_, predelay_);
        preWrite_ = (preWrite_ + 1) & preMask_;

        // Line outputs (read before this frame's write: D_i ≥ 1).
        float x[kLines];
        float v[kLines];
        for (uint32_t i = 0; i < kLines; ++i) {
            delay_[i] = glide(delay_[i], target_[i]);
            x[i] = readAt(lines + std::size_t{i} * lineCap_, lineMask_, lineWrite_, delay_[i]);
            damp_[i] = snap(b * x[i] + a * damp_[i]);
            const float g = gainsRamp ? (s + 1 == n ? gains[i] : gains_[i] + gainStep[i] * static_cast<float>(s + 1))
                                      : gains[i];
            v[i] = g * damp_[i];
        }
        hadamardInPlace(v);
        for (uint32_t i = 0; i < kLines; ++i)
            lines[std::size_t{i} * lineCap_ + lineWrite_] = snap(v[i] * kNorm + ((i & 1u) == 0 ? pL : pR));
        lineWrite_ = (lineWrite_ + 1) & lineMask_;

        const float wL = kOutGain * (x[0] - x[1] + x[2] - x[3] + x[4] - x[5] + x[6] - x[7]);
        const float wR = kOutGain * (x[0] + x[1] - x[2] - x[3] + x[4] + x[5] - x[6] - x[7]);
        const float m = mixRamp.at(s);
        if (outL) outL[s] = (1.0f - m) * dryL + m * wL;
        if (outR) outR[s] = (1.0f - m) * dryR + m * wR;
    }
    gains_ = gains;
    // Channels beyond stereo are silent.
    for (uint32_t c = 2; c < out.numChannels; ++c) std::memset(out.channels[c], 0, std::size_t{n} * sizeof(float));
}

} // namespace daw
