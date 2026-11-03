// T-073 checks for the built-in reverb (DSP-033, DSP-040, DSP-041, IO-011). Run from
// Tests/DAWEngineTests/ReverbTests.swift; see ReverbChecks.h for why they're C++.
//
// The oracle below is written from the 06 spec text (Reverb.h's signal path), independently of
// nodes/Reverb.cpp and dsp/Hadamard.h: it works in double, keeps every line's whole history
// instead of ring buffers, and multiplies by the Hadamard matrix entry by entry
// ((−1)^popcount(r & c)) instead of the fast transform.

#include "ReverbChecks.h"

#include <algorithm>
#include <array>
#include <bit>
#include <cfloat>
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
#include "daw/EngineFacade.h"
#include "nodes/Reverb.h"
#include "time/TempoMap.h"

using namespace daw;
using namespace daw::testing::nodes;

namespace daw::testing {

namespace {

using R = Reverb;
using Signal = std::vector<float>;

struct Settings {
    float size = 0.5f, decay = 2.0f, damping = 0.5f, predelay = 10.0f, mix = 0.3f;
};

// 06 DSP-033: line lengths at 48 kHz, size 1.
constexpr std::array<double, 8> kSpecBase{2411, 2647, 2953, 3203, 3541, 3833, 4241, 4799};

double hadamard(uint32_t r, uint32_t c) { return std::popcount(r & c) % 2 == 0 ? 1.0 : -1.0; }

// Per-sample model of Reverb.h's signal path, in double, without snapping (it changes values by
// less than 1e-9).
struct Oracle {
    std::vector<double> inL, inR;
    std::array<std::vector<double>, 8> line;
    std::array<double, 8> d{}, z{}, gPrev{};
    double p = 0, mixPrev = 0;
    bool primed = false;

    static double at(const std::vector<double>& h, int64_t t) {
        return t >= 0 && t < static_cast<int64_t>(h.size()) ? h[static_cast<size_t>(t)] : 0.0;
    }
    // The value `delay` frames before frame t, linearly interpolated.
    static double read(const std::vector<double>& h, int64_t t, double delay) {
        const double k = std::floor(delay);
        const double f = delay - k;
        const double a = at(h, t - static_cast<int64_t>(k)), b = at(h, t - static_cast<int64_t>(k) - 1);
        return a + f * (b - a);
    }
    static double glide(double cur, double target) {
        if (target - cur > 0.125) return cur + 0.125;
        if (cur - target > 0.125) return cur - 0.125;
        return target;
    }

    void block(const Signal& l, const Signal& r, size_t from, uint32_t n, const Settings& s, std::vector<double>& outL,
               std::vector<double>& outR) {
        if (n == 0) return;
        const double scale = 0.15 + 0.85 * s.size;
        std::array<double, 8> len{}, g{};
        for (size_t i = 0; i < 8; ++i) {
            len[i] = std::max(1.0, std::round(kSpecBase[i] * scale * kRate / 48000.0));
            g[i] = std::pow(10.0, -3.0 * len[i] / (s.decay * kRate));
        }
        const double pTarget = std::round(s.predelay * kRate / 1000.0);
        const double fc = std::min(18000.0 * std::pow(500.0 / 18000.0, double{s.damping}), 0.45 * kRate);
        const double a = std::exp(-2.0 * std::numbers::pi * fc / kRate);
        if (!primed) {
            d = len, p = pTarget, gPrev = g, mixPrev = s.mix;
            primed = true;
        }
        auto ramp = [n](double prev, double target, uint32_t k) {
            return k + 1 == n ? target : prev + (target - prev) * (k + 1) / n;
        };
        for (uint32_t k = 0; k < n; ++k) {
            const auto t = static_cast<int64_t>(inL.size());
            const double dryL = l[from + k], dryR = r[from + k];
            inL.push_back(dryL);
            inR.push_back(dryR);
            p = glide(p, pTarget);
            const double pL = read(inL, t, p), pR = read(inR, t, p);
            std::array<double, 8> x{}, y{};
            for (size_t i = 0; i < 8; ++i) {
                d[i] = glide(d[i], len[i]);
                x[i] = read(line[i], t, d[i]);
                z[i] = (1 - a) * x[i] + a * z[i];
                y[i] = ramp(gPrev[i], g[i], k) * z[i];
            }
            for (uint32_t row = 0; row < 8; ++row) {
                double m = 0;
                for (uint32_t c = 0; c < 8; ++c) m += hadamard(row, c) * y[c];
                line[row].push_back(m / std::sqrt(8.0) + (row % 2 == 0 ? pL : pR));
            }
            double wL = 0, wR = 0;
            for (uint32_t i = 0; i < 8; ++i) {
                wL += hadamard(1, i) * x[i];
                wR += hadamard(2, i) * x[i];
            }
            const double mx = ramp(mixPrev, s.mix, k);
            outL.push_back((1 - mx) * dryL + mx * 0.25 * wL);
            outR.push_back((1 - mx) * dryR + mx * 0.25 * wR);
        }
        gPrev = g;
        mixPrev = s.mix;
    }
};

// Drives a Reverb directly. `in` holds 0, 1 or 2 channels.
struct RevRig {
    explicit RevRig(uint32_t numParams = R::kNumParams) : params(16), node(0, numParams) {
        trapInstalled = RtTrap::install();  // no Engine here to install it (ENG-030)
        (void)params.allocate(R::kNumParams, 0.0f);
        for (const ParamInfo& p : R::kParamInfo) params.set(p.index, p.def);
        node.prepare(PrepareInfo{kRate, kMaxBlock, 2, 2});
    }

