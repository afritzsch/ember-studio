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
    explicit GainRig(uint32_t numParams = GainNode::kNumParams) : params(4), node(0, numParams) {
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
    DAW_CHECK(GainNode::kNumParams == 2 && GainNode::kMinNumParams == 1);
    DAW_CHECK(GainNode::kParamInfo[0].index == GainNode::kLevel && GainNode::kParamInfo[1].index == GainNode::kMute);
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

    // Mute (slot 1): fades out over one block, last frame exactly 0; ≥ 0.5 is on, NaN off.
    rig.params.set(GainNode::kMute, 1.0f);
    rig.process(100, 1.0f, -0.5f);
    bool fade = true;
    for (uint32_t i = 0; i < 100; ++i) {
        const double v = 1.0 - (i + 1) / 100.0;
        fade = fade && near(rig.outL[i], v) && near(rig.outR[i], -0.5 * v);
    }
    DAW_CHECK(fade && rig.outL[99] == 0.0f && rig.outR[99] == 0.0f);
    rig.params.set(GainNode::kLevel, 2.0f);  // the level moves while muted …
    rig.process(64, 1.0f, 1.0f);
    DAW_CHECK(all(rig.outL, 0, 64, 0.0, 0.0));
    rig.params.set(GainNode::kMute, 0.49f);  // … and unmuting fades in to the new level
    rig.process(100, 1.0f, 1.0f);
    bool fadeIn = true;
    for (uint32_t i = 0; i < 100; ++i) fadeIn = fadeIn && near(rig.outL[i], 2.0 * (i + 1) / 100.0);
    DAW_CHECK(fadeIn && rig.outL[99] == 2.0f);
    rig.params.set(GainNode::kMute, std::nanf(""));
    rig.process(16, 1.0f, 1.0f);
    DAW_CHECK(all(rig.outL, 0, 16, 2.0, 0.0));
    rig.params.set(GainNode::kMute, 0.0f);
    rig.params.set(GainNode::kLevel, 1.0f);
    rig.process(16, 1.0f, 1.0f);

    // A plain gain (numParams 1) has no mute slot: whatever follows its level is never read.
    {
        GainRig plain(GainNode::kMinNumParams);
        plain.params.set(GainNode::kLevel, 0.5f);
        plain.params.set(GainNode::kMute, 1.0f);
        plain.process(32, 1.0f, 1.0f);
        plain.process(32, 1.0f, 1.0f);
        DAW_CHECK(all(plain.outL, 0, 32, 0.5, 0.0) && all(plain.outR, 0, 32, 0.5, 0.0));
        DAW_CHECK(plain.violations == 0);
    }

    // Block-size fuzz 0 … 4096 with a new level and mute each block: continuous across blocks.
    std::mt19937 rng(7);
    std::uniform_real_distribution<float> levels(0.0f, 2.0f);
    std::uniform_int_distribution<uint32_t> sizes(0, kMaxBlock);
    float last = rig.outL.back();
    bool continuous = true;
    for (int b = 0; b < 200; ++b) {
        rig.params.set(GainNode::kLevel, levels(rng));
        rig.params.set(GainNode::kMute, b % 3 == 0 ? 1.0f : 0.0f);
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

namespace {

// player 10 → insert 11 (plain gain) → strip 20 → master 1
//                 │                      └→ post send 30 ┐
//                 └→ pre send 31 ──────────────────────→ bus 40 → master 1
// A mono DC 1.0 clip; insert 0.5, strip gain 1 centre, post send 0.5, pre send 0.25. Each send
// has level + mute (GainNode::kNumParams); the insert has only a level.
struct SendRig {
    SendRig() {
        rig.addAsset(makeAsset(1, 1, 1'000'000, [](uint32_t, int64_t) { return 1.0f; }));
        ParamSlotTable& params = rig.engine().params();
        auto s = params.allocate(ChannelStrip::kNumParams, 0.0f);
        auto i = params.allocate(GainNode::kMinNumParams, 0.5f);
        // The post send's level (0.5) sits right after the insert's: an insert that read a mute
        // slot it doesn't have would see 0.5 and mute itself.
        auto po = params.allocate(GainNode::kNumParams, 0.0f);
        auto pr = params.allocate(GainNode::kNumParams, 0.0f);
        ok = s.ok() && i.ok() && po.ok() && pr.ok();
        if (!ok) return;
        strip = s.value();
        insert = i.value();
        post = po.value();
        pre = pr.value();
        params.set(strip + ChannelStrip::kGain, 1.0f);
        params.set(post + GainNode::kLevel, 0.5f);
        params.set(pre + GainNode::kLevel, 0.25f);

        d = baseDescription();
        d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
        d.nodes.push_back(NodeDesc{11, NodeKind::gain, 1, insert, GainNode::kMinNumParams, {}});
        d.nodes.push_back(NodeDesc{20, NodeKind::channelStrip, 1, strip, ChannelStrip::kNumParams, {}});
        d.nodes.push_back(NodeDesc{30, NodeKind::gain, 1, post, GainNode::kNumParams, {}});
        d.nodes.push_back(NodeDesc{31, NodeKind::gain, 1, pre, GainNode::kNumParams, {}});
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
    }

    bool start() { return ok && rig.publish(d) && rig.transport().locate(0) && rig.transport().play(); }

    void set(ParamID id, float value) { rig.engine().params().set(id, value); }
    // What T-016 does for a track's resolved mute (MIX-006, MIX-007): the strip's slot and every
    // send's.
    void muteTrack(bool muted) {
        const float v = muted ? 1.0f : 0.0f;
        set(strip + ChannelStrip::kMute, v);
        set(post + GainNode::kMute, v);
        set(pre + GainNode::kMute, v);
    }

    // Renders two 256-frame blocks; the first carries the ramp to any slot change made before it.
    void twoBlocks() {
        rig.clearOutput();
        rig.renderFrames(512, [] { return 256u; });
    }

    Rig rig;
    bool ok = false;
    ParamID strip = 0, insert = 0, post = 0, pre = 0;
    GraphDescription d;
};

// The insert passes 0.5, the strip 0.5·g·√½ per side (gain g, centre pan).
constexpr double kH = kHalfSqrt2;
// master = strip 0.5h + post 0.5·0.5h + pre 0.25·0.5
constexpr double kBase = 0.75 * kH + 0.125;

// out[0 … 256) is the linear one-block ramp from `from` to `to`.
bool rampsOverFirstBlock(const std::vector<float>& out, double from, double to) {
    bool ramp = true;
    for (uint32_t i = 0; i < 256; ++i) ramp = ramp && near(out[i], from + (to - from) * (i + 1) / 256.0);
    return ramp;
}

} // namespace

CheckResult sendsPreAndPostFader() {
    CheckResult checks;
    SendRig s;
    Rig& rig = s.rig;

    // A gain node needs at least its level slot.
    GraphDescription bad = s.d;
    bad.nodes[4].numParams = 0;
    DAW_CHECK(!rig.build(bad).ok());

    DAW_CHECK(s.start());
    s.twoBlocks();
    DAW_CHECK(all(rig.left(), 0, 512, kBase) && all(rig.right(), 0, 512, kBase));

    // Everything below is slot writes: no publish, no rebuild (D-09, ENG-023).
    // Fader down: the post-fader send follows it, the pre-fader send doesn't.
    s.set(s.strip + ChannelStrip::kGain, 0.0f);
    s.twoBlocks();
    DAW_CHECK(rampsOverFirstBlock(rig.left(), kBase, 0.125));
    DAW_CHECK(all(rig.left(), 255, 512, 0.125) && all(rig.right(), 255, 512, 0.125));
    s.set(s.strip + ChannelStrip::kGain, 1.0f);
    s.twoBlocks();
    DAW_CHECK(all(rig.left(), 256, 512, kBase));

    // Phase invert: post-fader inverted with the strip, pre-fader not.
    s.set(s.strip + ChannelStrip::kPhase, 1.0f);
    s.twoBlocks();
    DAW_CHECK(all(rig.left(), 256, 512, -0.75 * kH + 0.125) && all(rig.right(), 256, 512, -0.75 * kH + 0.125));
    s.set(s.strip + ChannelStrip::kPhase, 0.0f);

    // Pan hard left: the post-fader send is post-pan too.
    s.set(s.strip + ChannelStrip::kPan, -1.0f);
    s.twoBlocks();
    DAW_CHECK(all(rig.left(), 256, 512, 0.5 + 0.25 + 0.125) && all(rig.right(), 256, 512, 0.125));
    s.set(s.strip + ChannelStrip::kPan, 0.0f);

    // Send levels: each send's slot scales only its own path.
    s.set(s.pre + GainNode::kLevel, 0.0f);
    s.twoBlocks();
    DAW_CHECK(all(rig.left(), 256, 512, 0.75 * kH));
    s.set(s.post + GainNode::kLevel, 2.0f);
    s.twoBlocks();
    // The post send ramps 0.5 → 2 across the block.
    DAW_CHECK(rampsOverFirstBlock(rig.left(), 0.75 * kH, 1.5 * kH) && all(rig.left(), 256, 512, 1.5 * kH));

    // Fader down, pre-fader send alone: a cue/monitor send.
    s.set(s.pre + GainNode::kLevel, 1.0f);
    s.set(s.strip + ChannelStrip::kGain, 0.0f);
    s.twoBlocks();
    DAW_CHECK(all(rig.left(), 256, 512, 0.5) && all(rig.right(), 256, 512, 0.5));

    DAW_CHECK(rig.violations() == 0);
    return checks;
}

CheckResult sendsMutedWithTrack() {
    CheckResult checks;
    SendRig s;
    Rig& rig = s.rig;
    DAW_CHECK(s.start());
    s.twoBlocks();
    DAW_CHECK(all(rig.left(), 0, 512, kBase));

    // The strip's mute slot alone silences the strip and so its post-fader send, but not the
    // pre-fader send, which taps upstream: that's why the model writes every send's mute too.
    s.set(s.strip + ChannelStrip::kMute, 1.0f);
    s.twoBlocks();
    DAW_CHECK(all(rig.left(), 256, 512, 0.125));
    s.set(s.strip + ChannelStrip::kMute, 0.0f);
    s.twoBlocks();
    DAW_CHECK(all(rig.left(), 256, 512, kBase));

    // MIX-007: muting the track (strip + both sends) silences the strip and both sends, so the
    // bus gets nothing. All three fade over the same block; the post-fader send fades twice (its
    // own mute on top of the strip's), so it follows (1 − t)², t = (i + 1)/256.
    s.muteTrack(true);
    s.twoBlocks();
    bool fade = true;
    for (uint32_t i = 0; i < 256; ++i) {
        const double u = 1.0 - (i + 1) / 256.0;
        const double v = 0.5 * kH * u + 0.25 * kH * u * u + 0.125 * u;
        fade = fade && near(rig.left()[i], v) && near(rig.right()[i], v);
    }
    DAW_CHECK(fade);
    DAW_CHECK(all(rig.left(), 255, 512, 0.0, 0.0) && all(rig.right(), 255, 512, 0.0, 0.0));
    // Send levels and the fader still move while muted (the model keeps them), silently.
    s.set(s.pre + GainNode::kLevel, 0.5f);
    s.twoBlocks();
    DAW_CHECK(all(rig.left(), 0, 512, 0.0, 0.0));

    // Unmuting brings both sends back without a click: a fade-in over one block, from the silent
    // last frame, to the new levels (pre send now 0.5 · 0.5).
    s.muteTrack(false);
    s.twoBlocks();
    bool fadeIn = true;
    for (uint32_t i = 0; i < 256; ++i) {
        const double t = (i + 1) / 256.0;
        const double v = 0.5 * kH * t + 0.25 * kH * t * t + 0.25 * t;
        fadeIn = fadeIn && near(rig.left()[i], v) && near(rig.right()[i], v);
    }
    DAW_CHECK(fadeIn);
    const double unmuted = 0.75 * kH + 0.25;
    DAW_CHECK(all(rig.left(), 255, 512, unmuted) && all(rig.right(), 255, 512, unmuted));
    // No click: no frame-to-frame step exceeds the steepest the fade can be (the (t²)' = 2t
    // term at t = 1), starting from the silent frame before.
    const double maxStep = (0.5 * kH + 2 * 0.25 * kH + 0.25) / 256 + 1e-6;
    bool smooth = std::fabs(rig.left()[0]) <= maxStep;
    for (size_t i = 1; i < 512; ++i) smooth = smooth && std::fabs(rig.left()[i] - rig.left()[i - 1]) <= maxStep;
    DAW_CHECK(smooth);

    DAW_CHECK(rig.violations() == 0);
    return checks;
}

} // namespace daw::testing
