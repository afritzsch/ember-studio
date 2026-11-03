// T-072 checks for the built-in delay (DSP-032, DSP-040, DSP-041, TIME-008, DW-162). Run from
// Tests/DAWEngineTests/DelayTests.swift; see DelayChecks.h for why they're C++.
//
// The oracle below is written from the 06 spec text (Delay.h's signal path), independently of
// nodes/Delay.cpp: it works in double, keeps each line's whole history instead of a ring buffer,
// and has its own note-value table and time rule.

#include "DelayChecks.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <functional>
#include <numbers>
#include <random>
#include <string>
#include <vector>

#include "NodeTestHarness.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/ProcessContext.h"
#include "core/RtTrap.h"
#include "daw/EngineFacade.h"
#include "nodes/Delay.h"
#include "time/TempoMap.h"

using namespace daw;
using namespace daw::testing::nodes;

namespace daw::testing {

namespace {

using D = Delay;
using Signal = std::vector<float>;

struct Settings {
    float time = 375.0f, sync = 1.0f, note = 5.0f, feedback = 0.35f, lowpass = 8000.0f, pingpong = 0.0f, mix = 0.3f;
    double bpm = 120.0;
};

// 06 DSP-032: note values in quarter notes, shortest first.
constexpr std::array<double, 14> kSpecBeats{0.125, 1.0 / 6, 0.25, 1.0 / 3, 0.375, 0.5, 2.0 / 3,
                                            0.75,  1.0,     4.0 / 3, 1.5, 2.0,   3.0, 4.0};
constexpr double kSpecMaxFrames = 4.0 * kRate;  // 4 s
constexpr double kSpecCrossfade = 0.020 * kRate;  // 20 ms

TempoMap tempoAt(double bpm) {
    auto map = TempoMap::make({{0, bpm}}, {{0, 4, 4}}, kRate);
    return map ? std::move(map).value() : TempoMap{};
}

// Per-sample model of Delay.h's signal path, in double, without snapping (it changes values by
// less than 1e-9).
struct Oracle {
    std::vector<double> lineL, lineR;  // every value written, by frame
    double d = 0, to = 0, pos = 0, zL = 0, zR = 0, fbPrev = 0, mixPrev = 0;
    bool primed = false;

    static double at(const std::vector<double>& h, int64_t t) {
        return t >= 0 && t < static_cast<int64_t>(h.size()) ? h[static_cast<size_t>(t)] : 0.0;
    }
    static double target(const Settings& s) {
        double frames = 0;
        if (s.sync >= 0.5f) {
            const double index = std::clamp(std::round(double{s.note}), 0.0, 13.0);
            frames = std::round(kSpecBeats[static_cast<size_t>(index)] * 60.0 * kRate / s.bpm);
        } else {
            frames = std::round(double{s.time} * kRate / 1000.0);
        }
        return std::clamp(frames, 1.0, kSpecMaxFrames);
    }

    void block(const Signal& l, const Signal& r, size_t from, uint32_t n, const Settings& s, std::vector<double>& outL,
               std::vector<double>& outR) {
        if (n == 0) return;
        const double t0 = target(s);
        const bool filterOn = s.lowpass < 20000.0f;
        const double a = std::exp(-2.0 * std::numbers::pi * std::min(double{s.lowpass}, 0.45 * kRate) / kRate);
        if (!primed) {
            d = to = t0, pos = 0, fbPrev = s.feedback, mixPrev = s.mix;
            primed = true;
        }
        auto ramp = [n](double prev, double target, uint32_t k) {
            return k + 1 == n ? target : prev + (target - prev) * (k + 1) / n;
        };
        for (uint32_t k = 0; k < n; ++k) {
            const auto t = static_cast<int64_t>(lineL.size());
            const double dryL = l[from + k], dryR = r[from + k];
            if (to == d && t0 != d) to = t0, pos = 0;
            double xL = at(lineL, t - static_cast<int64_t>(d)), xR = at(lineR, t - static_cast<int64_t>(d));
            if (to != d) {
                pos += 1;
                const double w = pos / kSpecCrossfade;
                xL = (1 - w) * xL + w * at(lineL, t - static_cast<int64_t>(to));
                xR = (1 - w) * xR + w * at(lineR, t - static_cast<int64_t>(to));
                if (pos >= kSpecCrossfade) d = to, pos = 0;
            }
            zL = filterOn ? (1 - a) * xL + a * zL : xL;
            zR = filterOn ? (1 - a) * xR + a * zR : xR;
            const double fb = ramp(fbPrev, s.feedback, k);
            if (s.pingpong >= 0.5f) {
                lineL.push_back(0.5 * (dryL + dryR) + fb * zR);
                lineR.push_back(fb * zL);
            } else {
                lineL.push_back(dryL + fb * zL);
                lineR.push_back(dryR + fb * zR);
            }
            const double m = ramp(mixPrev, s.mix, k);
            outL.push_back((1 - m) * dryL + m * xL);
            outR.push_back((1 - m) * dryR + m * xR);
        }
        fbPrev = s.feedback;
        mixPrev = s.mix;
    }
};

// Drives a Delay directly. `in` holds 0, 1 or 2 channels.
struct DelayRig {
    explicit DelayRig(uint32_t numParams = D::kNumParams) : params(16), node(0, numParams) {
        trapInstalled = RtTrap::install();  // no Engine here to install it (ENG-030)
        (void)params.allocate(D::kNumParams, 0.0f);
        for (const ParamInfo& p : D::kParamInfo) params.set(p.index, p.def);
        node.prepare(PrepareInfo{kRate, kMaxBlock, 2, 2});
    }