    void apply(const Settings& s) {
        params.set(R::kSize, s.size);
        params.set(R::kDecay, s.decay);
        params.set(R::kDamping, s.damping);
        params.set(R::kPredelay, s.predelay);
        params.set(R::kMix, s.mix);
    }

    // Processes frames [from, from + n) of `in` and appends the output.
    void process(const std::vector<Signal>& in, size_t from, uint32_t n) {
        std::vector<Signal> buf(in.size());
        std::vector<float*> ptr;
        for (size_t c = 0; c < in.size(); ++c) {
            buf[c].assign(in[c].begin() + static_cast<std::ptrdiff_t>(from),
                          in[c].begin() + static_cast<std::ptrdiff_t>(from + n));
            ptr.push_back(buf[c].data());
        }
        Signal l(n, -99.0f), r(n, -99.0f);
        float* out[2] = {l.data(), r.data()};
        NodeIO io;
        if (!ptr.empty()) io.audioIn = AudioBufferView{ptr.data(), static_cast<uint32_t>(ptr.size()), n};
        io.audioOut = AudioBufferView{out, 2, n};
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

    void run(const std::vector<Signal>& in, const std::function<uint32_t()>& nextBlock) {
        const size_t total = in.empty() ? 0 : in[0].size();
        size_t pos = 0;
        for (int guard = 0; pos < total && guard < 1'000'000; ++guard) {
            const auto n = static_cast<uint32_t>(std::min<size_t>(nextBlock(), total - pos));
            process(in, pos, n);
            pos += n;
        }
    }

    ParamSlotTable params;
    Reverb node;
    TempoMap tempo;
    Signal left, right;
    uint64_t violations = 0;
    bool trapInstalled = false;
};

Signal impulse(size_t n, float amp = 1.0f) {
    Signal s(n, 0.0f);
    if (n > 0) s[0] = amp;
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

bool allZero(const Signal& s, size_t from = 0) {
    return std::all_of(s.begin() + static_cast<std::ptrdiff_t>(std::min(from, s.size())), s.end(),
                       [](float x) { return x == 0.0f; });
}

// Index of the first non-zero sample (s.size() if none).
size_t firstNonZero(const Signal& s) {
    return static_cast<size_t>(std::find_if(s.begin(), s.end(), [](float x) { return x != 0.0f; }) - s.begin());
}

// RT60 from the Schroeder backward-integrated energy of `ir` lowpassed at 200 Hz (four one-poles),
// fitted between −5 and −35 dB.
double lowFrequencyRt60(const Signal& ir) {
    std::vector<double> x(ir.begin(), ir.end());
    const double c = std::exp(-2.0 * std::numbers::pi * 200.0 / kRate);
    for (int pass = 0; pass < 4; ++pass) {
        double z = 0;
        for (double& v : x) v = z = (1 - c) * v + c * z;
    }
    std::vector<double> edc(x.size() + 1, 0.0);
    for (size_t i = x.size(); i-- > 0;) edc[i] = edc[i + 1] + x[i] * x[i];
    size_t i5 = 0, i35 = 0;
    for (size_t i = 0; i < x.size(); ++i) {
        const double db = 10 * std::log10(edc[i] / edc[0]);
        if (i5 == 0 && db < -5) i5 = i;
        if (db < -35) {
            i35 = i;
            break;
        }
    }
    if (i5 == 0 || i35 <= i5) return 0;
    return 60.0 / (30.0 / (static_cast<double>(i35 - i5) / kRate));
}

// Energy of the first difference over energy, in [from, to): high-frequency share.
double hfShare(const Signal& s, size_t from, size_t to) {
    double e = 0, de = 0;
    for (size_t i = from; i < to; ++i) {
        e += double{s[i]} * s[i];
        const double diff = double{s[i]} - s[i - 1];
        de += diff * diff;
    }
    return e > 0 ? de / e : 0;
}

double correlation(const Signal& a, const Signal& b, size_t from, size_t to) {
    double ab = 0, aa = 0, bb = 0;
    for (size_t i = from; i < to; ++i) {
        ab += double{a[i]} * b[i];
        aa += double{a[i]} * a[i];
        bb += double{b[i]} * b[i];
    }
    return ab / std::sqrt(aa * bb);
}

double maxError(const Signal& got, const std::vector<double>& want) {
    double worst = got.size() == want.size() ? 0.0 : 1e9;
    for (size_t i = 0; i < std::min(got.size(), want.size()); ++i) worst = std::max(worst, std::fabs(got[i] - want[i]));
    return worst;
}

struct Response {
    Signal left, right;
    uint64_t violations;
};

// The response to `inL`/`inR` with fixed 512-frame blocks.
Response response(const Settings& s, const Signal& inL, const Signal& inR) {
    RevRig rig;
    rig.apply(s);
    rig.run({inL, inR}, [] { return 512u; });
    return {rig.left, rig.right, rig.violations};
}

} // namespace

CheckResult reverbParams() {
    CheckResult checks;
    DAW_CHECK(R::kNumParams == 5);
    for (uint32_t i = 0; i < R::kNumParams; ++i) {
        const ParamInfo& p = R::kParamInfo[i];
        DAW_CHECK(p.index == i);
        DAW_CHECK(p.min <= p.def && p.def <= p.max);
        DAW_CHECK(p.automatable);
    }
    DAW_CHECK(R::kParamInfo[R::kSize].def == 0.5f && R::kParamInfo[R::kDecay].def == 2.0f);
    DAW_CHECK(R::kParamInfo[R::kDamping].def == 0.5f && R::kParamInfo[R::kPredelay].def == 10.0f);
    DAW_CHECK(R::kParamInfo[R::kMix].def == 0.3f);
    DAW_CHECK(R::kParamInfo[R::kDecay].min == 0.1f && R::kParamInfo[R::kDecay].max == 20.0f);
    DAW_CHECK(R::kParamInfo[R::kPredelay].max == 200.0f);
    for (size_t i = 0; i < 8; ++i) DAW_CHECK(R::kBaseFrames[i] == kSpecBase[i]);
    DAW_CHECK(R(0, 0).latencySamples() == 0);  // the pre-delay is part of the effect
    // Line lengths: size scales 0.15 … 1, and they follow the rate.
    DAW_CHECK(R::lineLengths(1.0, 48000.0)[0] == 2411 && R::lineLengths(1.0, 48000.0)[7] == 4799);
    DAW_CHECK(R::lineLengths(0.5, 48000.0)[0] == 1386);  // round(2411 · 0.575)
    DAW_CHECK(R::lineLengths(0.0, 48000.0)[0] == 362);   // round(2411 · 0.15)
    DAW_CHECK(R::lineLengths(1.0, 96000.0)[7] == 9598);
    DAW_CHECK(R::tailSeconds(2.0) == 2.0 && R::tailSeconds(2.0, 90.0) == 3.0);

    // DSP-041: the table reaches the model through the facade.
    DriverConfigPOD config;
    config.sampleRate = kRate;
    if (EngineFacade* facade = EngineFacade::create(EngineMode::offline, config)) {
        const std::string json = facade->paramInfoJSON(NodeKind::reverb);
        DAW_CHECK(json.find("\"index\":0,\"id\":\"size\"") != std::string::npos);
        DAW_CHECK(json.find("\"index\":1,\"id\":\"decay\"") != std::string::npos);
        DAW_CHECK(json.find("\"index\":2,\"id\":\"damping\"") != std::string::npos);
        DAW_CHECK(json.find("\"index\":3,\"id\":\"predelay\"") != std::string::npos);
        DAW_CHECK(json.find("\"index\":4,\"id\":\"mix\"") != std::string::npos);
        DAW_CHECK(json.find("\"default\":2.000000,\"curve\":\"log\",\"unit\":\"s\"") != std::string::npos);
        releaseFacade(facade);
    } else {
        DAW_CHECK(false);
    }

    // Defaults: numParams 0, NaN slots and default slot values all render the same; clamping.
    const Signal in = bursts(9600, 3);
    uint64_t violations = 0;
    auto renderWith = [&](uint32_t numParams, const std::function<void(ParamSlotTable&)>& set) {
        RevRig rig(numParams);
        set(rig.params);
        rig.run({in, in}, [] { return 512u; });
        violations += rig.violations;
        DAW_CHECK(rig.trapInstalled || !DAW_RT_TRAP);  // otherwise the scopes count nothing
        return rig.left;
    };
    auto withValues = [&](const Settings& s) {
        return renderWith(R::kNumParams, [&](ParamSlotTable& p) {
            p.set(R::kSize, s.size);
            p.set(R::kDecay, s.decay);
            p.set(R::kDamping, s.damping);
            p.set(R::kPredelay, s.predelay);
            p.set(R::kMix, s.mix);
        });
    };
    const Signal defaults = renderWith(R::kNumParams, [](ParamSlotTable&) {});
    DAW_CHECK(defaults != in);
    DAW_CHECK(renderWith(0, [](ParamSlotTable& p) { p.set(R::kMix, 1.0f); }) == defaults);
    DAW_CHECK(renderWith(R::kNumParams, [](ParamSlotTable& p) {
                  for (uint32_t i = 0; i < R::kNumParams; ++i) p.set(i, std::nanf(""));
              }) == defaults);
    // Out of range values clamp: size 5 → 1, decay 100 → 20, damping −1 → 0, predelay −5 → 0,
    // mix 2 → 1.
    DAW_CHECK(withValues({5.0f, 100.0f, -1.0f, -5.0f, 2.0f}) == withValues({1.0f, 20.0f, 0.0f, 0.0f, 1.0f}));
    DAW_CHECK(withValues({-1.0f, 0.0f, 3.0f, 900.0f, -1.0f}) == withValues({0.0f, 0.1f, 1.0f, 200.0f, 0.0f}));
    DAW_CHECK(violations == 0);
    return checks;
}

CheckResult reverbOracle() {
    CheckResult checks;
    uint64_t violations = 0;
    const size_t total = 72000;
    const Signal l = bursts(total, 31), r = bursts(total, 32);
    // Constant params, fixed blocks.
    {
        RevRig rig;
        Oracle oracle;
        const Settings s{0.7f, 1.5f, 0.3f, 12.5f, 0.6f};
        rig.apply(s);
        std::vector<double> wantL, wantR;
        for (size_t pos = 0; pos < total; pos += 480) {
            rig.process({l, r}, pos, 480);
            oracle.block(l, r, pos, 480, s, wantL, wantR);
        }
        DAW_CHECK(maxError(rig.left, wantL) < 2e-5);
        DAW_CHECK(maxError(rig.right, wantR) < 2e-5);
        violations += rig.violations;
    }
    // Every param changes between blocks of random sizes: size and pre-delay glide (by 1/8 frame
    // per frame, so the reads interpolate), decay and mix ramp, damping is latched.
    {
        RevRig rig;
        Oracle oracle;
        std::mt19937 rng(5);
        std::vector<double> wantL, wantR;
        size_t pos = 0;
        int block = 0;
        while (pos < total) {
            Settings s{0.4f, 2.0f, 0.5f, 5.0f, 0.5f};
            if (block % 30 >= 15) s = Settings{0.55f, 0.6f, 0.9f, 40.0f, 0.8f};
            if (block % 11 == 3) s.mix = 1.0f;
            if (block % 17 == 9) s.decay = 8.0f;
            rig.apply(s);
            const auto n = static_cast<uint32_t>(std::min<size_t>(rng() % 1200, total - pos));
            rig.process({l, r}, pos, n);
            oracle.block(l, r, pos, n, s, wantL, wantR);
            pos += n;
            ++block;
        }
        DAW_CHECK(maxError(rig.left, wantL) < 2e-5);
        DAW_CHECK(maxError(rig.right, wantR) < 2e-5);
        violations += rig.violations;
    }
    DAW_CHECK(violations == 0);
    return checks;
}

CheckResult reverbResponse() {
    CheckResult checks;
    uint64_t violations = 0;
    const size_t n = 4 * 48000;
    const Signal one = impulse(n), zero(n, 0.0f);

    // First arrival: an impulse on L at frame 0 enters the even lines after the pre-delay and
    // comes out of the shortest line (line 0) at frame P + L_0, with tap +1 on both outputs.
    for (const auto& [size, predelay, first] :
         {std::tuple{0.5f, 10.0f, size_t{480 + 1386}}, std::tuple{0.5f, 0.0f, size_t{1386}},
          std::tuple{1.0f, 10.0f, size_t{480 + 2411}}, std::tuple{0.0f, 200.0f, size_t{9600 + 362}}}) {
        Response rig = response({size, 2.0f, 0.5f, predelay, 1.0f}, one, zero);
        DAW_CHECK(firstNonZero(rig.left) == first && firstNonZero(rig.right) == first);
        DAW_CHECK(rig.left[first] == 0.25f && rig.right[first] == 0.25f);  // kOutGain · 1
        violations += rig.violations;
    }

    // Decay is the low-frequency RT60 (±10 %), whatever the size and damping.
    for (float decay : {0.5f, 1.0f, 3.0f})
        for (float size : {0.2f, 0.8f}) {
            Response rig = response({size, decay, 0.6f, 0.0f, 1.0f}, one, one);
            const double rt60 = lowFrequencyRt60(rig.left);
            DAW_CHECK(std::fabs(rt60 / decay - 1.0) < 0.1);
            violations += rig.violations;
        }

    // Damping takes high frequencies out of the tail; 0 leaves them in.
    {
        Response bright = response({0.5f, 2.0f, 0.0f, 0.0f, 1.0f}, one, zero);
        Response dark = response({0.5f, 2.0f, 1.0f, 0.0f, 1.0f}, one, zero);
        const double b = hfShare(bright.left, 14400, 28800), d = hfShare(dark.left, 14400, 28800);
        DAW_CHECK(d < 0.25 * b);
        violations += bright.violations + dark.violations;
    }

    // Stereo: the two outputs are decorrelated, for a one-sided and a centred source.
    for (bool centred : {false, true}) {
        Response rig = response({0.5f, 2.0f, 0.5f, 0.0f, 1.0f}, one, centred ? one : zero);
        DAW_CHECK(std::fabs(correlation(rig.left, rig.right, 4800, 96000)) < 0.2);
        violations += rig.violations;
    }

    // Mix 0 is the input bit for bit; mix 1 has no dry (frame 0 of an impulse is silent).
    {
        const Signal l = bursts(48000, 41), r = bursts(48000, 42);
        RevRig dry;
        dry.apply({0.5f, 2.0f, 0.5f, 10.0f, 0.0f});
        dry.run({l, r}, [] { return 512u; });
        DAW_CHECK(dry.left == l && dry.right == r);
        Response wet = response({0.5f, 2.0f, 0.5f, 10.0f, 1.0f}, one, one);
        DAW_CHECK(wet.left[0] == 0.0f && wet.right[0] == 0.0f);
        violations += dry.violations + wet.violations;
    }

    // A mono input feeds both sides: the same as a stereo input with L copied to R.
    {
        const Signal m = bursts(48000, 43);
        RevRig mono, stereo;
        mono.run({m}, [] { return 512u; });
        stereo.run({m, m}, [] { return 512u; });
        DAW_CHECK(mono.left == stereo.left && mono.right == stereo.right);
        violations += mono.violations + stereo.violations;
    }
    DAW_CHECK(violations == 0);
    return checks;
}

CheckResult reverbRobustness() {
    CheckResult checks;
    uint64_t violations = 0;
    // ENG-004: random block sizes (0 … 4096, zeros included) match fixed 512-frame blocks bit for
    // bit with constant params.
    for (const Settings& s : {Settings{}, Settings{0.9f, 6.0f, 0.2f, 37.0f, 0.7f}}) {
        const size_t total = 200000;
        const Signal l = bursts(total, 51), r = bursts(total, 52);
        RevRig fixed, fuzzed;
        fixed.apply(s);
        fuzzed.apply(s);
        fixed.run({l, r}, [] { return 512u; });
        std::mt19937 rng(7);
        fuzzed.run({l, r}, [&] {
            const uint32_t pick = rng() % 10;
            return pick == 0 ? 0u : pick == 1 ? kMaxBlock : static_cast<uint32_t>(rng() % kMaxBlock);
        });
        DAW_CHECK(fixed.left == fuzzed.left && fixed.right == fuzzed.right);
        violations += fixed.violations + fuzzed.violations;
    }

    // DSP-040: silence in → silence out after the tail. Every value in the network snaps to
    // exactly 0 below −180 dBFS, so the output becomes exactly 0 (about decay · 3 s after a
    // 0 dBFS input stops) and never holds a denormal on the way.
    for (const auto& [decay, seconds] : {std::pair{2.0f, 9}, std::pair{20.0f, 70}}) {
        RevRig rig;
        rig.apply({0.7f, decay, 0.3f, 20.0f, 1.0f});
        const Signal loud = bursts(48000, 61);
        rig.run({loud, loud}, [] { return 512u; });
        rig.left.clear();
        rig.right.clear();
        const Signal quiet(static_cast<size_t>(seconds) * 48000, 0.0f);
        rig.run({quiet, quiet}, [] { return 512u; });
        DAW_CHECK(!allZero(rig.left));  // there was a tail
        const size_t lastSecond = rig.left.size() - 48000;
        DAW_CHECK(allZero(rig.left, lastSecond) && allZero(rig.right, lastSecond));
        DAW_CHECK(rig.node.isSilent());
        bool normal = true;
        for (const Signal* s : {&rig.left, &rig.right})
            for (float x : *s) normal = normal && (x == 0.0f || std::fabs(x) >= FLT_MIN);
        DAW_CHECK(normal);
        violations += rig.violations;
    }

    // DSP-040: NaN guard. A block with a NaN (or Inf) outputs silence, is counted and clears the
    // network; the next block is what a fresh reverb makes of it.
    {
        const Signal in = bursts(2048, 71);
        RevRig rig, fresh;
        rig.process({in, in}, 0, 512);
        Signal bad = in;
        bad[512 + 17] = std::numeric_limits<float>::quiet_NaN();
        rig.process({in, bad}, 512, 512);
        DAW_CHECK(rig.node.nanBlocks() == 1);
        DAW_CHECK(allZero(rig.left, 512) && allZero(rig.right, 512));
        DAW_CHECK(rig.node.isSilent());
        rig.process({in, in}, 1024, 512);
        fresh.process({in, in}, 1024, 512);
        DAW_CHECK(std::equal(fresh.left.begin(), fresh.left.end(), rig.left.begin() + 1024));
        DAW_CHECK(std::equal(fresh.right.begin(), fresh.right.end(), rig.right.begin() + 1024));
        bad = in;
        bad[1536 + 3] = std::numeric_limits<float>::infinity();
        rig.process({bad, in}, 1536, 512);
        DAW_CHECK(rig.node.nanBlocks() == 2);
        DAW_CHECK(allZero(rig.left, 1536));
        violations += rig.violations + fresh.violations;
    }

    // The tail rings on without an input (no channels) and across reset() (TIME-008: a locate
    // keeps effect tails), exactly as with a silent input.
    {
        const Signal in = bursts(4800, 81), quiet(48000, 0.0f);
        RevRig silent, none, reset;
        for (RevRig* rig : {&silent, &none, &reset}) rig->run({in, in}, [] { return 480u; });
        silent.run({quiet, quiet}, [] { return 480u; });
        for (size_t pos = 0; pos < quiet.size(); pos += 480) {
            none.process({}, pos, 480);
            reset.node.reset();
            reset.process({quiet, quiet}, pos, 480);
        }
        DAW_CHECK(!allZero(silent.left, 4800));
        DAW_CHECK(none.left == silent.left && none.right == silent.right);
        DAW_CHECK(reset.left == silent.left && reset.right == silent.right);
        violations += silent.violations + none.violations + reset.violations;
    }
    DAW_CHECK(violations == 0);
    return checks;
}

CheckResult reverbThroughEngine() {
    CheckResult checks;
    const Settings s{0.6f, 1.2f, 0.4f, 15.0f, 0.5f};
    // impulse player 10 → reverb 20 → master 1. The player duplicates the mono asset to L/R.
    auto setUp = [&](Rig& rig) {
        rig.addAsset(makeAsset(1, 1, 4800, [](uint32_t, int64_t i) { return i == 0 ? 1.0f : 0.0f; }));
        auto params = rig.engine().params().allocate(R::kNumParams, 0.0f);
        DAW_CHECK(params.ok());
        const ParamID first = params.value();
        ParamSlotTable& slots = rig.engine().params();
        slots.set(first + R::kSize, s.size);
        slots.set(first + R::kDecay, s.decay);
        slots.set(first + R::kDamping, s.damping);
        slots.set(first + R::kPredelay, s.predelay);
        slots.set(first + R::kMix, s.mix);
        GraphDescription d = baseDescription();
        d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
        d.nodes.push_back(NodeDesc{20, NodeKind::reverb, 1, first, R::kNumParams, {}});
        d.edges.push_back(EdgeDesc{1, 10, 20, EdgeKind::audio, 0});
        d.edges.push_back(EdgeDesc{2, 20, 1, EdgeKind::audio, 0});
        d.audioClips.push_back(clip(10, 1, 0, 192, 1));
        DAW_CHECK(rig.publish(d));
        DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
    };

    Rig a, b;
    setUp(a);
    setUp(b);
    a.renderFrames(96000, [] { return 256u; });
    std::mt19937 rng(9);
    b.renderFrames(96000, [&] { return 1 + static_cast<uint32_t>(rng() % 1024); });

    // The node driven directly gives the same bits.
    RevRig direct;
    direct.apply(s);
    const Signal one = impulse(96000);
    direct.run({one, one}, [] { return 256u; });
    DAW_CHECK(a.left().size() == 96000);
    DAW_CHECK(a.left() == direct.left && a.right() == direct.right);
    DAW_CHECK(a.left()[0] == 0.5f);  // dry × (1 − mix)
    DAW_CHECK(!allZero(a.left(), 4800) && !allZero(a.right(), 4800));
    // IO-011: two fresh engines, any block sizes, the same bits.
    DAW_CHECK(a.left() == b.left() && a.right() == b.right());

    // TIME-008: a locate while playing resets the clip player, not the reverb: the tail goes on
    // exactly as without the locate (the clip has ended, so the player is silent either way).
    Rig c;
    setUp(c);
    c.renderFrames(9600, [] { return 256u; });
    DAW_CHECK(c.transport().locate(3840));
    c.renderFrames(96000 - 9600, [] { return 256u; });
    DAW_CHECK(c.left() == a.left() && c.right() == a.right());

    DAW_CHECK(a.engine().telemetry().snapshot().graphLatency == 0);
    DAW_CHECK(a.violations() == 0 && b.violations() == 0 && c.violations() == 0 && direct.violations == 0);
    return checks;
}

} // namespace daw::testing
