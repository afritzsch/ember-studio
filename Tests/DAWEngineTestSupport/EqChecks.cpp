// T-070 checks for the built-in EQ (DSP-030, DSP-040, DSP-041) and the registry's param tables.
// Run from Tests/DAWEngineTests/EqTests.swift; see EqChecks.h for why they're C++.
//
// The oracle below is written from the RBJ cookbook text, independently of dsp/Biquad.h: it keeps
// a0 unnormalized and evaluates H(e^jw) with complex arithmetic.

#include "EqChecks.h"

#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <limits>
#include <numbers>
#include <random>
#include <span>
#include <string>
#include <thread>
#include <vector>

#include <unistd.h>

#include "NodeTestHarness.h"
#include "TestNodes.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/ProcessContext.h"
#include "core/RtTrap.h"
#include "core/Telemetry.h"
#include "daw/EngineFacade.h"
#include "graph/NodeRegistry.h"
#include "nodes/ChannelStrip.h"
#include "nodes/Compressor.h"
#include "nodes/Delay.h"
#include "nodes/Eq.h"
#include "nodes/GainNode.h"
#include "nodes/Metronome.h"
#include "nodes/Reverb.h"
#include "nodes/Sampler.h"
#include "time/TempoMap.h"

using namespace daw;
using namespace daw::testing::nodes;

namespace daw::testing {

namespace {

using Cx = std::complex<double>;

// One band as the oracle sees it. `slotOffset` of 0 means the HP (see Eq.h's table).
struct Biquad {
    double b0, b1, b2, a0, a1, a2;

    Cx response(double hz, double rate) const {
        const Cx z1 = std::polar(1.0, -2.0 * std::numbers::pi * hz / rate);
        return (b0 + z1 * (b1 + z1 * b2)) / (a0 + z1 * (a1 + z1 * a2));
    }

