// T-020 checks for sends (MIX-007). Run from Tests/DAWEngineTests/SendTests.swift; see
// SendChecks.h for why they're C++.

#include "SendChecks.h"

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
#include "nodes/ChannelStrip.h"
#include "nodes/GainNode.h"
#include "time/TempoMap.h"

using namespace daw;
using namespace daw::testing::nodes;

namespace daw::testing {

namespace {

constexpr float kHalfSqrt2 = static_cast<float>(std::numbers::sqrt2 / 2);

bool near(double a, double b, double tol = 1e-6) { return std::fabs(a - b) <= tol; }

bool all(const std::vector<float>& v, size_t from, size_t to, double value, double tol = 1e-6) {
    for (size_t i = from; i < to; ++i)
        if (!near(v[i], value, tol)) return false;
    return true;
}

// One GainNode with its own slot, driven block by block with a constant stereo input.
struct GainRig {
    GainRig() : params(4), node(0) {
        trapInstalled = RtTrap::install();  // no Engine here to install it (ENG-030)
        (void)params.allocate(GainNode::kNumParams, 0.0f);
        node.prepare(PrepareInfo{kRate, kMaxBlock, 2, 2});
    }

    void process(uint32_t n, float inL, float inR) {
        inBufL.assign(n, inL);
        inBufR.assign(n, inR);
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
        node.process(ctx, io);
        violations += scope.violations();
    }

