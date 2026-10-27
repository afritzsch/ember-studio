// T-013 checks for the ChannelStrip. Run from Tests/DAWEngineTests/ChannelStripTests.swift; see
// ChannelStripChecks.h for why they're C++.

#include "ChannelStripChecks.h"

#include <cmath>
#include <cstdint>
#include <numbers>
#include <random>
#include <vector>

#include "NodeTestHarness.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/ProcessContext.h"
#include "core/RtTrap.h"
#include "core/Telemetry.h"
#include "dsp/MeterWindow.h"
#include "dsp/PanLaw.h"
#include "nodes/ChannelStrip.h"
#include "time/TempoMap.h"

using namespace daw;
using namespace daw::testing::nodes;

namespace daw::testing {

namespace {

constexpr float kHalfSqrt2 = static_cast<float>(std::numbers::sqrt2 / 2);

bool near(double a, double b, double tol = 1e-6) { return std::fabs(a - b) <= tol; }

// One strip with its own param slots, driven block by block with a given input.
struct StripRig {
    explicit StripRig(MeterTarget meter = {}) : params(16), strip(0, meter) {
        // No Engine here to install the trap (ENG-030); without it the scope would count nothing.
        trapInstalled = RtTrap::install();
        (void)params.allocate(ChannelStrip::kNumParams, 0.0f);
        strip.prepare(PrepareInfo{kRate, kMaxBlock, 2, 2});
    }

    void set(float gain, float pan) {
        params.set(ChannelStrip::kGain, gain);
        params.set(ChannelStrip::kPan, pan);
    }

    // Processes one block of `in` (both channels: inL, inR) into outL/outR.
    void process(const std::vector<float>& inL, const std::vector<float>& inR) {
        const auto n = static_cast<uint32_t>(inL.size());
        inBufL = inL;
        inBufR = inR;
        outL.assign(n, -99.0f);
        outR.assign(n, -99.0f);
        float* in[2] = {inBufL.data(), inBufR.data()};
        float* out[2] = {outL.data(), outR.data()};
        NodeIO io;
        io.audioIn = AudioBufferView{in, 2, n};
        io.audioOut = AudioBufferView{out, 2, n};
        TransportBlock block{false, false, 0, {}, &tempo};
        ProcessContext ctx{n, kRate, block, params};
        RtScope scope;
        strip.process(ctx, io);
        violations += scope.violations();
    }
    void process(uint32_t n, float value) { process(std::vector<float>(n, value), std::vector<float>(n, value)); }