    // Frames for the slowest pole to settle by e^-12 (≈ 6e-6, far under 0.1 dB).
    double settleFrames() const {
        const double p = a1 / a0, q = a2 / a0;
        const double disc = p * p - 4 * q;
        const double r = disc < 0 ? std::sqrt(q) : (std::fabs(p) + std::sqrt(disc)) / 2.0;
        return r <= 0 ? 0.0 : 12.0 / -std::log(r);
    }
};

enum class Shape { highPass, lowShelf, peak, highShelf, lowPass };

struct Rbj {
    double c, s, alpha, A, rootA;
};

Rbj rbj(double hz, double q, double db, double rate) {
    const double w = 2.0 * std::numbers::pi * hz / rate;
    const double A = std::pow(10.0, db / 40.0);
    return {std::cos(w), std::sin(w), std::sin(w) / (2.0 * q), A, std::sqrt(A)};
}

// The cookbook's formulas, unnormalized.
Biquad oracle(Shape shape, double hz, double q, double db, double rate) {
    const auto [c, s, alpha, A, rootA] = rbj(hz, q, db, rate);
    (void)s;
    switch (shape) {
        case Shape::lowPass: return {(1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha};
        case Shape::highPass: return {(1 + c) / 2, -1 - c, (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha};
        case Shape::peak: return {1 + alpha * A, -2 * c, 1 - alpha * A, 1 + alpha / A, -2 * c, 1 - alpha / A};
        case Shape::lowShelf: {
            const double t = 2 * rootA * alpha;
            return {A * (A + 1 - (A - 1) * c + t), 2 * A * (A - 1 - (A + 1) * c), A * (A + 1 - (A - 1) * c - t),
                    A + 1 + (A - 1) * c + t,        -2 * (A - 1 + (A + 1) * c),     A + 1 + (A - 1) * c - t};
        }
        case Shape::highShelf: {
            const double t = 2 * rootA * alpha;
            return {A * (A + 1 + (A - 1) * c + t), -2 * A * (A - 1 + (A + 1) * c), A * (A + 1 + (A - 1) * c - t),
                    A + 1 - (A - 1) * c + t,        2 * (A - 1 - (A + 1) * c),      A + 1 - (A - 1) * c - t};
        }
    }
    return {1, 0, 0, 1, 0, 0};
}

// One band's settings, by Eq band index.
struct BandSetting {
    uint32_t band;
    Shape shape;
    float hz, q, db;
};

// Writes `s` into the rig's slots; the other bands stay at their defaults.
struct EqRig {
    explicit EqRig(double rateIn = kRate, uint32_t numParams = Eq::kNumParams, Telemetry* telemetry = nullptr)
        : rate(rateIn), params(32), node(0, numParams, telemetry) {
        trapInstalled = RtTrap::install();  // no Engine here to install it (ENG-030)
        (void)params.allocate(Eq::kNumParams, 0.0f);
        for (const ParamInfo& p : Eq::kParamInfo) params.set(p.index, p.def);
        node.prepare(PrepareInfo{rate, kMaxBlock, 2, 2});
    }

    void band(const BandSetting& s) {
        const uint32_t base = s.band == Eq::kHighPass ? Eq::kHpOn
                            : s.band == Eq::kLowShelf ? Eq::kLowOn
                            : s.band == Eq::kPeak1    ? Eq::kPeak1On
                            : s.band == Eq::kPeak2    ? Eq::kPeak2On
                            : s.band == Eq::kHighShelf ? Eq::kHighOn
                                                       : Eq::kLpOn;
        params.set(base, 1.0f);
        params.set(base + 1, s.hz);
        if (s.band == Eq::kHighPass || s.band == Eq::kLowPass) {
            params.set(base + 2, s.q);
        } else {
            params.set(base + 2, s.db);
            params.set(base + 3, s.q);
        }
    }

    // Frames [from, from + n) of `in`, appended to left/right. `in` empty: no input at all.
    void process(const std::vector<std::vector<float>>& in, size_t from, uint32_t n) {
        std::vector<std::vector<float>> copies(in.size());
        std::vector<float*> inPtr;
        for (size_t c = 0; c < in.size(); ++c) {
            copies[c].assign(in[c].begin() + static_cast<std::ptrdiff_t>(from),
                             in[c].begin() + static_cast<std::ptrdiff_t>(from + n));
            inPtr.push_back(copies[c].data());
        }
        std::vector<float> l(n, -99.0f), r(n, -99.0f);
        float* out[2] = {l.data(), r.data()};
        NodeIO io;
        if (!inPtr.empty()) io.audioIn = AudioBufferView{inPtr.data(), static_cast<uint32_t>(inPtr.size()), n};
        io.audioOut = AudioBufferView{out, 2, n};
        TransportBlock block{false, false, 0, {}, &tempo};
        ProcessContext ctx{n, rate, block, params};
        {
            RtScope scope;
            node.process(ctx, io);
            violations += scope.violations();
        }
        left.insert(left.end(), l.begin(), l.end());
        right.insert(right.end(), r.begin(), r.end());
    }

    void run(const std::vector<std::vector<float>>& in, const std::function<uint32_t()>& nextBlock) {
        const size_t total = in.empty() ? 0 : in[0].size();
        size_t pos = 0;
        for (int guard = 0; pos < total && guard < 2'000'000; ++guard) {
            const auto n = static_cast<uint32_t>(std::min<size_t>(nextBlock(), total - pos));
            process(in, pos, n);
            pos += n;
        }
    }

    double rate;
    ParamSlotTable params;
    Eq node;
    TempoMap tempo;
    std::vector<float> left, right;
    uint64_t violations = 0;
    bool trapInstalled = false;
};

std::vector<float> constant(size_t n, float v) { return std::vector<float>(n, v); }

std::vector<float> sine(size_t n, double hz, double amp, double rate = kRate, double phase = 0.0) {
    std::vector<float> s(n);
    for (size_t i = 0; i < n; ++i)
        s[i] = static_cast<float>(amp * std::sin(2 * std::numbers::pi * hz * static_cast<double>(i) / rate + phase));
    return s;
}

std::vector<float> noiseBursts(size_t n, uint32_t seed) {
    std::mt19937 rng(seed);
    std::uniform_real_distribution<float> u(-1.0f, 1.0f);
    std::uniform_real_distribution<double> levelDb(-50.0, 0.0);
    std::vector<float> s(n, 0.0f);
    size_t i = 0;
    while (i < n) {
        const size_t len = 400 + rng() % 5000;
        const bool gap = rng() % 4 == 0;
        const auto amp = static_cast<float>(std::pow(10.0, levelDb(rng) / 20.0));
        for (size_t k = 0; k < len && i < n; ++k, ++i) s[i] = gap ? 0.0f : amp * u(rng);
    }
    return s;
}

// A's amplitude and phase at `hz`, over a window holding a whole number of cycles (integer hz and
// a one-second-at-`rate` window), so other whole-cycle tones don't leak in.
Cx projection(const std::vector<float>& y, size_t from, size_t frames, double hz, double rate) {
    Cx sum = 0;
    for (size_t i = 0; i < frames; ++i) {
        const double w = 2 * std::numbers::pi * hz * static_cast<double>(i) / rate;
        sum += double{y[from + i]} * Cx(std::sin(w), -std::cos(w));  // conj of e^{j(w−π/2)}
    }
    return sum * (2.0 / static_cast<double>(frames));
}

std::vector<double> probesFor(double rate) {
    std::vector<double> all{20, 47, 100, 220, 440, 1000, 2000, 3000, 5000, 8000, 11000, 12000, 16000, 19000, 21000, 30000, 40000};
    const double nyquist = rate / 2.0;
    all.push_back(std::floor(nyquist) - 500);
    all.push_back(std::floor(nyquist) - 100);
    all.push_back(std::floor(nyquist) - 30);
    std::sort(all.begin(), all.end());
    all.erase(std::unique(all.begin(), all.end()), all.end());
    std::erase_if(all, [&](double f) { return f >= nyquist; });
    return all;
}

struct Case {
    std::vector<BandSetting> bands;  // the bands to switch on (others stay at their defaults: flat)
};

} // namespace

CheckResult eqParams() {
    CheckResult checks;
    DAW_CHECK(Eq::kNumParams == 22 && Eq::kNumBands == 6);
    for (uint32_t i = 0; i < Eq::kNumParams; ++i) {
        const ParamInfo& p = Eq::kParamInfo[i];
        DAW_CHECK(p.index == i);
        DAW_CHECK(p.min <= p.def && p.def <= p.max);
    }
    DAW_CHECK(Eq(0, 0).latencySamples() == 0);

    // DSP-041: every built-in kind with a table publishes it through the registry, unchanged.
    auto same = [](std::span<const ParamInfo> a, std::span<const ParamInfo> b) {
        return a.size() == b.size() && a.data() == b.data();
    };
    DAW_CHECK(same(NodeRegistry::paramInfo(NodeKind::eq), Eq::kParamInfo));
    DAW_CHECK(same(NodeRegistry::paramInfo(NodeKind::compressor), Compressor::kParamInfo));
    DAW_CHECK(same(NodeRegistry::paramInfo(NodeKind::delay), Delay::kParamInfo));
    DAW_CHECK(same(NodeRegistry::paramInfo(NodeKind::reverb), Reverb::kParamInfo));
    DAW_CHECK(same(NodeRegistry::paramInfo(NodeKind::metronome), Metronome::kParamInfo));
    DAW_CHECK(same(NodeRegistry::paramInfo(NodeKind::sampler), Sampler::kParamInfo));
    DAW_CHECK(same(NodeRegistry::paramInfo(NodeKind::channelStrip), ChannelStrip::kParamInfo));
    DAW_CHECK(same(NodeRegistry::paramInfo(NodeKind::gain), GainNode::kParamInfo));
    DAW_CHECK(NodeRegistry::paramInfo(NodeKind::audioClipPlayer).empty());
    DAW_CHECK(NodeRegistry::paramInfo(NodeKind::auPlugin).empty());
    DAW_CHECK(NodeRegistry::paramInfo(NodeKind::master).empty());

    // A per-engine registry carries the tables too; a replaced factory keeps its kind's table.
    NodeRegistry registry = NodeRegistry::withBuiltins();
    DAW_CHECK(registerBuiltinNodes(registry, [](uint64_t) { return AudioAssetRef{}; }, nullptr).ok());
    const NodeKindInfo* eqKind = registry.find(NodeKind::eq);
    DAW_CHECK(eqKind != nullptr && same(eqKind->paramInfo, Eq::kParamInfo));
    const NodeKindInfo* gainKind = registry.find(NodeKind::gain);
    DAW_CHECK(gainKind != nullptr && same(gainKind->paramInfo, GainNode::kParamInfo));
    NodeKindInfo replacement{[](const NodeCreateInfo&) -> Result<std::unique_ptr<Node>> { return std::unique_ptr<Node>{}; }};
    DAW_CHECK(registry.set(NodeKind::eq, std::move(replacement)).ok());
    eqKind = registry.find(NodeKind::eq);
    DAW_CHECK(eqKind != nullptr && same(eqKind->paramInfo, Eq::kParamInfo));

    // The table reaches the model through the facade, which no longer lists kinds by hand.
    DriverConfigPOD config;
    config.sampleRate = kRate;
    if (EngineFacade* facade = EngineFacade::create(EngineMode::offline, config)) {
        const std::string eq = facade->paramInfoJSON(NodeKind::eq);
        DAW_CHECK(eq.find("\"index\":0,\"id\":\"hpOn\"") != std::string::npos);
        DAW_CHECK(eq.find("\"index\":5,\"id\":\"lowGain\"") != std::string::npos);
        DAW_CHECK(eq.find("\"index\":21,\"id\":\"lpQ\"") != std::string::npos);
        DAW_CHECK(eq.find("\"curve\":\"log\"") != std::string::npos);
        const std::string sampler = facade->paramInfoJSON(NodeKind::sampler);
        DAW_CHECK(sampler.find("\"index\":3,\"id\":\"release\"") != std::string::npos);
        DAW_CHECK(sampler.find("\"default\":0.200000") != std::string::npos);
        DAW_CHECK(facade->paramInfoJSON(NodeKind::audioClipPlayer) == "[]");
        releaseFacade(facade);
    } else {
        DAW_CHECK(false);
    }

    const auto in = sine(4096, 441, 0.9);
    // Default EQ, bit for bit flat: every band on at 0 dB is H(z) = 1, HP/LP off.
    {
        EqRig rig;
        rig.run({in, in}, [] { return 512u; });
        DAW_CHECK(rig.left == in && rig.right == in);
        DAW_CHECK(rig.violations == 0);
        DAW_CHECK(rig.trapInstalled || !DAW_RT_TRAP);  // otherwise the scopes count nothing
    }
    // Defaults beyond numParams; NaN slots read as defaults; default-valued slots.
    {
        EqRig none(kRate, 0);
        none.params.set(Eq::kPeak1Gain, 24.0f);  // ignored: beyond numParams
        none.run({in, in}, [] { return 512u; });
        DAW_CHECK(none.left == in);
        EqRig nanSlots;
        for (uint32_t i = 0; i < Eq::kNumParams; ++i) nanSlots.params.set(i, std::nanf(""));
        nanSlots.run({in, in}, [] { return 512u; });
        DAW_CHECK(nanSlots.left == in);
        DAW_CHECK(none.violations == 0 && nanSlots.violations == 0);
    }
    // Out of range is clamped: +40 dB → +24; 100 kHz → 20 kHz; Q 1000 → 10.
    {
        EqRig clamped, limit;
        clamped.band({Eq::kPeak1, Shape::peak, 1000.0f, 1000.0f, 40.0f});
        limit.band({Eq::kPeak1, Shape::peak, 1000.0f, 10.0f, 24.0f});
        clamped.params.set(Eq::kPeak2On, 1.0f);
        clamped.params.set(Eq::kPeak2Freq, 100000.0f);
        limit.params.set(Eq::kPeak2Freq, 20000.0f);
        clamped.run({in, in}, [] { return 512u; });
        limit.run({in, in}, [] { return 512u; });
        DAW_CHECK(clamped.left == limit.left);
        DAW_CHECK(clamped.left != in);
        DAW_CHECK(clamped.violations == 0 && limit.violations == 0);
    }
    return checks;
}

CheckResult eqResponse() {
    CheckResult checks;
    const std::vector<Case> cases = {
        {{{Eq::kLowShelf, Shape::lowShelf, 200.0f, Eq::kButterworthQ, 6.0f}}},
        {{{Eq::kLowShelf, Shape::lowShelf, 80.0f, 2.0f, -12.0f}}},
        {{{Eq::kPeak1, Shape::peak, 1000.0f, 1.0f, 12.0f}}},
        {{{Eq::kPeak1, Shape::peak, 5000.0f, 4.0f, -18.0f}}},
        {{{Eq::kPeak2, Shape::peak, 15000.0f, 0.5f, 24.0f}}},
        {{{Eq::kPeak2, Shape::peak, 19000.0f, 2.0f, -24.0f}}},
        {{{Eq::kHighShelf, Shape::highShelf, 8000.0f, Eq::kButterworthQ, 9.0f}}},
        {{{Eq::kHighShelf, Shape::highShelf, 3000.0f, 1.5f, -15.0f}}},
        {{{Eq::kHighPass, Shape::highPass, 80.0f, Eq::kButterworthQ, 0.0f}}},
        {{{Eq::kHighPass, Shape::highPass, 2000.0f, 5.0f, 0.0f}}},
        {{{Eq::kLowPass, Shape::lowPass, 10000.0f, Eq::kButterworthQ, 0.0f}}},
        {{{Eq::kLowPass, Shape::lowPass, 20000.0f, 0.7f, 0.0f}}},
        {{{Eq::kHighPass, Shape::highPass, 120.0f, 1.0f, 0.0f},
          {Eq::kLowShelf, Shape::lowShelf, 250.0f, 0.7f, -3.0f},
          {Eq::kPeak1, Shape::peak, 900.0f, 2.0f, 4.5f},
          {Eq::kPeak2, Shape::peak, 4000.0f, 1.2f, -6.0f},
          {Eq::kHighShelf, Shape::highShelf, 9000.0f, 0.9f, 5.0f},
          {Eq::kLowPass, Shape::lowPass, 18000.0f, 0.8f, 0.0f}}},
    };

    uint64_t violations = 0;
    double worst = 0;
    bool anyMeasured = false;
    bool sawNearNyquist = false;
    for (double rate : {44100.0, 48000.0, 88200.0, 96000.0}) {
        const std::vector<double> probes = probesFor(rate);
        const double amp = 0.9 / static_cast<double>(probes.size());
        const auto window = static_cast<size_t>(rate);
        for (const Case& test : cases) {
            std::vector<Biquad> filters;
            for (const BandSetting& s : test.bands)
                filters.push_back(oracle(s.shape, double{s.hz}, double{s.q}, double{s.db}, rate));
            double settle = 2048;
            for (const Biquad& f : filters) settle = std::max(settle, f.settleFrames());
            const auto settleFrames = static_cast<size_t>(settle);
            const size_t total = settleFrames + window;

            // Every probe at once: whole cycles over the window, so they don't leak into each other.
            std::vector<float> input(total, 0.0f);
            for (size_t i = 0; i < total; ++i) {
                double sum = 0;
                for (double hz : probes) sum += std::sin(2 * std::numbers::pi * hz * static_cast<double>(i) / rate);
                input[i] = static_cast<float>(amp * sum);
            }
            EqRig rig(rate);
            for (const BandSetting& s : test.bands) rig.band(s);
            rig.run({input, input}, [] { return 512u; });
            violations += rig.violations;
            DAW_CHECK(rig.left == rig.right);

            for (double hz : probes) {
                Cx analytic = 1;
                for (const Biquad& f : filters) analytic *= f.response(hz, rate);
                const double expected = std::abs(analytic);
                if (expected < 1e-4) continue;  // below −80 dB float input noise dominates; irrelevant
                const Cx measured = projection(rig.left, settleFrames, window, hz, rate);
                const double errorDb = 20.0 * std::log10(std::abs(measured) / amp / expected);
                worst = std::max(worst, std::fabs(errorDb));
                anyMeasured = true;
                if (hz >= std::floor(rate / 2.0) - 30) sawNearNyquist = true;
            }
        }
    }
    DAW_CHECK(anyMeasured && sawNearNyquist);
    DAW_CHECK(worst < 0.1);  // DSP-030 acceptance: within 0.1 dB of the analytic response
    DAW_CHECK(violations == 0);
    return checks;
}

CheckResult eqSweep() {
    CheckResult checks;
    uint64_t violations = 0;
    // A slew bound: a sine of peak P moves by at most P·2·sin(π f/fs) per frame. A click shows as
    // a sample-to-sample jump well above that, so allow a small margin for the amplitude ramp.
    auto maxStep = [](const std::vector<float>& y, size_t from) {
        double m = 0;
        for (size_t i = from + 1; i < y.size(); ++i) m = std::max(m, std::fabs(double{y[i]} - double{y[i - 1]}));
        return m;
    };
    auto peak = [](const std::vector<float>& y, size_t from) {
        double m = 0;
        for (size_t i = from; i < y.size(); ++i) m = std::max(m, std::fabs(double{y[i]}));
        return m;
    };

    const uint32_t blockSizes[] = {32, 64, 512, 4096};
    // Gain sweep on a peak at the tone's frequency: −24 → +24 dB and back, in 1 s.
    for (uint32_t blockSize : blockSizes) {
        const double hz = 1000;
        const size_t total = 48000;
        const auto in = sine(total, hz, 0.25);
        EqRig rig;
        rig.band({Eq::kPeak1, Shape::peak, static_cast<float>(hz), 1.0f, -24.0f});
        size_t pos = 0;
        while (pos < total) {
            const auto n = static_cast<uint32_t>(std::min<size_t>(blockSize, total - pos));
            const double t = static_cast<double>(pos) / static_cast<double>(total);  // 0…1 over the sweep
            const double db = t < 0.5 ? -24.0 + 96.0 * t : 24.0 - 96.0 * (t - 0.5);
            rig.params.set(Eq::kPeak1Gain, static_cast<float>(db));
            rig.process({in, in}, pos, n);
            pos += n;
        }
        const double slew = 2.0 * std::sin(std::numbers::pi * hz / kRate);
        DAW_CHECK(maxStep(rig.left, 4800) <= 1.25 * slew * peak(rig.left, 4800));
        DAW_CHECK(peak(rig.left, 0) <= 0.25 * std::pow(10.0, 24.0 / 20.0) * 1.25);  // no overshoot past the top gain
        violations += rig.violations;
    }
    // Frequency sweep on a peak: 100 Hz → 16 kHz, log, with the tone at 3 kHz, at each block size.
    for (uint32_t blockSize : blockSizes) {
        const double hz = 3000;
        const size_t total = 48000;
        const auto in = sine(total, hz, 0.25);
        EqRig rig;
        rig.band({Eq::kPeak1, Shape::peak, 100.0f, 1.5f, 18.0f});
        size_t pos = 0;
        while (pos < total) {
            const auto n = static_cast<uint32_t>(std::min<size_t>(blockSize, total - pos));
            const double t = static_cast<double>(pos) / static_cast<double>(total);
            rig.params.set(Eq::kPeak1Freq, static_cast<float>(100.0 * std::pow(160.0, t)));
            rig.process({in, in}, pos, n);
            pos += n;
        }
        const double slew = 2.0 * std::sin(std::numbers::pi * hz / kRate);
        DAW_CHECK(maxStep(rig.left, 4800) <= 1.25 * slew * peak(rig.left, 4800));
        DAW_CHECK(std::all_of(rig.left.begin(), rig.left.end(), [](float x) { return std::isfinite(x); }));
        violations += rig.violations;
    }
    // Fast LP sweep (the most exposed band): 20 kHz → 200 Hz in 0.5 s on a 300 Hz tone.
    {
        const double hz = 300;
        const size_t total = 24000;
        const auto in = sine(total, hz, 0.5);
        EqRig rig;
        rig.band({Eq::kLowPass, Shape::lowPass, 20000.0f, 2.0f, 0.0f});
        size_t pos = 0;
        while (pos < total) {
            const uint32_t n = 64;
            const double t = static_cast<double>(pos) / static_cast<double>(total);
            rig.params.set(Eq::kLpFreq, static_cast<float>(20000.0 * std::pow(0.01, t)));
            rig.process({in, in}, pos, n);
            pos += n;
        }
        const double slew = 2.0 * std::sin(std::numbers::pi * hz / kRate);
        DAW_CHECK(maxStep(rig.left, 480) <= 1.25 * slew * peak(rig.left, 480));
        violations += rig.violations;
    }

    // A full-range step in one small block stays finite and bounded, and settles on the response
    // the new coefficients state.
    {
        const double hz = 1000;
        const size_t total = 3 * 48000;
        const auto in = sine(total, hz, 0.25);
        EqRig rig;
        rig.band({Eq::kPeak1, Shape::peak, static_cast<float>(hz), 4.0f, -24.0f});
        size_t pos = 0;
        const size_t step = 24000;
        while (pos < total) {
            if (pos >= step) rig.params.set(Eq::kPeak1Gain, 24.0f);
            rig.process({in, in}, pos, 64);
            pos += 64;
        }
        DAW_CHECK(std::all_of(rig.left.begin(), rig.left.end(), [](float x) { return std::isfinite(x); }));
        DAW_CHECK(peak(rig.left, 0) < 0.25 * std::pow(10.0, 24.0 / 20.0) * 2.0);
        const auto settled = oracle(Shape::peak, hz, 4.0, 24.0, kRate);
        const double want = 0.25 * std::abs(settled.response(hz, kRate));
        const double got = std::abs(projection(rig.left, total - 48000, 48000, hz, kRate));
        DAW_CHECK(std::fabs(20.0 * std::log10(got / want)) < 0.1);
        violations += rig.violations;
    }

    // A band changing gain keeps its state: a −6 → +6 dB change over a block is continuous
    // relative to a band that doesn't change (no state reset), checked as the same slew bound
    // right across the change.
    {
        const size_t total = 9600;
        const double hz = 500;
        const auto in = sine(total, hz, 0.5);
        EqRig rig;
        rig.band({Eq::kPeak1, Shape::peak, 500.0f, 2.0f, -6.0f});
        rig.process({in, in}, 0, 4800);
        rig.params.set(Eq::kPeak1Gain, 6.0f);
        rig.process({in, in}, 4800, 480);
        rig.process({in, in}, 5280, 4320);
        const double slew = 2.0 * std::sin(std::numbers::pi * hz / kRate);
        DAW_CHECK(maxStep(rig.left, 4000) <= 1.25 * slew * peak(rig.left, 4000));
        violations += rig.violations;
    }
    DAW_CHECK(violations == 0);
    return checks;
}

CheckResult eqRobustness() {
    CheckResult checks;
    uint64_t violations = 0;
    const BandSetting active[] = {{Eq::kHighPass, Shape::highPass, 60.0f, 0.9f, 0.0f},
                                  {Eq::kLowShelf, Shape::lowShelf, 200.0f, 0.7f, 5.0f},
                                  {Eq::kPeak1, Shape::peak, 1200.0f, 3.0f, -9.0f},
                                  {Eq::kPeak2, Shape::peak, 6000.0f, 0.8f, 7.0f},
                                  {Eq::kHighShelf, Shape::highShelf, 9000.0f, 1.0f, -4.0f},
                                  {Eq::kLowPass, Shape::lowPass, 16000.0f, 1.0f, 0.0f}};

    // ENG-004: random block sizes (0 … 4096, zeros included) match fixed 512-frame blocks bit for
    // bit with constant params.
    {
        const size_t total = 200000;
        const auto l = noiseBursts(total, 71), r = noiseBursts(total, 72);
        EqRig fixed, fuzzed;
        for (const BandSetting& s : active) {
            fixed.band(s);
            fuzzed.band(s);
        }
        fixed.run({l, r}, [] { return 512u; });
        std::mt19937 rng(5);
        fuzzed.run({l, r}, [&] {
            const uint32_t pick = rng() % 10;
            return pick == 0 ? 0u : pick == 1 ? kMaxBlock : static_cast<uint32_t>(rng() % kMaxBlock);
        });
        DAW_CHECK(fixed.left == fuzzed.left && fixed.right == fuzzed.right);
        DAW_CHECK(fixed.left != l);  // it filters
        violations += fixed.violations + fuzzed.violations;
    }

    // DSP-040: after loud input, silence reaches exact 0 in finite time (no denormals). A high-Q
    // 20 Hz band is the slowest ring the table allows.
    {
        EqRig rig;
        for (const BandSetting& s : active) rig.band(s);
        rig.band({Eq::kPeak2, Shape::peak, 20.0f, 10.0f, 12.0f});
        const auto loud = sine(48000, 441, 1.0);
        rig.run({loud, loud}, [] { return 512u; });
        rig.left.clear();
        rig.right.clear();
        rig.run({constant(12 * 48000, 0.0f), constant(12 * 48000, 0.0f)}, [] { return 512u; });
        DAW_CHECK(rig.left.front() != 0.0f);  // it rang
        const size_t lastSecond = rig.left.size() - 48000;
        DAW_CHECK(std::all_of(rig.left.begin() + static_cast<std::ptrdiff_t>(lastSecond), rig.left.end(),
                              [](float x) { return x == 0.0f; }));
        DAW_CHECK(std::all_of(rig.right.begin() + static_cast<std::ptrdiff_t>(lastSecond), rig.right.end(),
                              [](float x) { return x == 0.0f; }));
        DAW_CHECK(std::all_of(rig.left.begin(), rig.left.end(),
                              [](float x) { return !std::isfinite(x) || std::fpclassify(x) != FP_SUBNORMAL; }));
        violations += rig.violations;
    }
    // Pure silence from the start is exact 0 from the first frame, with every band on.
    {
        EqRig rig;
        for (const BandSetting& s : active) rig.band(s);
        rig.run({constant(4096, 0.0f), constant(4096, 0.0f)}, [] { return 512u; });
        DAW_CHECK(std::all_of(rig.left.begin(), rig.left.end(), [](float x) { return x == 0.0f; }));
        violations += rig.violations;
    }

    // DSP-040: NaN guard. A NaN (or Inf) block outputs silence, is counted, and clears the filter
    // state: the next block equals a fresh EQ's first block.
    for (float bad : {std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity(),
                      -std::numeric_limits<float>::infinity()}) {
        const auto in = sine(2048, 441, 0.9);
        Telemetry telemetry;
        EqRig rig(kRate, Eq::kNumParams, &telemetry), fresh;
        for (const BandSetting& s : active) {
            rig.band(s);
            fresh.band(s);
        }
        rig.process({in, in}, 0, 512);
        auto dirty = in;
        dirty[512 + 17] = bad;
        rig.process({dirty, in}, 512, 512);
        DAW_CHECK(rig.node.nanBlocks() == 1);
        DAW_CHECK(telemetry.snapshot().nanBlocks == 1);
        DAW_CHECK(std::all_of(rig.left.begin() + 512, rig.left.end(), [](float x) { return x == 0.0f; }));
        DAW_CHECK(std::all_of(rig.right.begin() + 512, rig.right.end(), [](float x) { return x == 0.0f; }));
        rig.process({in, in}, 1024, 512);
        fresh.process({in, in}, 1024, 512);
        DAW_CHECK(std::equal(fresh.left.begin(), fresh.left.end(), rig.left.begin() + 1024));
        violations += rig.violations + fresh.violations;
    }

    // Mono input feeds both channels; no input is silence, and the filters ring on.
    {
        const auto in = sine(4096, 441, 0.5);
        EqRig mono, stereo;
        mono.band({Eq::kPeak1, Shape::peak, 441.0f, 1.0f, 6.0f});
        stereo.band({Eq::kPeak1, Shape::peak, 441.0f, 1.0f, 6.0f});
        mono.run({in}, [] { return 512u; });
        stereo.run({in, in}, [] { return 512u; });
        DAW_CHECK(mono.left == stereo.left && mono.right == stereo.left);
        const size_t firstRing = mono.left.size();
        mono.process({}, 0, 512);
        DAW_CHECK(mono.left[firstRing] != 0.0f);  // state rings with no input
        violations += mono.violations + stereo.violations;
    }
    DAW_CHECK(violations == 0);
    return checks;
}

CheckResult eqThroughEngine() {
    CheckResult checks;
    Rig rig;
    const double hz = 441;
    rig.addAsset(makeAsset(1, 1, 48000, [hz](uint32_t, int64_t i) {
        return static_cast<float>(0.25 * std::sin(2 * std::numbers::pi * hz * static_cast<double>(i) / kRate));
    }));
    auto params = rig.engine().params().allocate(Eq::kNumParams, 0.0f);
    DAW_CHECK(params.ok());
    const ParamID first = params.value();
    ParamSlotTable& slots = rig.engine().params();
    for (const ParamInfo& p : Eq::kParamInfo) slots.set(first + p.index, p.def);
    slots.set(first + Eq::kPeak1Freq, 441.0f);
    slots.set(first + Eq::kPeak1Gain, 6.0f);
    slots.set(first + Eq::kPeak1Q, 2.0f);

    // tone player 10 → eq 20 → master 1.
    GraphDescription d = baseDescription();
    d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
    d.nodes.push_back(NodeDesc{20, NodeKind::eq, 1, first, Eq::kNumParams, {}});
    d.edges.push_back(EdgeDesc{1, 10, 20, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{2, 20, 1, EdgeKind::audio, 0});
    d.audioClips.push_back(clip(10, 1, 0, 1920, 1));
    DAW_CHECK(rig.publish(d));
    DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
    rig.renderFrames(48000, [] { return 256u; });
    DAW_CHECK(rig.engine().telemetry().snapshot().graphLatency == 0);  // 0 latency: no PDC
    DAW_CHECK(rig.left() == rig.right());
    if (rig.left().size() == 48000) {
        const auto settled = oracle(Shape::peak, 441.0, 2.0, 6.0, kRate);
        const double want = 0.25 * std::abs(settled.response(441.0, kRate));
        // 441 Hz at 48 kHz: 44100 frames holds 405.1875 cycles; use a whole-cycle window instead.
        const size_t window = 32000;  // 294 whole cycles of 441 Hz at 48 kHz
        double re = 0, im = 0;
        for (size_t i = 0; i < window; ++i) {
            const double w = 2 * std::numbers::pi * 441.0 * static_cast<double>(i) / kRate;
            re += double{rig.left()[48000 - window + i]} * std::sin(w);
            im -= double{rig.left()[48000 - window + i]} * std::cos(w);
        }
        const double got = std::hypot(re, im) * 2.0 / static_cast<double>(window);
        DAW_CHECK(std::fabs(20.0 * std::log10(got / want)) < 0.1);
    }
    DAW_CHECK(rig.violations() == 0);

    // DSP-040, DW-142: NaN from a source node reaches each effect's guard: every effect counts
    // its own silenced blocks in telemetry, and the sum is what the engine reports.
    {
        const TestNodeSpec nanSource{NodeKind::audioClipPlayer, TestNodeType::nan, 0, 0, 0, 0};
        Rig nanRig([&](NodeRegistry& registry) { DAW_CHECK(registerTestNode(registry, nanSource).ok()); });
        auto first2 = nanRig.engine().params().allocate(64, 0.0f);
        DAW_CHECK(first2.ok());
        GraphDescription g = baseDescription();
        g.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
        const NodeKind effects[] = {NodeKind::eq, NodeKind::compressor, NodeKind::delay, NodeKind::reverb};
        ParamID next = first2.value();
        for (uint32_t k = 0; k < 4; ++k) {
            const NodeID id = 20 + k;
            g.nodes.push_back(NodeDesc{id, effects[k], 1, next, 0, {}});
            next += 16;
            g.edges.push_back(EdgeDesc{1 + 2 * k, 10, id, EdgeKind::audio, 0});
            g.edges.push_back(EdgeDesc{2 + 2 * k, id, 1, EdgeKind::audio, 0});
        }
        DAW_CHECK(nanRig.publish(g));
        DAW_CHECK(nanRig.transport().locate(0) && nanRig.transport().play());
        nanRig.renderFrames(2560, [] { return 256u; });
        DAW_CHECK(nanRig.engine().telemetry().snapshot().nanBlocks == 4 * 10);  // 4 effects, 10 blocks
        bool silent = true;
        for (float x : nanRig.left()) silent = silent && x == 0.0f;  // the master gets the guards' silence
        DAW_CHECK(silent);
        DAW_CHECK(nanRig.violations() == 0);
    }

    // The counter crosses the facade (TelemetryPOD, engine.telemetry).
    {
        const TestNodeSpec nanSource{NodeKind::audioClipPlayer, TestNodeType::nan, 0, 0, 0, 0};
        EngineFacade* facade = makeTestFacade(kRate, {nanSource});
        DAW_CHECK(facade != nullptr);
        if (facade) {
            GraphDescription g = baseDescription();
            g.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
            g.nodes.push_back(NodeDesc{20, NodeKind::eq, 1, 0, 0, {}});
            g.edges.push_back(EdgeDesc{1, 10, 20, EdgeKind::audio, 0});
            g.edges.push_back(EdgeDesc{2, 20, 1, EdgeKind::audio, 0});
            const uint64_t version = facade->applyGraph(g);
            const GraphStatusPOD status = facade->waitForGraph(version, 5000);
            DAW_CHECK(status.publishedVersion == version);
            const std::filesystem::path path = std::filesystem::temp_directory_path() /
                                               ("eq-nan-" + std::to_string(getpid()) + ".wav");
            ExportSpecPOD spec;
            spec.path = path.string();
            spec.tailEnabled = false;
            spec.blockSize = 512;
            const JobID job = facade->renderOffline(0, 960, spec);
            DAW_CHECK(job != 0);
            JobStatus render;
            for (int i = 0; i < 2000; ++i) {
                render = facade->pollJob(job);
                if (render.state == JobState::succeeded || render.state == JobState::failed) break;
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
            DAW_CHECK(render.state == JobState::succeeded);
            DAW_CHECK(facade->telemetry().nanBlocks > 0);
            std::error_code ignored;
            std::filesystem::remove(path, ignored);
            releaseFacade(facade);
        }
    }
    return checks;
}

} // namespace daw::testing
