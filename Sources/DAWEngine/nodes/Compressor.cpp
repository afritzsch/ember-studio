#include "nodes/Compressor.h"

#include <bit>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <limits>
#include <memory>
#include <numbers>

#include "automation/WrapJump.h"
#include "core/ProcessContext.h"
#include "dsp/Finite.h"
#include "dsp/FastDb.h"
#include "dsp/GainComputer.h"

namespace daw {

namespace {

// A block's audio is usable as `view` only if it has channels and covers the block.
bool covers(const AudioBufferView& view, uint32_t n) DAW_RT { return view.numChannels > 0 && view.numFrames >= n; }

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
    attackMs_ = releaseMs_ = std::numeric_limits<float>::quiet_NaN();  // the rate may have changed
    env_ = 0.0;
    ms_ = 0.0;
    primed_ = false;
}

float Compressor::param(const ProcessContext& ctx, uint32_t index, bool afterWrap) const DAW_RT {
    const ParamInfo& info = kParamInfo[index];
    if (index >= numParams_) return info.def;
    const float v = afterWrap ? afterWrapOr(ctx, firstParam_ + index) : ctx.params.get(firstParam_ + index);
    if (std::isnan(v)) return info.def;
    return v < info.min ? info.min : v > info.max ? info.max : v;
}

Compressor::Settings Compressor::settings(const ProcessContext& ctx, bool afterWrap) const DAW_RT {
    return Settings{param(ctx, kThreshold, afterWrap), param(ctx, kRatio, afterWrap),    param(ctx, kKnee, afterWrap),
                    param(ctx, kMakeup, afterWrap),    param(ctx, kAttack, afterWrap),   param(ctx, kRelease, afterWrap),
                    param(ctx, kDetector, afterWrap) >= 0.5f};
}

void Compressor::process(ProcessContext& ctx, NodeIO& io) DAW_RT {
    const AudioBufferView& in = io.audioIn;
    const AudioBufferView& out = io.audioOut;
    const uint32_t n = out.numFrames;
    if (n == 0) return;  // ENG-004: a 0-frame block leaves every state as it was

    // ENG-021: one read per slot per block. AUTO-003 (T-092): with a loop wrap that automation
    // jumps at, the block runs in two spans, the second with the after-wrap values.
    const Settings before = settings(ctx, false);
    const uint32_t wrap = wrapFrame(ctx, firstParam_, numParams_ < kNumParams ? numParams_ : kNumParams, n);
    const Settings after = wrap > 0 ? settings(ctx, true) : before;

    // MIX-008: the routed sidechain keys the detector; without one the input does.
    const bool hasInput = covers(in, n);
    const AudioBufferView* key = covers(io.sidechain, n) ? &io.sidechain : hasInput ? &in : nullptr;

    // DSP-040: NaN guard.
    if ((hasInput && !allFinite(in, n)) || (key != nullptr && key != &in && !allFinite(*key, n))) {
        // ENG-022: the smoothers end where this block's ramps would have.
        const Settings& last = wrap > 0 ? after : before;
        if (!primed_ || wrap > 0) {
            threshold_.reset(last.threshold);
            ratio_.reset(last.ratio);
            knee_.reset(last.knee);
            makeup_.reset(last.makeup);
            primed_ = true;
        } else {
            threshold_.next(last.threshold, n);
            ratio_.next(last.ratio, n);
            knee_.next(last.knee, n);
            makeup_.next(last.makeup, n);
        }
        for (uint32_t c = 0; c < out.numChannels; ++c) std::memset(out.channels[c], 0, std::size_t{n} * sizeof(float));
        env_ = 0.0;
        ms_ = 0.0;
        nanBlocks_.fetch_add(1, std::memory_order_relaxed);
        if (telemetry_ != nullptr) telemetry_->countNanBlock();  // DW-142
        if (meter_.telemetry != nullptr) meter_.telemetry->writeMeter(meter_.id, 1.0f, 1.0f);
        return;
    }

    double deepest = run(io, key, 0, wrap > 0 ? wrap : n, before, !primed_);
    primed_ = true;
    if (wrap > 0) {
        const double second = run(io, key, wrap, n - wrap, after, true);
        deepest = second < deepest ? second : deepest;
    }

    // Channels the input lacks are silent.
    const uint32_t gainChannels = hasInput ? (in.numChannels < out.numChannels ? in.numChannels : out.numChannels) : 0;
    for (uint32_t c = gainChannels; c < out.numChannels; ++c)
        std::memset(out.channels[c], 0, std::size_t{n} * sizeof(float));

    if (meter_.telemetry != nullptr)
        meter_.telemetry->writeMeter(meter_.id, static_cast<float>(std::exp(deepest * kDbToNat)),
                                     static_cast<float>(std::exp(env_ * kDbToNat)));
}

double Compressor::run(const NodeIO& io, const AudioBufferView* key, uint32_t offset, uint32_t len, const Settings& s,
                       bool jump) DAW_RT {
    const AudioBufferView& in = io.audioIn;
    const AudioBufferView& out = io.audioOut;
    const bool hasInput = covers(in, out.numFrames);  // as process() decided
    if (s.attackMs != attackMs_) {
        attackMs_ = s.attackMs;
        attackCoeff_ = onePole(s.attackMs, sampleRate_);
    }
    if (s.releaseMs != releaseMs_) {
        releaseMs_ = s.releaseMs;
        releaseCoeff_ = onePole(s.releaseMs, sampleRate_);
    }
    const double attack = attackCoeff_;
    const double release = releaseCoeff_;
    const bool rms = s.rms;
    if (jump) {
        threshold_.reset(s.threshold);
        ratio_.reset(s.ratio);
        knee_.reset(s.knee);
        makeup_.reset(s.makeup);
    }
    // ENG-022: ramp from where the previous block (or span) ended. Ramp::at takes the frame
    // within the span.
    const Ramp t(threshold_.next(s.threshold, len));
    const Ramp r(ratio_.next(s.ratio, len));
    const Ramp w(knee_.next(s.knee, len));
    const Ramp g(makeup_.next(s.makeup, len));
    const uint32_t keyChannels = key != nullptr ? key->numChannels : 0;
    const uint32_t gainChannels = hasInput ? (in.numChannels < out.numChannels ? in.numChannels : out.numChannels) : 0;
    const double invKeyChannels = keyChannels > 0 ? 1.0 / keyChannels : 0.0;

    // T-091 (TEST-008): the block runs in chunks, each in passes: the detector (serial for RMS,
    // cheap), its level in dB for the whole chunk (vectorized, dsp/FastDb.h), the gain computer
    // and ballistics (serial, cheap), the gains for the whole chunk (vectorized), then the
    // multiply. Every sample goes through the same operations as one at a time would, so the
    // result doesn't depend on block size (ENG-004).
    //
    // A block whose curve doesn't ramp keeps one GainCurve. Then a chunk whose key stays below
    // the knee while the envelope rests at 0 dB needs neither: c = 0 and e stays 0, so its gain
    // is the makeup alone. The level test is on the linear level, against the knee's lower edge
    // lowered by a relative 1e-9 (1e-8 dB), so a sample it lets through is below the edge in dB
    // too, whatever the rounding.
    const bool steadyCurve = t.step == 0.0 && r.step == 0.0 && w.step == 0.0 && t.start == t.target &&
                             r.start == r.target && w.start == w.target;
    const GainCurve curve(t.target, r.target, w.target);
    const bool steadyMakeup = g.step == 0.0 && g.start == g.target;
    const double kneeEdgeDb = t.target - w.target / 2.0;
    // The level the edge is in: amplitude for peak, power (m) for RMS.
    const double kneeEdge = (1.0 - 1e-9) * fastdb::exp(kneeEdgeDb * (rms ? 2.0 : 1.0) * fastdb::kNeperPerDb);
    const bool canRest = steadyCurve && steadyMakeup;
    const double makeupGain = g.target == 0.0 ? 1.0 : fastdb::dbToAmplitude(g.target);
    const double levelToDb = rms ? fastdb::kDbPerNeper / 2.0 : fastdb::kDbPerNeper;  // 10·log10 m, 20·log10 |k|

    constexpr uint32_t kChunk = 64;
    double level[kChunk];  // detector level (amplitude or power), then x in dB
    double gains[kChunk];  // e + makeup in dB, then the linear gain
    double deepest = 0.0;  // the block's deepest e, for the meter
    const uint32_t end = offset + len;
    for (uint32_t base = offset; base < end; base += kChunk) {
        const uint32_t m = end - base < kChunk ? end - base : kChunk;

        // Detector.
        double loudest = 0.0;
        if (rms) {
            for (uint32_t i = 0; i < m; ++i) {
                double sum = 0.0;
                for (uint32_t c = 0; c < keyChannels; ++c) {
                    const double k = key->channels[c][base + i];
                    sum += k * k;
                }
                ms_ = rmsCoeff_ * ms_ + (1.0 - rmsCoeff_) * sum * invKeyChannels;
                if (ms_ < kSnapMs) ms_ = 0.0;
                level[i] = ms_;
            }
        } else if (keyChannels == 1 || keyChannels == 2) {
            // One pass: max(|L|, |R|) in float (the same value as in double), and the chunk's
            // loudest by the bit patterns, which order like the values for non-negative floats
            // (and make an integer max, which vectorizes).
            const float* k0 = key->channels[0] + base;
            const float* k1 = key->channels[keyChannels - 1] + base;
            uint32_t loudBits = 0;
            for (uint32_t i = 0; i < m; ++i) {
                const float a = std::fabs(k0[i]), b = std::fabs(k1[i]);
                const float v = a > b ? a : b;
                level[i] = v;
                const uint32_t bits = std::bit_cast<uint32_t>(v);
                loudBits = bits > loudBits ? bits : loudBits;
            }
            loudest = std::bit_cast<float>(loudBits);
        } else {
            for (uint32_t i = 0; i < m; ++i) level[i] = 0.0;
            for (uint32_t c = 0; c < keyChannels; ++c) {
                const float* k = key->channels[c] + base;
                for (uint32_t i = 0; i < m; ++i) {
                    const double v = std::fabs(double{k[i]});
                    level[i] = v > level[i] ? v : level[i];
                }
            }
        }
        if (rms || keyChannels > 2)
            for (uint32_t i = 0; i < m; ++i) loudest = level[i] > loudest ? level[i] : loudest;

        if (canRest && env_ == 0.0 && loudest < kneeEdge) {
            // Below the knee at rest: the gain is the makeup alone.
            const float gain = static_cast<float>(makeupGain);
            for (uint32_t ch = 0; ch < gainChannels; ++ch) {
                const float* src = in.channels[ch] + base;
                float* dst = out.channels[ch] + base;
                for (uint32_t i = 0; i < m; ++i) dst[i] = src[i] * gain;
            }
            continue;
        }

        // Level in dB, floored (a level of 0 reads as the floor), and the gain computer's c,
        // which doesn't depend on the envelope.
        if (steadyCurve) {
#pragma clang loop interleave_count(4)
            for (uint32_t i = 0; i < m; ++i) {
                const double v = level[i];
                const double x = fastdb::ln(v > 0.0 ? v : 1.0) * levelToDb;
                level[i] = curve.gainDb(v > 0.0 && x > kFloorDb ? x : kFloorDb);
            }
        } else {
#pragma clang loop interleave_count(4)
            for (uint32_t i = 0; i < m; ++i) {
                const double v = level[i];
                const double x = fastdb::ln(v > 0.0 ? v : 1.0) * levelToDb;
                level[i] = v > 0.0 && x > kFloorDb ? x : kFloorDb;
            }
            for (uint32_t i = 0; i < m; ++i) {
                const uint32_t f = base + i - offset;
                level[i] = compressorGainDb(level[i], t.at(f), r.at(f), w.at(f));
            }
        }

        // Ballistics, the only serial part: both candidate steps, then a select (attack and
        // release alternate within a waveform's cycle, so a branch there would mispredict).
        for (uint32_t i = 0; i < m; ++i) {
            const double c = level[i];
            const double attacked = attack * env_ + (1.0 - attack) * c;
            const double released = release * env_ + (1.0 - release) * c;
            env_ = c < env_ ? attacked : released;
            // The snap is a branch, off the env → env chain: never taken while compressing,
            // steadily taken at rest. (The empty asm keeps the compiler from turning it back
            // into a select, which would put a compare and a select on the chain.)
            if (__builtin_expect(env_ > -kSnapDb, 0)) {
                __asm__ volatile("");
                env_ = 0.0;
            }
            deepest = env_ < deepest ? env_ : deepest;
            gains[i] = env_ + g.at(base + i - offset);
        }

        // Gains, then the multiply.
#pragma clang loop interleave_count(4)
        for (uint32_t i = 0; i < m; ++i) {
            const double db = gains[i];
            gains[i] = db == 0.0 ? 1.0 : fastdb::dbToAmplitude(db);
        }
        for (uint32_t ch = 0; ch < gainChannels; ++ch) {
            const float* src = in.channels[ch] + base;
            float* dst = out.channels[ch] + base;
            for (uint32_t i = 0; i < m; ++i) dst[i] = src[i] * static_cast<float>(gains[i]);
        }
    }
    return deepest;
}

} // namespace daw