    void apply(const Settings& s) {
        params.set(D::kTime, s.time);
        params.set(D::kSync, s.sync);
        params.set(D::kNote, s.note);
        params.set(D::kFeedback, s.feedback);
        params.set(D::kLowpass, s.lowpass);
        params.set(D::kPingPong, s.pingpong);
        params.set(D::kMix, s.mix);
        if (s.bpm != bpm) {
            tempo = tempoAt(s.bpm);
            bpm = s.bpm;
        }
    }

    // Processes frames [from, from + n) of `in` and appends the output (channels 0 and 1).
    void process(const std::vector<Signal>& in, size_t from, uint32_t n, uint32_t outChannels = 2) {
        std::vector<Signal> buf(in.size());
        std::vector<float*> ptr;
        for (size_t c = 0; c < in.size(); ++c) {
            buf[c].assign(in[c].begin() + static_cast<std::ptrdiff_t>(from),
                          in[c].begin() + static_cast<std::ptrdiff_t>(from + n));
            ptr.push_back(buf[c].data());
        }
        std::vector<Signal> outBuf(outChannels, Signal(n, -99.0f));
        std::vector<float*> out;
        for (Signal& o : outBuf) out.push_back(o.data());
        NodeIO io;
        if (!ptr.empty()) io.audioIn = AudioBufferView{ptr.data(), static_cast<uint32_t>(ptr.size()), n};
        io.audioOut = AudioBufferView{out.data(), outChannels, n};
        TransportBlock block{false, false, 0, {}, &tempo};
        ProcessContext ctx{n, kRate, block, params};
        {
            RtScope scope;
            node.process(ctx, io);
            violations += scope.violations();
        }
        left.insert(left.end(), outBuf[0].begin(), outBuf[0].end());
        right.insert(right.end(), outBuf[1].begin(), outBuf[1].end());
        for (uint32_t c = 2; c < outChannels; ++c)
            extraSilent = extraSilent && std::all_of(outBuf[c].begin(), outBuf[c].end(), [](float x) { return x == 0.0f; });
    }

    void run(const std::vector<Signal>& in, const std::function<uint32_t()>& nextBlock) {
        const size_t total = in.empty() ? 0 : in[0].size();
        size_t pos = 0;
        for (int guard = 0; pos < total && guard < 1'000'000; ++guard) {
            const auto n = static_cast<uint32_t>(std::min<size_t>(nextBlock(), total - pos));
            process(in, pos, n);
            pos += n;
        }
    }

    void resetNode() {
        RtScope scope;
        node.reset();
        violations += scope.violations();
    }