    ParamSlotTable params;
    ChannelStrip strip;
    TempoMap tempo;
    std::vector<float> inBufL, inBufR, outL, outR;
    uint64_t violations = 0;
    bool trapInstalled = false;
};

bool all(const std::vector<float>& v, float value, double tol = 0.0) {
    for (float x : v)
        if (!near(x, value, tol)) return false;
    return true;
}

} // namespace

CheckResult channelStripPanLaw() {
    CheckResult checks;

    // The law itself.
    DAW_CHECK(constantPowerPan(-1.0f).left == 1.0f && constantPowerPan(-1.0f).right == 0.0f);
    DAW_CHECK(constantPowerPan(0.0f).left == kHalfSqrt2 && constantPowerPan(0.0f).right == kHalfSqrt2);
    DAW_CHECK(constantPowerPan(1.0f).left == 0.0f && constantPowerPan(1.0f).right == 1.0f);
    DAW_CHECK(near(20.0 * std::log10(constantPowerPan(0.0f).left), -3.0103, 1e-4));
    std::mt19937 rng(5);
    std::uniform_real_distribution<float> pans(-1.0f, 1.0f);
    bool power = true, monotonic = true;
    for (int i = 0; i < 1000; ++i) {
        const float p = pans(rng);
        const PanGains g = constantPowerPan(p);
        power = power && near(double(g.left) * g.left + double(g.right) * g.right, 1.0, 1e-6);
        const PanGains h = constantPowerPan(std::min(1.0f, p + 0.01f));
        monotonic = monotonic && h.left <= g.left && h.right >= g.right;
    }
    DAW_CHECK(power && monotonic);
    DAW_CHECK(constantPowerPan(-7.0f).left == 1.0f && constantPowerPan(3.0f).right == 1.0f);
    DAW_CHECK(constantPowerPan(std::nanf("")).left == 1.0f);  // NaN clamps rather than spreads

    // Through the strip, with a fresh strip per setting so no block ramps.
    struct Case { float gain, pan, left, right; };
    const Case cases[] = {
        {1.0f, -1.0f, 1.0f, 0.0f},
        {1.0f, 0.0f, kHalfSqrt2, kHalfSqrt2},
        {1.0f, 1.0f, 0.0f, 1.0f},
        {2.0f, 0.0f, 2.0f * kHalfSqrt2, 2.0f * kHalfSqrt2},
        {0.0f, 0.0f, 0.0f, 0.0f},
        {100.0f, -1.0f, ChannelStrip::kMaxGain, 0.0f},  // clamped to +12 dB
        {-1.0f, -1.0f, 0.0f, 0.0f},                     // clamped to −∞ dB
    };
    for (const Case& c : cases) {
        StripRig rig;
        rig.set(c.gain, c.pan);
        rig.process(256, 1.0f);
        DAW_CHECK(all(rig.outL, c.left, 1e-7) && all(rig.outR, c.right, 1e-7));
        rig.process(300, 1.0f);  // steady: same values
        DAW_CHECK(all(rig.outL, c.left, 1e-7) && all(rig.outR, c.right, 1e-7));
        DAW_CHECK(rig.violations == 0);
        DAW_CHECK(rig.trapInstalled || !DAW_RT_TRAP);
    }
    DAW_CHECK(near(20.0 * std::log10(ChannelStrip::kMaxGain), 12.0, 1e-5));

    // Each gain scales its own channel (stereo throughout, MIX-004).
    StripRig rig;
    rig.set(1.0f, 0.5f);
    rig.process(std::vector<float>(64, 0.25f), std::vector<float>(64, -0.5f));
    const PanGains g = constantPowerPan(0.5f);
    DAW_CHECK(all(rig.outL, 0.25f * g.left, 1e-7) && all(rig.outR, -0.5f * g.right, 1e-7));
    DAW_CHECK(rig.violations == 0);
    return checks;
}

CheckResult channelStripSmoothing() {
    CheckResult checks;
    StripRig rig;
    rig.set(1.0f, -1.0f);
    rig.process(128, 1.0f);  // first block: no ramp up from 0
    DAW_CHECK(all(rig.outL, 1.0f) && all(rig.outR, 0.0f));

    // Gain 1 → 0.5 over one 100-frame block: out[i] = 1 + (0.5 − 1)(i + 1)/100, last exact.
    rig.set(0.5f, -1.0f);
    rig.process(100, 1.0f);
    bool ramp = true;
    for (uint32_t i = 0; i < 100; ++i) ramp = ramp && near(rig.outL[i], 1.0 - 0.5 * (i + 1) / 100.0, 1e-6);
    DAW_CHECK(ramp && rig.outL[99] == 0.5f && all(rig.outR, 0.0f));
    rig.process(50, 1.0f);  // settled
    DAW_CHECK(all(rig.outL, 0.5f));

    // A 0-frame block (ENG-004) changes nothing; the next real block does the ramp.
    rig.set(1.0f, 1.0f);
    rig.process(0, 1.0f);
    rig.process(64, 1.0f);
    // Left goes 0.5·1 → 1·0, right 0.5·0 → 1·1, both linear across the block.
    bool both = true;
    for (uint32_t i = 0; i < 64; ++i) {
        both = both && near(rig.outL[i], 0.5 - 0.5 * (i + 1) / 64.0, 1e-6);
        both = both && near(rig.outR[i], 1.0 * (i + 1) / 64.0, 1e-6);
    }
    DAW_CHECK(both && rig.outL[63] == 0.0f && rig.outR[63] == 1.0f);

    // Continuity: random slot changes every block never jump by more than the per-block ramp.
    std::mt19937 rng(9);
    std::uniform_real_distribution<float> gains(0.0f, 2.0f), pans(-1.0f, 1.0f);
    std::uniform_int_distribution<uint32_t> sizes(1, 512);
    float lastL = rig.outL.back(), lastR = rig.outR.back();
    bool continuous = true;
    for (int b = 0; b < 200; ++b) {
        rig.set(gains(rng), pans(rng));
        const uint32_t n = sizes(rng);
        rig.process(n, 1.0f);
        // The first frame is one ramp step from the previous block's last frame.
        const double maxStep = 2.0 / n + 1e-6;
        continuous = continuous && std::fabs(rig.outL[0] - lastL) <= maxStep && std::fabs(rig.outR[0] - lastR) <= maxStep;
        lastL = rig.outL.back();
        lastR = rig.outR.back();
    }
    DAW_CHECK(continuous);
    DAW_CHECK(rig.violations == 0);
    return checks;
}

CheckResult channelStripMeter() {
    CheckResult checks;
    // The window on its own.
    {
        MeterWindow w;
        w.prepare(kRate);
        DAW_CHECK(w.chunkFrames() == 48);
        DAW_CHECK(w.reading().peak == 0.0f && w.reading().rms == 0.0f);
        // A full window of a 0.5-amplitude 1 kHz sine: peak 0.5, RMS 0.5/√2.
        std::vector<float> sine(14400);
        for (size_t i = 0; i < sine.size(); ++i)
            sine[i] = 0.5f * std::sin(2.0 * std::numbers::pi * 1000.0 * double(i) / kRate);
        w.add(sine.data(), sine.data(), uint32_t(sine.size()));
        DAW_CHECK(near(w.reading().peak, 0.5, 1e-4));
        DAW_CHECK(near(w.reading().rms, 0.5 / std::numbers::sqrt2, 1e-4));
        // 150 ms of silence: half the window's energy is left, RMS falls by √2.
        std::vector<float> silence(7200, 0.0f);
        w.add(silence.data(), silence.data(), uint32_t(silence.size()));
        DAW_CHECK(near(w.reading().rms, 0.5 / 2.0, 1e-3));
        DAW_CHECK(near(w.reading().peak, 0.5, 1e-4));  // still inside the window
        // Another 151 ms: everything loud has left the window.
        std::vector<float> more(7248, 0.0f);
        w.add(more.data(), more.data(), uint32_t(more.size()));
        DAW_CHECK(w.reading().peak == 0.0f && w.reading().rms == 0.0f);
        // L and R meter as one signal: mean square (L² + R²)/2.
        w.reset();
        std::vector<float> l(14400, 1.0f), r(14400, 0.0f);
        w.add(l.data(), r.data(), uint32_t(l.size()));
        DAW_CHECK(w.reading().peak == 1.0f && near(w.reading().rms, std::sqrt(0.5), 1e-6));
    }

    // Through the strip: post-fader, written to its MeterID every block.
    Telemetry telemetry;
    StripRig rig(MeterTarget{&telemetry, 42});
    rig.set(2.0f, -1.0f);  // left only, ×2
    for (int b = 0; b < 60; ++b) rig.process(256, 0.25f);  // 320 ms
    const MeterReading m = telemetry.meter(42);
    DAW_CHECK(near(m.peak, 0.5, 1e-6));
    DAW_CHECK(near(m.rms, 0.5 / std::numbers::sqrt2, 1e-5));  // (0.5² + 0²)/2
    DAW_CHECK(telemetry.meter(41).peak == 0.0f);
    DAW_CHECK(rig.violations == 0);
    return checks;
}

CheckResult channelStripThroughEngine() {
    CheckResult checks;
    Rig rig;
    rig.addAsset(makeAsset(1, 1, 100000, [](uint32_t, int64_t) { return 1.0f; }));
    auto params = rig.engine().params().allocate(ChannelStrip::kNumParams, 0.0f);
    DAW_CHECK(params.ok());
    const ParamID first = params.value();
    rig.engine().params().set(first + ChannelStrip::kGain, 1.0f);
    rig.engine().params().set(first + ChannelStrip::kPan, 0.0f);

    // player 10 → strip 20 → master 1.
    GraphDescription d = baseDescription();
    d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
    d.nodes.push_back(NodeDesc{20, NodeKind::channelStrip, 1, first, ChannelStrip::kNumParams, {}});
    d.edges.push_back(EdgeDesc{1, 10, 20, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{2, 20, 1, EdgeKind::audio, 0});
    d.audioClips.push_back(clip(10, 1, 0, 3000, 1));

    // A strip with too few params is rejected at build time.
    GraphDescription bad = d;
    bad.nodes[2].numParams = 1;
    DAW_CHECK(!rig.build(bad).ok());

    DAW_CHECK(rig.publish(d));
    DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
    rig.renderFrames(512, [] { return 256u; });
    // Mono clip duplicated to L/R, panned centre: −3 dB per side.
    DAW_CHECK(all(rig.left(), kHalfSqrt2, 1e-7) && all(rig.right(), kHalfSqrt2, 1e-7));

    // Slot writes reach the strip without a rebuild (D-09), ramped over one block.
    rig.engine().params().set(first + ChannelStrip::kPan, 1.0f);
    rig.clearOutput();
    rig.renderFrames(512, [] { return 256u; });
    DAW_CHECK(near(rig.left()[255], 0.0, 1e-7) && near(rig.right()[255], 1.0, 1e-7));
    DAW_CHECK(rig.left()[0] > 0.6f && rig.left()[0] < kHalfSqrt2);  // ramping, not jumping
    bool settled = true;
    for (size_t i = 256; i < 512; ++i) settled = settled && rig.left()[i] == 0.0f && rig.right()[i] == 1.0f;
    DAW_CHECK(settled);
    DAW_CHECK(rig.violations() == 0);
    return checks;
}

} // namespace daw::testing