    ParamSlotTable params;
    GainNode node;
    TempoMap tempo;
    std::vector<float> inBufL, inBufR, outL, outR;
    uint64_t violations = 0;
    bool trapInstalled = false;
};

} // namespace

CheckResult gainNodeLevel() {
    CheckResult checks;
    DAW_CHECK(GainNode::kNumParams == 1 && GainNode::kParamInfo[0].index == GainNode::kLevel);
    DAW_CHECK(GainNode::kMaxLevel == ChannelStrip::kMaxGain);

    GainRig rig;
    rig.params.set(GainNode::kLevel, 0.5f);
    rig.process(64, 1.0f, -0.5f);  // first block: no ramp up from 0
    DAW_CHECK(all(rig.outL, 0, 64, 0.5) && all(rig.outR, 0, 64, -0.25));

    // 0.5 → 2 over one 100-frame block, linear, last frame exact; both channels.
    rig.params.set(GainNode::kLevel, 2.0f);
    rig.process(100, 1.0f, -0.5f);
    bool ramp = true;
    for (uint32_t i = 0; i < 100; ++i) {
        const double v = 0.5 + 1.5 * (i + 1) / 100.0;
        ramp = ramp && near(rig.outL[i], v) && near(rig.outR[i], -0.5 * v);
    }
    DAW_CHECK(ramp && rig.outL[99] == 2.0f);

    // A 0-frame block (ENG-004) changes nothing; the next real block ramps.
    rig.params.set(GainNode::kLevel, 1.0f);
    rig.process(0, 1.0f, 1.0f);
    rig.process(10, 1.0f, 1.0f);
    DAW_CHECK(near(rig.outL[0], 1.9) && rig.outL[9] == 1.0f);

    // Clamped to 0 … +12 dB; NaN is silence.
    struct Case { float slot, level; };
    for (const Case c : {Case{100.0f, GainNode::kMaxLevel}, Case{-1.0f, 0.0f}, Case{std::nanf(""), 0.0f}}) {
        GainRig fresh;
        fresh.params.set(GainNode::kLevel, c.slot);
        fresh.process(32, 1.0f, 1.0f);
        DAW_CHECK(all(fresh.outL, 0, 32, c.level, 0.0) && all(fresh.outR, 0, 32, c.level, 0.0));
        DAW_CHECK(fresh.violations == 0);
    }

    // Block-size fuzz 0 … 4096 with a new level each block: continuous across blocks.
    std::mt19937 rng(7);
    std::uniform_real_distribution<float> levels(0.0f, 2.0f);
    std::uniform_int_distribution<uint32_t> sizes(0, kMaxBlock);
    float last = rig.outL.back();
    bool continuous = true;
    for (int b = 0; b < 200; ++b) {
        rig.params.set(GainNode::kLevel, levels(rng));
        const uint32_t n = sizes(rng);
        rig.process(n, 1.0f, 1.0f);
        if (n == 0) continue;
        continuous = continuous && std::fabs(rig.outL[0] - last) <= 2.0 / n + 1e-6;
        last = rig.outL.back();
    }
    DAW_CHECK(continuous);
    DAW_CHECK(rig.violations == 0);
    DAW_CHECK(rig.trapInstalled || !DAW_RT_TRAP);
    return checks;
}

CheckResult sendsPreAndPostFader() {
    CheckResult checks;
    Rig rig;
    rig.addAsset(makeAsset(1, 1, 1'000'000, [](uint32_t, int64_t) { return 1.0f; }));
    ParamSlotTable& params = rig.engine().params();
    auto strip = params.allocate(ChannelStrip::kNumParams, 0.0f);
    auto insert = params.allocate(1, 0.5f);
    auto post = params.allocate(1, 0.5f);
    auto pre = params.allocate(1, 0.25f);
    DAW_CHECK(strip.ok() && insert.ok() && post.ok() && pre.ok());
    const ParamID gain = strip.value() + ChannelStrip::kGain, pan = strip.value() + ChannelStrip::kPan;
    const ParamID mute = strip.value() + ChannelStrip::kMute, phase = strip.value() + ChannelStrip::kPhase;
    params.set(gain, 1.0f);

    // player 10 → insert 11 → strip 20 → master 1
    //                 │          └→ post send 30 ┐
    //                 └→ pre send 31 ──────────→ bus 40 → master 1
    GraphDescription d = baseDescription();
    d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
    d.nodes.push_back(NodeDesc{11, NodeKind::gain, 1, insert.value(), 1, {}});
    d.nodes.push_back(NodeDesc{20, NodeKind::channelStrip, 1, strip.value(), ChannelStrip::kNumParams, {}});
    d.nodes.push_back(NodeDesc{30, NodeKind::gain, 1, post.value(), 1, {}});
    d.nodes.push_back(NodeDesc{31, NodeKind::gain, 1, pre.value(), 1, {}});
    d.nodes.push_back(NodeDesc{40, NodeKind::bus, 1, 0, 0, {}});
    d.edges.push_back(EdgeDesc{1, 10, 11, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{2, 11, 20, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{3, 20, 1, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{4, 20, 30, EdgeKind::audio, 0});  // post-fader tap: the strip's output
    d.edges.push_back(EdgeDesc{5, 30, 40, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{6, 11, 31, EdgeKind::audio, 0});  // pre-fader tap: what feeds the strip
    d.edges.push_back(EdgeDesc{7, 31, 40, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{8, 40, 1, EdgeKind::audio, 0});
    d.audioClips.push_back(clip(10, 1, 0, 30000, 1));

    // A gain node needs its level slot.
    GraphDescription bad = d;
    bad.nodes[4].numParams = 0;
    DAW_CHECK(!rig.build(bad).ok());

    DAW_CHECK(rig.publish(d));
    DAW_CHECK(rig.transport().locate(0) && rig.transport().play());

    // Renders two 256-frame blocks; the first carries the ramp to any slot change made before it.
    auto twoBlocks = [&] {
        rig.clearOutput();
        rig.renderFrames(512, [] { return 256u; });
    };
    // The insert passes 0.5, the strip (gain g, centre pan) 0.5·g·√½ per side.
    const double h = kHalfSqrt2;
    twoBlocks();
    // master = strip 0.5h + post 0.5·0.5h + pre 0.25·0.5
    const double base = 0.75 * h + 0.125;
    DAW_CHECK(all(rig.left(), 0, 512, base) && all(rig.right(), 0, 512, base));

    // Everything below is slot writes: no publish, no rebuild (D-09, ENG-023).
    // Fader down: the post-fader send follows it, the pre-fader send doesn't.
    params.set(gain, 0.0f);
    twoBlocks();
    bool ramp = true;
    for (uint32_t i = 0; i < 256; ++i) ramp = ramp && near(rig.left()[i], 0.125 + 0.75 * h * (1.0 - (i + 1) / 256.0));
    DAW_CHECK(ramp);
    DAW_CHECK(all(rig.left(), 255, 512, 0.125) && all(rig.right(), 255, 512, 0.125));

    // Mute (the slot the model writes, solo included, MIX-006): the same, ramped over one block.
    // MIX-007: the pre-fader send ignores the strip's mute.
    params.set(gain, 1.0f);
    twoBlocks();
    DAW_CHECK(all(rig.left(), 256, 512, base));
    params.set(mute, 1.0f);
    twoBlocks();
    ramp = true;
    for (uint32_t i = 0; i < 256; ++i) ramp = ramp && near(rig.left()[i], 0.125 + 0.75 * h * (1.0 - (i + 1) / 256.0));
    DAW_CHECK(ramp);
    DAW_CHECK(all(rig.left(), 255, 512, 0.125) && all(rig.right(), 255, 512, 0.125));
    params.set(mute, 0.0f);
    twoBlocks();
    DAW_CHECK(all(rig.left(), 256, 512, base));

    // Phase invert: post-fader inverted with the strip, pre-fader not.
    params.set(phase, 1.0f);
    twoBlocks();
    DAW_CHECK(all(rig.left(), 256, 512, -0.75 * h + 0.125) && all(rig.right(), 256, 512, -0.75 * h + 0.125));
    params.set(phase, 0.0f);

    // Pan hard left: the post-fader send is post-pan too.
    params.set(pan, -1.0f);
    twoBlocks();
    DAW_CHECK(all(rig.left(), 256, 512, 0.5 + 0.25 + 0.125) && all(rig.right(), 256, 512, 0.125));
    params.set(pan, 0.0f);

    // Send levels: each send's slot scales only its own path.
    params.set(pre.value(), 0.0f);
    twoBlocks();
    DAW_CHECK(all(rig.left(), 256, 512, 0.75 * h));
    params.set(post.value(), 2.0f);
    twoBlocks();
    ramp = true;  // the post send ramps 0.5 → 2 across the block
    for (uint32_t i = 0; i < 256; ++i) ramp = ramp && near(rig.left()[i], 0.5 * h + 0.5 * h * (0.5 + 1.5 * (i + 1) / 256.0));
    DAW_CHECK(ramp && all(rig.left(), 256, 512, 1.5 * h));

    // Pre-fader send alone with the strip muted and its fader down: a cue/monitor send.
    params.set(pre.value(), 1.0f);
    params.set(mute, 1.0f);
    params.set(gain, 0.0f);
    twoBlocks();
    DAW_CHECK(all(rig.left(), 256, 512, 0.5) && all(rig.right(), 256, 512, 0.5));

    DAW_CHECK(rig.violations() == 0);
    return checks;
}

} // namespace daw::testing