    ParamSlotTable params;
    Delay node;
    TempoMap tempo;
    double bpm = 120.0;
    Signal left, right;
    uint64_t violations = 0;
    bool trapInstalled = false;
    bool extraSilent = true;
};

Signal impulse(size_t n, float amp = 1.0f) {
    Signal s(n, 0.0f);
    if (n > 0) s[0] = amp;
    return s;
}

Signal sine(size_t n, double hz, float amp, size_t from = 0) {
    Signal s(n, 0.0f);
    for (size_t i = from; i < n; ++i)
        s[i] = amp * static_cast<float>(std::sin(2.0 * std::numbers::pi * hz * static_cast<double>(i - from) / kRate));
    return s;
}

// Deterministic noise in bursts of different levels (−40 … 0 dBFS), with silent gaps.
Signal bursts(size_t n, uint32_t seed) {
    std::mt19937 rng(seed);
    std::uniform_real_distribution<float> u(-1.0f, 1.0f);
    std::uniform_real_distribution<double> levelDb(-40.0, 0.0);
    Signal s(n, 0.0f);
    size_t i = 0;
    while (i < n) {
        const size_t len = 500 + rng() % 6000;
        const bool gap = rng() % 4 == 0;
        const auto amp = static_cast<float>(std::pow(10.0, levelDb(rng) / 20.0));
        for (size_t k = 0; k < len && i < n; ++k, ++i) s[i] = gap ? 0.0f : amp * u(rng);
    }
    return s;
}

bool allZero(const Signal& s, size_t from = 0, size_t to = SIZE_MAX) {
    to = std::min(to, s.size());
    for (size_t i = std::min(from, to); i < to; ++i)
        if (s[i] != 0.0f) return false;
    return true;
}

// The frames holding a non-zero sample.
std::vector<size_t> nonZero(const Signal& s) {
    std::vector<size_t> out;
    for (size_t i = 0; i < s.size(); ++i)
        if (s[i] != 0.0f) out.push_back(i);
    return out;
}

double maxError(const Signal& got, const std::vector<double>& want) {
    double worst = got.size() == want.size() ? 0.0 : 1e9;
    for (size_t i = 0; i < std::min(got.size(), want.size()); ++i) worst = std::max(worst, std::fabs(got[i] - want[i]));
    return worst;
}

double maxStep(const Signal& s, size_t from, size_t to) {
    double worst = 0;
    for (size_t i = std::max<size_t>(from, 1); i < std::min(to, s.size()); ++i)
        worst = std::max(worst, std::fabs(double{s[i]} - s[i - 1]));
    return worst;
}

struct Response {
    Signal left, right;
    uint64_t violations;
};

// The response to `inL`/`inR` (or a mono input) with fixed 512-frame blocks.
Response response(const Settings& s, const std::vector<Signal>& in) {
    DelayRig rig;
    rig.apply(s);
    rig.run(in, [] { return 512u; });
    return {rig.left, rig.right, rig.violations};
}

} // namespace

CheckResult delayParams() {
    CheckResult checks;
    DAW_CHECK(D::kNumParams == 7);
    for (uint32_t i = 0; i < D::kNumParams; ++i) {
        const ParamInfo& p = D::kParamInfo[i];
        DAW_CHECK(p.index == i);
        DAW_CHECK(p.min <= p.def && p.def <= p.max);
        DAW_CHECK(p.automatable);
    }
    DAW_CHECK(D::kParamInfo[D::kTime].min == 1.0f && D::kParamInfo[D::kTime].max == 4000.0f);
    DAW_CHECK(D::kParamInfo[D::kTime].def == 375.0f && D::kParamInfo[D::kSync].def == 1.0f);
    DAW_CHECK(D::kParamInfo[D::kNote].max == 13.0f && D::kParamInfo[D::kNote].def == 5.0f);
    DAW_CHECK(D::kParamInfo[D::kFeedback].max == 0.95f && D::kParamInfo[D::kFeedback].def == 0.35f);
    DAW_CHECK(D::kParamInfo[D::kLowpass].min == 200.0f && D::kParamInfo[D::kLowpass].max == 20000.0f);
    DAW_CHECK(D::kParamInfo[D::kLowpass].def == 8000.0f && D::kParamInfo[D::kPingPong].def == 0.0f);
    DAW_CHECK(D::kParamInfo[D::kMix].def == 0.3f);
    // The note table: shortest first, the 06 values; the default is 1/8.
    for (size_t i = 0; i < D::kNumNotes; ++i) DAW_CHECK(std::fabs(D::kNotes[i].beats - kSpecBeats[i]) < 1e-12);
    DAW_CHECK(std::string(D::kNotes[5].name) == "1/8" && std::string(D::kNotes[13].name) == "1/1");
    DAW_CHECK(D(0, 0).latencySamples() == 0);

    // Delay times in frames (06 DSP-032).
    DAW_CHECK(D::delayFrames(375.0f, false, 5.0f, 120.0, kRate) == 18000);
    DAW_CHECK(D::delayFrames(1.0f, false, 5.0f, 120.0, kRate) == 48);
    DAW_CHECK(D::delayFrames(0.001f, false, 5.0f, 120.0, kRate) == 1);  // at least 1 frame
    DAW_CHECK(D::delayFrames(4000.0f, false, 5.0f, 120.0, kRate) == 192000);
    DAW_CHECK(D::delayFrames(999.0f, true, 5.0f, 120.0, kRate) == 12000);  // 1/8 at 120: 250 ms
    DAW_CHECK(D::delayFrames(999.0f, true, 8.0f, 90.0, kRate) == 32000);   // 1/4 at 90
    DAW_CHECK(D::delayFrames(999.0f, true, 7.0f, 120.0, kRate) == 18000);  // 1/8D
    DAW_CHECK(D::delayFrames(999.0f, true, 1.0f, 120.0, kRate) == 4000);   // 1/16T
    DAW_CHECK(D::delayFrames(999.0f, true, 4.6f, 120.0, kRate) == 12000);  // rounds to 1/8
    DAW_CHECK(D::delayFrames(999.0f, true, 13.0f, 30.0, kRate) == 192000); // 8 s → 4 s
    DAW_CHECK(D::delayFrames(999.0f, true, 5.0f, std::nan(""), kRate) == 12000);  // no tempo: 120
    DAW_CHECK(D::delayFrames(999.0f, true, 5.0f, 120.0, 96000.0) == 24000);
    DAW_CHECK(D::crossfadeFrames(48000.0) == 960 && D::crossfadeFrames(44100.0) == 882);

    // DSP-041: the table reaches the model through the facade.
    DriverConfigPOD config;
    config.sampleRate = kRate;
    if (EngineFacade* facade = EngineFacade::create(EngineMode::offline, config)) {
        const std::string json = facade->paramInfoJSON(NodeKind::delay);
        DAW_CHECK(json.find("\"index\":0,\"id\":\"time\"") != std::string::npos);
        DAW_CHECK(json.find("\"index\":1,\"id\":\"sync\"") != std::string::npos);
        DAW_CHECK(json.find("\"index\":2,\"id\":\"note\"") != std::string::npos);
        DAW_CHECK(json.find("\"index\":3,\"id\":\"feedback\"") != std::string::npos);
        DAW_CHECK(json.find("\"index\":4,\"id\":\"lowpass\"") != std::string::npos);
        DAW_CHECK(json.find("\"index\":5,\"id\":\"pingpong\"") != std::string::npos);
        DAW_CHECK(json.find("\"index\":6,\"id\":\"mix\"") != std::string::npos);
        DAW_CHECK(json.find("\"default\":375.000000,\"curve\":\"log\",\"unit\":\"ms\"") != std::string::npos);
        releaseFacade(facade);
    } else {
        DAW_CHECK(false);
    }

    // Defaults: numParams 0, NaN slots and default slot values all render the same; clamping.
    const Signal in = bursts(48000, 3);
    uint64_t violations = 0;
    auto renderWith = [&](uint32_t numParams, const std::function<void(ParamSlotTable&)>& set) {
        DelayRig rig(numParams);
        set(rig.params);
        rig.run({in, in}, [] { return 512u; });
        violations += rig.violations;
        DAW_CHECK(rig.trapInstalled || !DAW_RT_TRAP);  // otherwise the scopes count nothing
        return rig.left;
    };
    auto withValues = [&](const Settings& s) {
        return renderWith(D::kNumParams, [&](ParamSlotTable& p) {
            p.set(D::kTime, s.time);
            p.set(D::kSync, s.sync);
            p.set(D::kNote, s.note);
            p.set(D::kFeedback, s.feedback);
            p.set(D::kLowpass, s.lowpass);
            p.set(D::kPingPong, s.pingpong);
            p.set(D::kMix, s.mix);
        });
    };
    const Signal defaults = renderWith(D::kNumParams, [](ParamSlotTable&) {});
    DAW_CHECK(defaults != in);
    DAW_CHECK(renderWith(0, [](ParamSlotTable& p) { p.set(D::kMix, 1.0f); }) == defaults);
    DAW_CHECK(renderWith(D::kNumParams, [](ParamSlotTable& p) {
                  for (uint32_t i = 0; i < D::kNumParams; ++i) p.set(i, std::nanf(""));
              }) == defaults);
    DAW_CHECK(withValues(Settings{}) == defaults);
    // Clamping: out-of-range values render like the nearest end of their range.
    Settings over{9000.0f, 0.0f, 99.0f, 5.0f, 1e6f, 0.0f, 2.0f};
    Settings top{4000.0f, 0.0f, 13.0f, 0.95f, 20000.0f, 0.0f, 1.0f};
    DAW_CHECK(withValues(over) == withValues(top));
    Settings under{-5.0f, -1.0f, -3.0f, -1.0f, 0.0f, -1.0f, -1.0f};
    Settings bottom{1.0f, 0.0f, 0.0f, 0.0f, 200.0f, 0.0f, 0.0f};
    DAW_CHECK(withValues(under) == withValues(bottom));
    Settings syncOver{375.0f, 7.0f, 99.0f, 0.35f, 8000.0f, 3.0f, 0.3f};
    Settings syncTop{375.0f, 1.0f, 13.0f, 0.35f, 8000.0f, 1.0f, 0.3f};
    DAW_CHECK(withValues(syncOver) == withValues(syncTop));
    DAW_CHECK(violations == 0);
    return checks;
}

CheckResult delayOracle() {
    CheckResult checks;
    constexpr size_t kFrames = 144000;
    const Signal inL = bursts(kFrames, 11), inR = bursts(kFrames, 12);
    std::mt19937 rng(5);
    std::uniform_real_distribution<float> u(0.0f, 1.0f);
    const std::array<double, 4> tempos{120.0, 90.0, 140.5, 60.0};

    DelayRig rig;
    Oracle oracle;
    std::vector<double> wantL, wantR;
    Settings s;
    size_t pos = 0;
    int changes = 0;
    for (int guard = 0; pos < kFrames && guard < 100000; ++guard) {
        // Change some params between blocks of random sizes (0-frame blocks included).
        if (guard == 0 || rng() % 3 == 0) {
            ++changes;
            switch (rng() % 7) {
            case 0: s.time = 1.0f + u(rng) * 3999.0f; break;
            case 1: s.sync = s.sync >= 0.5f ? 0.0f : 1.0f; break;
            case 2: s.note = u(rng) * 13.0f; break;
            case 3: s.feedback = u(rng) * 0.95f; break;
            case 4: s.lowpass = rng() % 4 == 0 ? 20000.0f : 200.0f + u(rng) * 19800.0f; break;
            case 5: s.pingpong = s.pingpong >= 0.5f ? 0.0f : 1.0f; break;
            default: s.bpm = tempos[rng() % tempos.size()]; break;
            }
            if (rng() % 2 == 0) s.mix = u(rng);
        }
        const auto n = static_cast<uint32_t>(std::min<size_t>(rng() % 9 == 0 ? 0 : 1 + rng() % 2048, kFrames - pos));
        rig.apply(s);
        rig.process({inL, inR}, pos, n);
        oracle.block(inL, inR, pos, n, s, wantL, wantR);
        pos += n;
    }
    DAW_CHECK(changes > 50);
    DAW_CHECK(rig.left.size() == kFrames);
    const double errL = maxError(rig.left, wantL), errR = maxError(rig.right, wantR);
    DAW_CHECK(errL < 1e-5);
    DAW_CHECK(errR < 1e-5);
    DAW_CHECK(rig.left != inL && rig.right != inR);
    DAW_CHECK(rig.violations == 0);

    // The same with a mono input (it feeds both sides) and without any input after a while.
    DelayRig mono;
    Oracle monoOracle;
    std::vector<double> mL, mR;
    Settings ms{250.0f, 0.0f, 5.0f, 0.7f, 3000.0f, 1.0f, 0.6f};
    mono.apply(ms);
    pos = 0;
    while (pos < 48000) {
        const auto n = static_cast<uint32_t>(std::min<size_t>(300, 48000 - pos));
        mono.process({inL}, pos, n);
        monoOracle.block(inL, inL, pos, n, ms, mL, mR);
        pos += n;
    }
    const Signal zeros(48000, 0.0f);
    for (size_t p = 0; p < 48000; p += 400) {
        mono.process({}, p, 400);  // no input channels: silence in, echoes ring on
        monoOracle.block(zeros, zeros, p, 400, ms, mL, mR);
    }
    DAW_CHECK(maxError(mono.left, mL) < 1e-5 && maxError(mono.right, mR) < 1e-5);
    DAW_CHECK(!allZero(mono.left, 60000) && !allZero(mono.right, 60000));
    DAW_CHECK(mono.violations == 0);
    return checks;
}

CheckResult delayResponse() {
    CheckResult checks;
    uint64_t violations = 0;
    const Signal one = impulse(60000);

    // Stereo, 1/8 at 120 bpm (12000 frames), feedback 0.5, lowpass off, wet only: echo k at
    // k · 12000 with 0.5^(k−1), exactly, and nothing else.
    {
        Response r = response(Settings{375.0f, 1.0f, 5.0f, 0.5f, 20000.0f, 0.0f, 1.0f}, {one, one});
        violations += r.violations;
        DAW_CHECK((nonZero(r.left) == std::vector<size_t>{12000, 24000, 36000, 48000}));
        DAW_CHECK(r.left[12000] == 1.0f && r.left[24000] == 0.5f && r.left[36000] == 0.25f && r.left[48000] == 0.125f);
        DAW_CHECK(r.right == r.left);
        // Mix 0.5: half the dry click, then half each echo.
        Response half = response(Settings{375.0f, 1.0f, 5.0f, 0.5f, 20000.0f, 0.0f, 0.5f}, {one, one});
        violations += half.violations;
        DAW_CHECK((nonZero(half.left) == std::vector<size_t>{0, 12000, 24000, 36000, 48000}));
        DAW_CHECK(half.left[0] == 0.5f && half.left[12000] == 0.5f && half.left[24000] == 0.25f);
        // The two sides are independent: a click on the left only echoes on the left.
        Response leftOnly = response(Settings{375.0f, 1.0f, 5.0f, 0.5f, 20000.0f, 0.0f, 1.0f}, {one, Signal(60000, 0.0f)});
        violations += leftOnly.violations;
        DAW_CHECK(leftOnly.left == r.left && allZero(leftOnly.right));
    }
    // Ping-pong: the mono sum enters on the left; echoes alternate left, right, left …
    {
        Response r = response(Settings{375.0f, 1.0f, 5.0f, 0.5f, 20000.0f, 1.0f, 1.0f}, {one, one});
        violations += r.violations;
        DAW_CHECK((nonZero(r.left) == std::vector<size_t>{12000, 36000}));
        DAW_CHECK((nonZero(r.right) == std::vector<size_t>{24000, 48000}));
        DAW_CHECK(r.left[12000] == 1.0f && r.right[24000] == 0.5f && r.left[36000] == 0.25f && r.right[48000] == 0.125f);
        // A click on the right alone enters at half level (½(L + R)), still on the left first.
        Response right = response(Settings{375.0f, 1.0f, 5.0f, 0.5f, 20000.0f, 1.0f, 1.0f}, {Signal(60000, 0.0f), one});
        violations += right.violations;
        DAW_CHECK(right.left[12000] == 0.5f && right.right[24000] == 0.25f);
    }
    // Times: 100 ms; 1/4 at 90 bpm (32000); 1/16T at 120 (4000).
    {
        Response ms = response(Settings{100.0f, 0.0f, 5.0f, 0.0f, 20000.0f, 0.0f, 1.0f}, {one, one});
        Response quarter = response(Settings{375.0f, 1.0f, 8.0f, 0.0f, 20000.0f, 0.0f, 1.0f, 90.0}, {one, one});
        Response triplet = response(Settings{375.0f, 1.0f, 1.0f, 0.0f, 20000.0f, 0.0f, 1.0f}, {one, one});
        violations += ms.violations + quarter.violations + triplet.violations;
        DAW_CHECK(nonZero(ms.left) == std::vector<size_t>{4800});
        DAW_CHECK(nonZero(quarter.left) == std::vector<size_t>{32000});
        DAW_CHECK(nonZero(triplet.left) == std::vector<size_t>{4000});
    }
    // Lowpass in the loop: the first echo is the click itself, each repeat passes the one-pole
    // once more (06: z = (1 − a)·x + a·z).
    {
        Response r = response(Settings{375.0f, 1.0f, 5.0f, 0.5f, 1000.0f, 0.0f, 1.0f}, {one, one});
        violations += r.violations;
        const double a = std::exp(-2.0 * std::numbers::pi * 1000.0 / kRate);
        DAW_CHECK(r.left[12000] == 1.0f && allZero(r.left, 12001, 24000));
        DAW_CHECK(std::fabs(r.left[24000] - 0.5 * (1 - a)) < 1e-7);
        DAW_CHECK(std::fabs(r.left[24001] - 0.5 * (1 - a) * a) < 1e-7);
        DAW_CHECK(std::fabs(r.left[24010] - 0.5 * (1 - a) * std::pow(a, 10)) < 1e-7);
        // The repeats get duller: the second echo's energy sits below the first's.
        double e1 = 0, e2 = 0;
        for (size_t i = 12000; i < 24000; ++i) e1 += double{r.left[i]} * r.left[i];
        for (size_t i = 24000; i < 36000; ++i) e2 += double{r.left[i]} * r.left[i];
        DAW_CHECK(e2 < 0.25 * e1 * 0.2);
    }
    // Mix 0 is the input bit for bit (with feedback running); a mono input feeds both sides.
    {
        const Signal noise = bursts(60000, 21), other = bursts(60000, 22);
        Response dry = response(Settings{375.0f, 1.0f, 5.0f, 0.9f, 3000.0f, 1.0f, 0.0f}, {noise, other});
        Response mono = response(Settings{}, {noise});
        Response both = response(Settings{}, {noise, noise});
        violations += dry.violations + mono.violations + both.violations;
        DAW_CHECK(dry.left == noise && dry.right == other);
        DAW_CHECK(mono.left == both.left && mono.right == both.right && mono.left == mono.right);
    }
    // A time change crossfades the taps over 20 ms: a 441 Hz sine, wet only, no feedback, 250 →
    // 230 ms (12000 → 11040 frames) after 30000 frames. A jump would step by over 0.5; the
    // crossfade keeps every step within the sine's own slope, and outside the 960 crossfade
    // frames the output is the input at exactly the old or the new delay (no pitch bend).
    {
        const Signal tone = sine(60000, 441.0, 0.5f);
        DelayRig rig;
        Settings s{250.0f, 0.0f, 5.0f, 0.0f, 20000.0f, 0.0f, 1.0f};
        rig.apply(s);
        rig.run({std::vector<float>(tone.begin(), tone.begin() + 30000), std::vector<float>(tone.begin(), tone.begin() + 30000)},
                [] { return 500u; });
        DAW_CHECK(rig.node.currentDelayFrames() == 12000);
        s.time = 230.0f;
        rig.apply(s);
        for (size_t p = 30000; p < 60000; p += 500) rig.process({tone, tone}, p, 500);
        DAW_CHECK(rig.node.currentDelayFrames() == 11040);
        double worst = 0;
        for (size_t t = 12000; t < 60000; ++t) {
            float want = 0.0f;
            if (t < 30000) {
                want = tone[t - 12000];
            } else if (t < 30960) {
                const float w = static_cast<float>(t - 30000 + 1) / 960.0f;
                want = (1.0f - w) * tone[t - 12000] + w * tone[t - 11040];
            } else {
                want = tone[t - 11040];
            }
            worst = std::max(worst, std::fabs(double{rig.left[t]} - want));
        }
        DAW_CHECK(worst < 1e-6);
        DAW_CHECK(rig.left[30960] == tone[30960 - 11040] && rig.left[29999] == tone[29999 - 12000]);
        DAW_CHECK(std::fabs(double{tone[30000 - 12000]} - tone[30000 - 11040]) > 0.5);  // what a jump would do
        const double slope = 0.5 * 2 * std::numbers::pi * 441.0 / kRate;
        DAW_CHECK(maxStep(rig.left, 12001, 60000) < slope + 0.002);
        violations += rig.violations;
    }
    DAW_CHECK(violations == 0);
    return checks;
}

CheckResult delayRobustness() {
    CheckResult checks;
    uint64_t violations = 0;

    // ENG-004: random block sizes (0 … 4096) give the same bits as fixed 512-frame blocks.
    {
        const Signal inL = bursts(200000, 31), inR = bursts(200000, 32);
        for (const Settings& s : {Settings{}, Settings{730.0f, 0.0f, 5.0f, 0.8f, 2500.0f, 1.0f, 0.7f},
                                  Settings{375.0f, 1.0f, 2.0f, 0.95f, 20000.0f, 0.0f, 1.0f, 140.5}}) {
            DelayRig fixed, fuzz;
            fixed.apply(s);
            fuzz.apply(s);
            fixed.run({inL, inR}, [] { return 512u; });
            std::mt19937 rng(7);
            fuzz.run({inL, inR}, [&] { return static_cast<uint32_t>(rng() % 4097); });
            DAW_CHECK(fixed.left == fuzz.left && fixed.right == fuzz.right);
            violations += fixed.violations + fuzz.violations;
        }
    }

    // Silence in → exactly 0 out after the tail, with no denormals on the way: a click into the
    // longest-ringing settings (feedback 0.95), then silence until the lines are all 0.
    {
        DelayRig rig;
        rig.apply(Settings{375.0f, 1.0f, 0.0f, 0.95f, 8000.0f, 1.0f, 1.0f});  // 1/32: 3000 frames
        constexpr size_t kTotal = 3'000'000;
        const Signal click = impulse(4096);
        rig.process({click, click}, 0, 4096);
        const Signal zeros(4096, 0.0f);
        size_t frames = 4096;
        while (frames < kTotal && !rig.node.isSilent()) {
            rig.process({zeros, zeros}, 0, 4096);
            frames += 4096;
        }
        DAW_CHECK(rig.node.isSilent());
        DAW_CHECK(frames < kTotal);
        bool subnormal = false;
        for (size_t i = 0; i < rig.left.size(); ++i)
            subnormal = subnormal || std::fpclassify(rig.left[i]) == FP_SUBNORMAL ||
                        std::fpclassify(rig.right[i]) == FP_SUBNORMAL;
        DAW_CHECK(!subnormal);
        DAW_CHECK(!allZero(rig.left, 100000) && !allZero(rig.right, 100000));  // it did ring
        // Once silent, it stays exactly silent.
        const size_t mark = rig.left.size();
        for (int i = 0; i < 100; ++i) rig.process({zeros, zeros}, 0, 4096);
        DAW_CHECK(allZero(rig.left, mark) && allZero(rig.right, mark));
        violations += rig.violations;
    }

    // DSP-040: a block holding NaN or ±Inf outputs silence, is counted and clears the lines; the
    // following blocks sound like a fresh delay's.
    {
        const Signal pre = bursts(9600, 41), post = bursts(9600, 42);
        DelayRig rig;
        rig.apply(Settings{});
        rig.run({pre, pre}, [] { return 512u; });
        DAW_CHECK(!rig.node.isSilent() && rig.node.nanBlocks() == 0);
        for (float bad : {std::nanf(""), INFINITY, -INFINITY}) {
            Signal block(512, 0.25f);
            block[7] = bad;
            const size_t mark = rig.left.size();
            rig.process({block, Signal(512, 0.1f)}, 0, 512);
            DAW_CHECK(allZero(rig.left, mark) && allZero(rig.right, mark));
            DAW_CHECK(rig.node.isSilent());
        }
        DAW_CHECK(rig.node.nanBlocks() == 3);
        const size_t mark = rig.left.size();
        rig.run({post, post}, [] { return 512u; });
        DelayRig fresh;
        fresh.apply(Settings{});
        fresh.run({post, post}, [] { return 512u; });
        DAW_CHECK(Signal(rig.left.begin() + static_cast<std::ptrdiff_t>(mark), rig.left.end()) == fresh.left);
        violations += rig.violations + fresh.violations;
    }

    // Without an input (no channels) the echoes ring on, as with silence; reset() (a locate,
    // TIME-008) keeps them; channels beyond stereo are silent.
    {
        const Signal click = impulse(512);
        const Signal zeros(512, 0.0f);
        const Settings s{375.0f, 1.0f, 5.0f, 0.6f, 5000.0f, 1.0f, 0.5f};
        DelayRig a, b, c;
        for (DelayRig* rig : {&a, &b, &c}) {
            rig->apply(s);
            rig->process({click, click}, 0, 512);
        }
        for (int i = 0; i < 200; ++i) {
            a.process({zeros, zeros}, 0, 512);
            b.process({}, 0, 512, 3);
            if (i == 10) c.resetNode();
            c.process({zeros, zeros}, 0, 512);
        }
        DAW_CHECK(!allZero(a.left, 512) && !allZero(a.right, 512));
        DAW_CHECK(a.left == b.left && a.right == b.right);
        DAW_CHECK(a.left == c.left && a.right == c.right);
        DAW_CHECK(b.extraSilent);
        violations += a.violations + b.violations + c.violations;
    }
    DAW_CHECK(violations == 0);
    return checks;
}

CheckResult delayThroughEngine() {
    CheckResult checks;
    // impulse player 10 → delay 20 → master 1. The player duplicates the mono asset to L/R.
    auto setUp = [&](Rig& rig, const Settings& s, AudioAssetRef asset, Tick clipTicks, const TempoMapDesc* tempo) {
        rig.addAsset(std::move(asset));
        auto params = rig.engine().params().allocate(D::kNumParams, 0.0f);
        DAW_CHECK(params.ok());
        const ParamID first = params.value();
        ParamSlotTable& slots = rig.engine().params();
        slots.set(first + D::kTime, s.time);
        slots.set(first + D::kSync, s.sync);
        slots.set(first + D::kNote, s.note);
        slots.set(first + D::kFeedback, s.feedback);
        slots.set(first + D::kLowpass, s.lowpass);
        slots.set(first + D::kPingPong, s.pingpong);
        slots.set(first + D::kMix, s.mix);
        GraphDescription d = baseDescription();
        if (tempo) d.tempo = *tempo;
        d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
        d.nodes.push_back(NodeDesc{20, NodeKind::delay, 1, first, D::kNumParams, {}});
        d.edges.push_back(EdgeDesc{1, 10, 20, EdgeKind::audio, 0});
        d.edges.push_back(EdgeDesc{2, 20, 1, EdgeKind::audio, 0});
        d.audioClips.push_back(clip(10, 1, 0, clipTicks, 1));
        DAW_CHECK(rig.publish(d));
        DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
    };
    auto click = [] { return makeAsset(1, 1, 4800, [](uint32_t, int64_t i) { return i == 0 ? 1.0f : 0.0f; }); };
    // 1/8 at 120 bpm (12000 frames), ping-pong, lowpass in the loop, half wet.
    const Settings s{375.0f, 1.0f, 5.0f, 0.5f, 6000.0f, 1.0f, 0.5f};

    Rig a, b;
    setUp(a, s, click(), 192, nullptr);
    setUp(b, s, click(), 192, nullptr);
    a.renderFrames(96000, [] { return 256u; });
    std::mt19937 rng(9);
    b.renderFrames(96000, [&] { return 1 + static_cast<uint32_t>(rng() % 1024); });

    // The node driven directly gives the same bits, in any block sizes.
    DelayRig direct;
    direct.apply(s);
    const Signal one = impulse(96000);
    direct.run({one, one}, [] { return 256u; });
    DAW_CHECK(a.left().size() == 96000);
    DAW_CHECK(a.left() == direct.left && a.right() == direct.right);
    DAW_CHECK(a.left() == b.left() && a.right() == b.right());
    DAW_CHECK(a.left()[0] == 0.5f && a.left()[12000] == 0.5f && a.right()[12000] == 0.0f);  // dry, first echo
    DAW_CHECK(a.right()[24000] != 0.0f);

    // TIME-008, DW-162: a locate while playing resets the clip player, not the delay. At frame
    // 6000, before the first echo, locate forward past the clip (tick 3840): every echo still
    // comes, exactly as without the locate.
    Rig c;
    setUp(c, s, click(), 192, nullptr);
    c.renderFrames(6000, [] { return 256u; });
    DAW_CHECK(c.transport().locate(3840));
    c.renderFrames(96000 - 6000, [] { return 256u; });
    DAW_CHECK(c.left() == a.left() && c.right() == a.right());
    DAW_CHECK(!allZero(c.left(), 6000) && !allZero(c.right(), 6000));
    // Locate back to the click instead: the player restarts (the click sounds again at frame 6000)
    // and the delay's echoes of the first click go on under the new ones (a linear,
    // time-invariant effect: the sum of the response and the response 6000 frames later).
    Rig e;
    setUp(e, s, click(), 192, nullptr);
    e.renderFrames(6000, [] { return 256u; });
    DAW_CHECK(e.transport().locate(0));
    e.renderFrames(96000 - 6000, [] { return 256u; });
    double worst = 0;
    for (size_t t = 0; t < 96000; ++t) {
        const double wantL = double{a.left()[t]} + (t >= 6000 ? double{a.left()[t - 6000]} : 0.0);
        const double wantR = double{a.right()[t]} + (t >= 6000 ? double{a.right()[t - 6000]} : 0.0);
        worst = std::max({worst, std::fabs(e.left()[t] - wantL), std::fabs(e.right()[t] - wantR)});
    }
    DAW_CHECK(worst < 1e-6);
    DAW_CHECK(e.left()[6000] == 0.5f && e.left()[12000] == 0.5f && e.left()[18000] == 0.5f);

    // DSP-032: a tempo change while playing moves the synced time with a crossfade. 120 → 60 bpm
    // at tick 1920 (frame 48000); 1/8 goes from 12000 to 24000 frames. In 256-frame blocks the
    // first block at 60 bpm starts at frame 48128 (TIME-007: a block runs at its start tempo).
    // Wet only, no feedback, a 441 Hz sine in.
    const TempoMapDesc change{{{0, 120.0}, {1920, 60.0}}, {{0, 4, 4}}};
    const Settings synced{375.0f, 1.0f, 5.0f, 0.0f, 20000.0f, 0.0f, 1.0f};
    const Signal tone = sine(144000, 441.0, 0.5f);
    Rig f;
    setUp(f, synced, makeAsset(1, 1, 144000, [&](uint32_t, int64_t i) { return tone[static_cast<size_t>(i)]; }), 3840,
          &change);
    f.renderFrames(120000, [] { return 256u; });
    worst = 0;
    for (size_t t = 0; t < 120000; ++t) {
        auto in = [&](int64_t i) { return i >= 0 ? tone[static_cast<size_t>(i)] : 0.0f; };
        const auto ti = static_cast<int64_t>(t);
        float want = 0.0f;
        if (t < 48128) {
            want = in(ti - 12000);
        } else if (t < 48128 + 960) {
            const float w = static_cast<float>(t - 48128 + 1) / 960.0f;
            want = (1.0f - w) * in(ti - 12000) + w * in(ti - 24000);
        } else {
            want = in(ti - 24000);
        }
        worst = std::max({worst, std::fabs(double{f.left()[t]} - want), std::fabs(double{f.right()[t]} - want)});
    }
    DAW_CHECK(worst < 1e-6);
    DAW_CHECK(std::fabs(double{tone[48128 - 12000]} - tone[48128 - 24000]) > 0.5);  // what a jump would do
    DAW_CHECK(maxStep(f.left(), 12001, 120000) < 0.5 * 2 * std::numbers::pi * 441.0 / kRate + 0.002);

    DAW_CHECK(a.engine().telemetry().snapshot().graphLatency == 0);
    DAW_CHECK(a.violations() == 0 && b.violations() == 0 && c.violations() == 0 && e.violations() == 0 &&
              f.violations() == 0 && direct.violations == 0);
    return checks;
}

} // namespace daw::testing
