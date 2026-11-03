// T-071 checks for the built-in compressor (DSP-031, DSP-040, DSP-041, MIX-008). Run from
// Tests/DAWEngineTests/CompressorTests.swift; see CompressorChecks.h for why they're C++.
//
// The oracle below is written from the 06 spec text (Compressor.h's signal path), independently
// of nodes/Compressor.cpp and dsp/GainComputer.h: its static curve is the piecewise form
// "below the knee / above the knee / quadratic in between", in a different branch order.

#include "CompressorChecks.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <functional>
#include <limits>
#include <numbers>
#include <random>
#include <string>
#include <vector>

#include "NodeTestHarness.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/ProcessContext.h"
#include "core/RtTrap.h"
#include "core/Telemetry.h"
#include "daw/EngineFacade.h"
#include "dsp/GainComputer.h"
#include "nodes/Compressor.h"
#include "time/TempoMap.h"

using namespace daw;
using namespace daw::testing::nodes;

namespace daw::testing {

namespace {

using C = Compressor;

bool near(double a, double b, double tol) { return std::fabs(a - b) <= tol; }
double toDb(double gain) { return 20.0 * std::log10(gain); }
double fromDb(double db) { return std::pow(10.0, db / 20.0); }

// The 06 static curve, piecewise in x (dB): unity below the knee, T + (x − T)/R above it,
// quadratic inside. Returns the gain change y − x.
double curveDb(double x, double t, double r, double w) {
    if (x <= t - w / 2) return 0.0;
    if (x >= t + w / 2) return (t + (x - t) / r) - x;
    const double d = x - t + w / 2;
    return (1.0 / r - 1.0) * d * d / (2.0 * w);
}

struct Settings {
    float threshold = -20.0f, ratio = 4.0f, attack = 10.0f, release = 100.0f, knee = 6.0f, makeup = 0.0f;
    bool rms = false;
};

// Per-sample model of Compressor.h's signal path (no snapping: it changes values by < 1e-9 dB).
struct Oracle {
    double env = 0.0, ms = 0.0;
    double prevT = 0, prevR = 0, prevW = 0, prevG = 0;
    bool primed = false;

    // One block: `key[c][i]`, the block's settings; returns the gain (linear) per frame.
    std::vector<double> block(const std::vector<std::vector<float>>& key, uint32_t n, const Settings& s) {
        std::vector<double> gains(n);
        if (n == 0) return gains;
        if (!primed) {
            prevT = s.threshold, prevR = s.ratio, prevW = s.knee, prevG = s.makeup;
            primed = true;
        }
        auto ramp = [n](double from, float to, uint32_t i) {
            return i + 1 == n ? double{to} : from + (double{to} - from) / n * static_cast<double>(i + 1);
        };
        auto coeff = [](double ms) { return std::exp(-1.0 / (ms / 1000.0 * kRate)); };
        const double aA = coeff(s.attack), aR = coeff(s.release), beta = coeff(C::kRmsMs);
        for (uint32_t i = 0; i < n; ++i) {
            double x;
            if (s.rms) {
                double sum = 0;
                for (const auto& ch : key) sum += double{ch[i]} * ch[i];
                ms = beta * ms + (1 - beta) * (key.empty() ? 0.0 : sum / static_cast<double>(key.size()));
                x = ms > 0 ? 10 * std::log10(ms) : C::kFloorDb;
            } else {
                double peak = 0;
                for (const auto& ch : key) peak = std::max(peak, std::fabs(double{ch[i]}));
                x = peak > 0 ? 20 * std::log10(peak) : C::kFloorDb;
            }
            x = std::max(x, C::kFloorDb);
            const double c = curveDb(x, ramp(prevT, s.threshold, i), ramp(prevR, s.ratio, i), ramp(prevW, s.knee, i));
            const double a = c < env ? aA : aR;
            env = a * env + (1 - a) * c;
            gains[i] = fromDb(env + ramp(prevG, s.makeup, i));
        }
        prevT = s.threshold, prevR = s.ratio, prevW = s.knee, prevG = s.makeup;
        return gains;
    }
};

// Drives a Compressor directly. Inputs and keys are per channel; an empty key means no sidechain.
struct CompRig {
    explicit CompRig(uint32_t numParams = C::kNumParams, MeterTarget meter = {})
        : params(16), node(0, numParams, meter) {
        trapInstalled = RtTrap::install();  // no Engine here to install it (ENG-030)
        (void)params.allocate(C::kNumParams, 0.0f);
        for (const ParamInfo& p : C::kParamInfo) params.set(p.index, p.def);
        node.prepare(PrepareInfo{kRate, kMaxBlock, 2, 2});
    }

    void apply(const Settings& s) {
        params.set(C::kThreshold, s.threshold);
        params.set(C::kRatio, s.ratio);
        params.set(C::kAttack, s.attack);
        params.set(C::kRelease, s.release);
        params.set(C::kKnee, s.knee);
        params.set(C::kMakeup, s.makeup);
        params.set(C::kDetector, s.rms ? 1.0f : 0.0f);
    }

    // Processes frames [from, from + n) of `in` (and `key`) and appends the output.
    void process(const std::vector<std::vector<float>>& in, const std::vector<std::vector<float>>& key, size_t from,
                 uint32_t n) {
        std::vector<std::vector<float>> inBuf(in.size()), keyBuf(key.size());
        std::vector<float*> inPtr, keyPtr;
        for (size_t c = 0; c < in.size(); ++c) {
            inBuf[c].assign(in[c].begin() + static_cast<std::ptrdiff_t>(from),
                            in[c].begin() + static_cast<std::ptrdiff_t>(from + n));
            inPtr.push_back(inBuf[c].data());
        }
        for (size_t c = 0; c < key.size(); ++c) {
            keyBuf[c].assign(key[c].begin() + static_cast<std::ptrdiff_t>(from),
                             key[c].begin() + static_cast<std::ptrdiff_t>(from + n));
            keyPtr.push_back(keyBuf[c].data());
        }
        std::vector<float> l(n, -99.0f), r(n, -99.0f);
        float* out[2] = {l.data(), r.data()};
        NodeIO io;
        io.audioIn = AudioBufferView{inPtr.data(), static_cast<uint32_t>(inPtr.size()), n};
        io.audioOut = AudioBufferView{out, 2, n};
        if (!keyPtr.empty()) io.sidechain = AudioBufferView{keyPtr.data(), static_cast<uint32_t>(keyPtr.size()), n};
        TransportBlock block{false, false, 0, {}, &tempo};
        ProcessContext ctx{n, kRate, block, params};
        {
            RtScope scope;
            node.process(ctx, io);
            violations += scope.violations();
        }
        left.insert(left.end(), l.begin(), l.end());
        right.insert(right.end(), r.begin(), r.end());
    }

    // The whole signal in blocks from `nextBlock()`.
    void run(const std::vector<std::vector<float>>& in, const std::vector<std::vector<float>>& key,
             const std::function<uint32_t()>& nextBlock) {
        const size_t total = in.empty() ? 0 : in[0].size();
        size_t pos = 0;
        for (int guard = 0; pos < total && guard < 1'000'000; ++guard) {
            const auto n = static_cast<uint32_t>(std::min<size_t>(nextBlock(), total - pos));
            process(in, key, pos, n);
            pos += n;
        }
    }

    ParamSlotTable params;
    Compressor node;
    TempoMap tempo;
    std::vector<float> left, right;
    uint64_t violations = 0;
    bool trapInstalled = false;
};

std::vector<float> constant(size_t n, float v) { return std::vector<float>(n, v); }

std::vector<float> sine(size_t n, double hz, double amp, double phase = 0.0) {
    std::vector<float> s(n);
    for (size_t i = 0; i < n; ++i)
        s[i] = static_cast<float>(amp * std::sin(2 * std::numbers::pi * hz * static_cast<double>(i) / kRate + phase));
    return s;
}

// Deterministic noise in bursts of different levels (−50 … 0 dBFS), with silent gaps.
std::vector<float> bursts(size_t n, uint32_t seed) {
    std::mt19937 rng(seed);
    std::uniform_real_distribution<float> u(-1.0f, 1.0f);
    std::uniform_real_distribution<double> levelDb(-50.0, 0.0);
    std::vector<float> s(n, 0.0f);
    size_t i = 0;
    while (i < n) {
        const size_t len = 500 + rng() % 6000;
        const bool gap = rng() % 4 == 0;
        const auto amp = static_cast<float>(fromDb(levelDb(rng)));
        for (size_t k = 0; k < len && i < n; ++k, ++i) s[i] = gap ? 0.0f : amp * u(rng);
    }
    return s;
}

double maxError(const std::vector<float>& out, const std::vector<float>& in, const std::vector<double>& gain,
                   size_t from = 0) {
    double worst = 0;
    for (size_t i = from; i < out.size(); ++i)
        worst = std::max(worst, std::fabs(double{out[i]} - double{in[i]} * gain[i]));
    return worst;
}

} // namespace

CheckResult compressorParams() {
    CheckResult checks;
    DAW_CHECK(C::kNumParams == 7);
    for (uint32_t i = 0; i < C::kNumParams; ++i) {
        const ParamInfo& p = C::kParamInfo[i];
        DAW_CHECK(p.index == i);
        DAW_CHECK(p.min <= p.def && p.def <= p.max);
    }
    DAW_CHECK(C::kParamInfo[C::kThreshold].def == -20.0f && C::kParamInfo[C::kRatio].def == 4.0f);
    DAW_CHECK(C::kParamInfo[C::kMakeup].def == 0.0f && C::kParamInfo[C::kDetector].def == 0.0f);
    DAW_CHECK(C::kindInfo(nullptr).meters);  // DSP-031: the GR meter
    DAW_CHECK(C(0, 0).latencySamples() == 0);  // no lookahead

    // DSP-041: the table reaches the model through the facade.
    DriverConfigPOD config;
    config.sampleRate = kRate;
    if (EngineFacade* facade = EngineFacade::create(EngineMode::offline, config)) {
        const std::string json = facade->paramInfoJSON(NodeKind::compressor);
        DAW_CHECK(json.find("\"index\":0,\"id\":\"threshold\"") != std::string::npos);
        DAW_CHECK(json.find("\"index\":1,\"id\":\"ratio\"") != std::string::npos);
        DAW_CHECK(json.find("\"index\":2,\"id\":\"attack\"") != std::string::npos);
        DAW_CHECK(json.find("\"index\":3,\"id\":\"release\"") != std::string::npos);
        DAW_CHECK(json.find("\"index\":4,\"id\":\"knee\"") != std::string::npos);
        DAW_CHECK(json.find("\"index\":5,\"id\":\"makeup\"") != std::string::npos);
        DAW_CHECK(json.find("\"index\":6,\"id\":\"detector\"") != std::string::npos);
        DAW_CHECK(json.find("\"default\":-20.000000") != std::string::npos);
        releaseFacade(facade);
    } else {
        DAW_CHECK(false);
    }

    // Defaults: numParams 0, NaN slots and default slot values all render the same; clamping.
    const auto in = sine(4096, 441, 0.9);
    auto renderWith = [&](uint32_t numParams, const std::function<void(ParamSlotTable&)>& set) {
        CompRig rig(numParams);
        set(rig.params);
        rig.run({in, in}, {}, [] { return 512u; });
        DAW_CHECK(rig.violations == 0);
        DAW_CHECK(rig.trapInstalled || !DAW_RT_TRAP);  // otherwise the scopes count nothing
        return rig.left;
    };
    const auto defaults = renderWith(C::kNumParams, [](ParamSlotTable&) {});
    DAW_CHECK(defaults != in);  // 0.9 peak is above −20 dB: it compresses
    DAW_CHECK(renderWith(0, [](ParamSlotTable& p) { p.set(C::kThreshold, -60.0f); }) == defaults);
    DAW_CHECK(renderWith(C::kNumParams, [](ParamSlotTable& p) {
                  for (uint32_t i = 0; i < C::kNumParams; ++i) p.set(i, std::nanf(""));
              }) == defaults);
    // Out of range: threshold +10 → 0 dB, ratio 0.5 → 1 (unity everywhere).
    const auto unity = renderWith(C::kNumParams, [](ParamSlotTable& p) { p.set(C::kRatio, 0.5f); });
    DAW_CHECK(unity == in);
    const auto clamped = renderWith(C::kNumParams, [](ParamSlotTable& p) {
        p.set(C::kThreshold, 10.0f);
        p.set(C::kKnee, 0.0f);
    });
    DAW_CHECK(clamped == in);  // 0.9 < 0 dBFS: nothing above a 0 dB hard knee
    return checks;
}

CheckResult compressorStaticCurve() {
    CheckResult checks;
    // The engine's curve is continuous and monotonic and matches the oracle's.
    bool matches = true, continuous = true, monotonic = true;
    for (double t : {-60.0, -40.0, -20.0, -6.0, 0.0})
        for (double r : {1.0, 1.5, 2.0, 4.0, 10.0, 20.0})
            for (double w : {0.0, 3.0, 6.0, 12.0, 24.0}) {
                double prevY = -1e9, prevG = 1;
                for (double x = -100; x <= 12; x += 0.01) {
                    const double g = compressorGainDb(x, t, r, w);
                    matches = matches && near(g, curveDb(x, t, r, w), 1e-9);
                    monotonic = monotonic && g <= prevG + 1e-12 && x + g >= prevY - 1e-12;
                    prevY = x + g, prevG = g;
                }
                for (double edge : {t - w / 2, t + w / 2})
                    continuous = continuous &&
                                 near(compressorGainDb(edge - 1e-7, t, r, w), compressorGainDb(edge + 1e-7, t, r, w), 1e-6);
            }
    DAW_CHECK(matches && continuous && monotonic);
    DAW_CHECK(compressorGainDb(-10, -20, 4, 0) == -7.5);  // 10 dB over at 4:1 → 2.5 dB over
    DAW_CHECK(near(compressorGainDb(-20, -20, 4, 6), -0.75 * 9.0 / 12.0, 1e-12));  // knee centre: (1/R−1)·W/8
    DAW_CHECK(compressorGainDb(-23, -20, 4, 6) == 0.0 && compressorGainDb(0, -20, 1, 6) == 0.0);

    // Through the node: a settled constant key gives the curve's gain, both detectors.
    struct Grid {
        float t, r, w;
    };
    const Grid grid[] = {{-20, 4, 0}, {-20, 4, 6}, {-40, 2, 12}, {-6, 20, 3}, {-30, 1.5f, 24}, {-10, 1, 6}};
    bool peakOk = true, rmsOk = true;
    uint64_t violations = 0;
    for (const Grid& g : grid) {
        for (double level = -80; level <= 6; level += 2) {
            const auto amp = static_cast<float>(fromDb(level));
            const double want = curveDb(20 * std::log10(double{amp}), g.t, g.r, g.w);
            for (bool rms : {false, true}) {
                if (rms && std::fmod(level, 8.0) != 0.0) continue;  // RMS settles slowly: fewer levels
                CompRig rig;
                rig.apply({g.t, g.r, 0.1f, 1.0f, g.w, 0.0f, rms});
                const size_t frames = rms ? 48000 : 4800;
                rig.run({constant(frames, amp), constant(frames, -amp)}, {}, [] { return 4096u; });
                const double got = toDb(double{rig.left.back()} / amp);
                const bool ok = near(got, want, 1e-4) && rig.right.back() == -rig.left.back();
                (rms ? rmsOk : peakOk) = (rms ? rmsOk : peakOk) && ok;
                violations += rig.violations;
            }
        }
    }
    DAW_CHECK(peakOk);
    DAW_CHECK(rmsOk);

    // Makeup adds exactly, above and below the threshold.
    {
        CompRig rig;
        rig.apply({-20, 4, 0.1f, 1, 0, 6, false});
        rig.run({constant(4800, 0.01f), constant(4800, 0.01f)}, {}, [] { return 4800u; });  // −40 dB: below
        DAW_CHECK(near(toDb(double{rig.left.back()} / 0.01), 6.0, 1e-4));
        violations += rig.violations;
    }
    // RMS sees a sine's RMS (peak − 3.01 dB), not its peak.
    {
        CompRig rig;
        rig.apply({-20, 4, 50, 50, 0, 0, true});
        const auto s = sine(96000, 1000, 0.5);
        rig.run({s, s}, {}, [] { return 1024u; });
        const double want = curveDb(toDb(0.5 / std::numbers::sqrt2), -20, 4, 0);
        double gain = 0;  // the gain at the last few peaks
        for (size_t i = 95000; i < 96000; ++i)
            if (std::fabs(s[i]) > 0.4999f) gain = double{rig.left[i]} / s[i];
        DAW_CHECK(near(toDb(gain), want, 0.1));
        violations += rig.violations;
    }
    DAW_CHECK(violations == 0);
    return checks;
}

CheckResult compressorBallistics() {
    CheckResult checks;
    uint64_t violations = 0;
    // Attack and release from a key step, in closed form: from rest, a constant target c gives
    // e[n] = c·(1 − α^(n+1)); back to silence, e[n] = e0·α_R^(n+1).
    {
        CompRig rig;
        rig.apply({-20, 4, 5, 50, 0, 0, false});
        const size_t on = 4800, total = 4800 + 48000;
        std::vector<float> in(total, 0.0f);
        for (size_t i = 0; i < on; ++i) in[i] = 1.0f;  // 0 dB, 20 dB over → c = −15 dB
        // Silence keys nothing, so release shows on the gain alone: watch it on a quiet tone.
        std::vector<float> probe = in;
        for (size_t i = on; i < total; ++i) probe[i] = 1e-4f;  // −80 dB, below the threshold
        rig.run({probe, probe}, {}, [] { return 256u; });
        const double aA = std::exp(-1.0 / (0.005 * kRate)), aR = std::exp(-1.0 / (0.05 * kRate));
        double worstAttack = 0, worstRelease = 0;
        double e = 0;
        for (size_t i = 0; i < on; ++i) {
            e = -15.0 * (1.0 - std::pow(aA, static_cast<double>(i + 1)));
            worstAttack = std::max(worstAttack, std::fabs(toDb(double{rig.left[i]}) - e));
        }
        for (size_t i = on; i < total; ++i) {
            const double want = e * std::pow(aR, static_cast<double>(i - on + 1));
            worstRelease = std::max(worstRelease, std::fabs(toDb(double{rig.left[i]} / 1e-4) - want));
        }
        DAW_CHECK(worstAttack < 1e-4 && worstRelease < 1e-4);
        // One attack time constant (240 frames) in, the gain is 1 − 1/e of the way there.
        DAW_CHECK(near(toDb(double{rig.left[239]}), -15.0 * (1 - std::exp(-1.0)), 1e-3));
        violations += rig.violations;
    }
    // Per sample against the oracle: bursts, both detectors, params changing between blocks
    // (ramped across the block), random block sizes.
    for (bool rms : {false, true}) {
        CompRig rig;
        Oracle oracle;
        const size_t total = 96000;
        const auto l = bursts(total, 7), r = bursts(total, 8);
        std::mt19937 rng(rms ? 11 : 12);
        std::vector<double> gains;
        size_t pos = 0;
        int block = 0;
        while (pos < total) {
            Settings s{-30, 3, 2, 80, 6, 2, rms};
            if (block % 40 >= 20) s = Settings{-18, 8, 20, 30, 0, 0, rms};
            if (block % 13 == 5) s.makeup = 4;
            rig.apply(s);
            const auto n = static_cast<uint32_t>(std::min<size_t>(rng() % 1500, total - pos));
            rig.process({l, r}, {}, pos, n);
            std::vector<std::vector<float>> key{{l.begin() + static_cast<std::ptrdiff_t>(pos),
                                                 l.begin() + static_cast<std::ptrdiff_t>(pos + n)},
                                                {r.begin() + static_cast<std::ptrdiff_t>(pos),
                                                 r.begin() + static_cast<std::ptrdiff_t>(pos + n)}};
            const auto g = oracle.block(key, n, s);
            gains.insert(gains.end(), g.begin(), g.end());
            pos += n;
            ++block;
        }
        DAW_CHECK(maxError(rig.left, l, gains) < 1e-6);
        DAW_CHECK(maxError(rig.right, r, gains) < 1e-6);
        violations += rig.violations;
    }
    DAW_CHECK(violations == 0);
    return checks;
}

CheckResult compressorSidechain() {
    CheckResult checks;
    uint64_t violations = 0;
    const size_t total = 9600;
    const auto quiet = sine(total, 441, 0.1);  // −20 dBFS peak, below a −10 dB threshold
    std::vector<float> key(total, 0.0f);
    for (size_t i = 2000; i < 4000; ++i) key[i] = 1.0f;
    const Settings s{-10, 4, 1, 20, 0, 0, false};
    // MIX-008: the sidechain keys: before it, output == input bit for bit; from its first loud
    // sample the gain follows the key (oracle keyed by the sidechain), never the input.
    {
        CompRig rig;
        rig.apply(s);
        rig.run({quiet, quiet}, {key, key}, [] { return 512u; });
        bool before = true;
        for (size_t i = 0; i < 2000; ++i) before = before && rig.left[i] == quiet[i];
        DAW_CHECK(before);
        DAW_CHECK(std::fabs(rig.left[2000]) < std::fabs(quiet[2000]));  // 0 latency: the key's first sample
        Oracle oracle;
        std::vector<double> gains;
        for (size_t pos = 0; pos < total; pos += 512) {
            const auto n = static_cast<uint32_t>(std::min<size_t>(512, total - pos));
            std::vector<float> k(key.begin() + static_cast<std::ptrdiff_t>(pos),
                                 key.begin() + static_cast<std::ptrdiff_t>(pos + n));
            const auto g = oracle.block({k, k}, n, s);
            gains.insert(gains.end(), g.begin(), g.end());
        }
        DAW_CHECK(maxError(rig.left, quiet, gains) < 1e-7 && rig.left == rig.right);
        DAW_CHECK(near(toDb(gains[3999]), -7.5, 1e-3));  // 0 dB key, 10 dB over at 4:1
        violations += rig.violations;
    }
    // A loud input with a silent sidechain passes untouched; without the sidechain it compresses.
    {
        const auto loud = sine(total, 441, 0.9);
        CompRig keyed, self;
        keyed.apply(s);
        self.apply(s);
        keyed.run({loud, loud}, {constant(total, 0.0f), constant(total, 0.0f)}, [] { return 512u; });
        self.run({loud, loud}, {}, [] { return 512u; });
        DAW_CHECK(keyed.left == loud && keyed.right == loud);
        DAW_CHECK(self.left != loud);
        violations += keyed.violations + self.violations;
    }
    // Stereo link: a key on one channel only (or a mono key) sets one gain for both outputs.
    {
        const auto inL = sine(total, 441, 0.3), inR = sine(total, 300, 0.2);
        CompRig rightKey, monoKey;
        rightKey.apply(s);
        monoKey.apply(s);
        rightKey.run({inL, inR}, {constant(total, 0.0f), key}, [] { return 512u; });
        monoKey.run({inL, inR}, {key}, [] { return 512u; });
        DAW_CHECK(rightKey.left == monoKey.left && rightKey.right == monoKey.right);
        bool linked = true;
        for (size_t i = 0; i < total; ++i)
            if (std::fabs(inL[i]) > 0.05f && std::fabs(inR[i]) > 0.05f)
                linked = linked && near(rightKey.left[i] / inL[i], rightKey.right[i] / inR[i], 1e-5);
        DAW_CHECK(linked);
        DAW_CHECK(std::fabs(rightKey.left[3000]) < std::fabs(inL[3000]) * 0.5f || std::fabs(inL[3000]) < 0.01f);
        violations += rightKey.violations + monoKey.violations;
    }
    DAW_CHECK(violations == 0);
    return checks;
}

CheckResult compressorRobustness() {
    CheckResult checks;
    uint64_t violations = 0;
    // ENG-004: random block sizes (0 … 4096, zeros included) match fixed 512-frame blocks bit for
    // bit with constant params, both detectors, self-keyed and sidechained.
    for (bool rms : {false, true})
        for (bool sidechained : {false, true}) {
            const size_t total = 200000;
            const auto l = bursts(total, 21), r = bursts(total, 22), k = bursts(total, 23);
            const std::vector<std::vector<float>> key = sidechained ? std::vector<std::vector<float>>{k, k}
                                                                    : std::vector<std::vector<float>>{};
            const Settings s{-24, 5, 3, 60, 6, 3, rms};
            CompRig fixed, fuzzed;
            fixed.apply(s);
            fuzzed.apply(s);
            fixed.run({l, r}, key, [] { return 512u; });
            std::mt19937 rng(rms * 2 + sidechained);
            fuzzed.run({l, r}, key, [&] {
                const uint32_t pick = rng() % 10;
                return pick == 0 ? 0u : pick == 1 ? kMaxBlock : static_cast<uint32_t>(rng() % kMaxBlock);
            });
            DAW_CHECK(fixed.left == fuzzed.left && fixed.right == fuzzed.right);
            violations += fixed.violations + fuzzed.violations;
        }

    // DSP-040: silence in → silence out; the envelope (and the RMS average) settle to exactly
    // 0 dB, so after the tail the gain is exactly 1 and nothing decays into denormals.
    for (bool rms : {false, true}) {
        CompRig rig;
        rig.apply({-40, 10, 1, 100, 0, 0, rms});
        const auto loud = sine(48000, 441, 1.0);
        rig.run({loud, loud}, {}, [] { return 512u; });
        DAW_CHECK(rig.node.gainReductionDb() < -20.0);
        rig.left.clear();
        rig.right.clear();
        rig.run({constant(5 * 48000, 0.0f), constant(5 * 48000, 0.0f)}, {}, [] { return 512u; });
        DAW_CHECK(std::all_of(rig.left.begin(), rig.left.end(), [](float x) { return x == 0.0f; }));
        DAW_CHECK(std::all_of(rig.right.begin(), rig.right.end(), [](float x) { return x == 0.0f; }));
        DAW_CHECK(rig.node.gainReductionDb() == 0.0);
        rig.left.clear();
        const auto soft = sine(512, 441, 0.001);  // −60 dB: below the threshold
        rig.run({soft, soft}, {}, [] { return 512u; });
        DAW_CHECK(rig.left == soft);  // exactly unity: settled to 0 dB, no residue
        violations += rig.violations;
    }

    // DSP-040: NaN guard. A block with a NaN (input) or Inf (sidechain) outputs silence, is
    // counted, and the next block starts the detector afresh.
    {
        const auto in = sine(2048, 441, 0.9);
        CompRig rig, fresh;
        const Settings s{-20, 4, 5, 50, 6, 0, false};
        rig.apply(s);
        fresh.apply(s);
        rig.process({in, in}, {}, 0, 512);
        auto bad = in;
        bad[512 + 17] = std::numeric_limits<float>::quiet_NaN();
        rig.process({bad, in}, {}, 512, 512);
        DAW_CHECK(rig.node.nanBlocks() == 1);
        DAW_CHECK(std::all_of(rig.left.begin() + 512, rig.left.end(), [](float x) { return x == 0.0f; }));
        DAW_CHECK(std::all_of(rig.right.begin() + 512, rig.right.end(), [](float x) { return x == 0.0f; }));
        DAW_CHECK(rig.node.gainReductionDb() == 0.0);
        // The next block equals a fresh compressor's first block (params already primed: same values).
        rig.process({in, in}, {}, 1024, 512);
        fresh.process({in, in}, {}, 1024, 512);
        DAW_CHECK(std::equal(fresh.left.begin(), fresh.left.end(), rig.left.begin() + 1024));
        // Inf in the sidechain.
        auto key = constant(2048, 0.5f);
        key[1536 + 3] = std::numeric_limits<float>::infinity();
        rig.process({in, in}, {key, key}, 1536, 512);
        DAW_CHECK(rig.node.nanBlocks() == 2);
        DAW_CHECK(std::all_of(rig.left.begin() + 1536, rig.left.end(), [](float x) { return x == 0.0f; }));
        violations += rig.violations + fresh.violations;
    }
    DAW_CHECK(violations == 0);
    return checks;
}

CheckResult compressorThroughEngine() {
    CheckResult checks;
    Rig rig;
    // Tone 0.25 at 441 Hz (−12 dBFS, above the threshold, but the sidechain keys); key: DC 1.0.
    rig.addAsset(makeAsset(1, 1, 48000, [](uint32_t, int64_t i) {
        return static_cast<float>(0.25 * std::sin(2 * std::numbers::pi * 441 * static_cast<double>(i) / kRate));
    }));
    rig.addAsset(makeAsset(2, 1, 4800, [](uint32_t, int64_t) { return 1.0f; }));
    auto params = rig.engine().params().allocate(C::kNumParams, 0.0f);
    DAW_CHECK(params.ok());
    const ParamID first = params.value();
    const Settings s{-20, 4, 1, 50, 0, 0, false};
    ParamSlotTable& slots = rig.engine().params();
    slots.set(first + C::kThreshold, s.threshold);
    slots.set(first + C::kRatio, s.ratio);
    slots.set(first + C::kAttack, s.attack);
    slots.set(first + C::kRelease, s.release);
    slots.set(first + C::kKnee, s.knee);
    slots.set(first + C::kMakeup, s.makeup);
    slots.set(first + C::kDetector, 0.0f);

    // tone player 10 → compressor 20 → master 1; key player 11 ─sidechain→ 20 (tick 240 = 6000).
    GraphDescription d = baseDescription();
    d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
    d.nodes.push_back(NodeDesc{11, NodeKind::audioClipPlayer, 1, 0, 0, {}});
    d.nodes.push_back(NodeDesc{20, NodeKind::compressor, 1, first, C::kNumParams, {}});
    d.edges.push_back(EdgeDesc{1, 10, 20, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{2, 20, 1, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{3, 11, 20, EdgeKind::sidechain, 0});
    d.audioClips.push_back(clip(10, 1, 0, 1920, 1));
    d.audioClips.push_back(clip(11, 2, 240, 192, 2));
    DAW_CHECK(rig.publish(d));
    const MeterID meter = rig.builder().meterOf(20);
    DAW_CHECK(meter != kNoMeter);
    DAW_CHECK(rig.transport().locate(0) && rig.transport().play());

    rig.renderFrames(9000, [] { return 256u; });
    // Mid-key, settled: the meter reads the −15 dB reduction (1 ms attack).
    const MeterReading during = rig.engine().telemetry().meter(meter);
    DAW_CHECK(near(during.rms, fromDb(-15.0), 1e-4));
    DAW_CHECK(during.peak <= during.rms + 1e-6f);
    rig.renderFrames(48000 - 9000, [] { return 256u; });
    const MeterReading after = rig.engine().telemetry().meter(meter);
    DAW_CHECK(after.rms > 0.999f);  // released

    // Per sample: tone × oracle gain keyed by the key clip (0 latency: GR from frame 6000).
    std::vector<float> tone(48000), key(48000, 0.0f);
    for (size_t i = 0; i < 48000; ++i)
        tone[i] = static_cast<float>(0.25 * std::sin(2 * std::numbers::pi * 441 * static_cast<double>(i) / kRate));
    for (size_t i = 6000; i < 10800; ++i) key[i] = 1.0f;
    Oracle oracle;
    std::vector<double> gains;
    for (size_t pos = 0; pos < 48000; pos += 256) {
        std::vector<float> k(key.begin() + static_cast<std::ptrdiff_t>(pos),
                             key.begin() + static_cast<std::ptrdiff_t>(pos + 256));
        const auto g = oracle.block({k, k}, 256, s);
        gains.insert(gains.end(), g.begin(), g.end());
    }
    DAW_CHECK(rig.left().size() == 48000);
    if (rig.left().size() == 48000) {
        bool untouched = true;
        for (size_t i = 0; i < 6000; ++i) untouched = untouched && rig.left()[i] == tone[i];
        DAW_CHECK(untouched);
        DAW_CHECK(std::fabs(rig.left()[6000]) < std::fabs(tone[6000]) * 0.99f);
        DAW_CHECK(maxError(rig.left(), tone, gains) < 1e-7);
        DAW_CHECK(rig.left() == rig.right());
    }
    DAW_CHECK(rig.engine().telemetry().snapshot().graphLatency == 0);
    DAW_CHECK(rig.violations() == 0);
    return checks;
}

} // namespace daw::testing
