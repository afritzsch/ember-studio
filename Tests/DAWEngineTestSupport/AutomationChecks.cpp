// T-074 checks for automation (11). Run from Tests/DAWEngineTests/AutomationTests.swift; see
// AutomationChecks.h for why they're C++.

#include "AutomationChecks.h"

#include <cmath>
#include <cstdint>
#include <limits>
#include <numbers>
#include <vector>

#include "NodeTestHarness.h"
#include "automation/AutomationCompiler.h"
#include "automation/AutomationCurve.h"
#include "automation/AutomationPlayer.h"
#include "automation/ParamMapping.h"
#include "core/RtTrap.h"
#include "nodes/ChannelStrip.h"
#include "nodes/Compressor.h"
#include "nodes/GainNode.h"

using namespace daw;
using namespace daw::testing::nodes;

namespace daw::testing {

namespace {

constexpr double kH = std::numbers::sqrt2 / 2;  // centre pan, per side (MIX-005)

bool near(double a, double b, double tol = 1e-6) { return std::fabs(a - b) <= tol; }
bool nearRel(double a, double b, double rel = 1e-5) { return std::fabs(a - b) <= rel * std::max(1e-3, std::fabs(b)); }

AutomationPoint pt(Tick tick, float value, AutomationCurve curve = AutomationCurve::linear, float shape = 0) {
    return AutomationPoint{tick, value, curve, shape};
}

AutomationPointDesc pd(Tick tick, float value, uint8_t curve = 0, float shape = 0) {
    return AutomationPointDesc{tick, value, curve, shape};
}

ParamMapping stripGainMapping() { return ParamMapping::from(ChannelStrip::kParamInfo[ChannelStrip::kGain]); }

// player 10 (mono DC 1.0) → strip 20 → master 1. With `gainNode`, a send-like gain node 30
// (level + mute) sits between player and master instead of the strip.
struct LaneRig {
    explicit LaneRig(bool gainNode = false) : gain(gainNode) {
        rig.addAsset(makeAsset(1, 1, 10'000'000, [](uint32_t, int64_t) { return 1.0f; }));
        ParamSlotTable& params = rig.engine().params();
        const uint32_t count = gain ? GainNode::kNumParams : ChannelStrip::kNumParams;
        auto s = params.allocate(count, 0.0f);
        ok = s.ok();
        if (!ok) return;
        first = s.value();
        params.set(first, 1.0f);  // gain / level
        d = baseDescription();
        d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
        if (gain)
            d.nodes.push_back(NodeDesc{30, NodeKind::gain, 1, first, GainNode::kNumParams, {}});
        else
            d.nodes.push_back(NodeDesc{20, NodeKind::channelStrip, 1, first, ChannelStrip::kNumParams, {}});
        const NodeID mid = gain ? 30 : 20;
        d.edges.push_back(EdgeDesc{1, 10, mid, EdgeKind::audio, 0});
        d.edges.push_back(EdgeDesc{2, mid, 1, EdgeKind::audio, 0});
        d.audioClips.push_back(clip(10, 1, 0, 300'000, 1));
    }

    void lane(std::vector<AutomationPointDesc> points, bool enabled = true, uint32_t index = 0) {
        d.automation.push_back(AutomationDesc{7, first + index, std::move(points), enabled});
    }

    // What one output frame is per unit of gain: the strip pans centre, a gain node doesn't.
    double scale() const { return gain ? 1.0 : kH; }
    float slot(uint32_t index = 0) { return rig.engine().params().get(first + index); }

    Rig rig;
    bool gain;
    bool ok = false;
    ParamID first = 0;
    GraphDescription d;
};

} // namespace

CheckResult automationCurves() {
    CheckResult checks;
    // AUTO-004: linear halfway; hold keeps the left value; exp follows (e^(s f) − 1)/(e^s − 1).
    DAW_CHECK(near(interpolate(pt(0, 0.2f), pt(100, 0.6f), 50), 0.4));
    DAW_CHECK(near(interpolate(pt(0, 0.2f), pt(100, 0.6f), 0), 0.2));
    DAW_CHECK(near(interpolate(pt(0, 0.2f), pt(100, 0.6f), 100), 0.6));
    DAW_CHECK(interpolate(pt(0, 0.2f, AutomationCurve::hold), pt(100, 0.6f), 99) == 0.2f);
    for (const float s : {3.0f, -3.0f, 0.5f}) {
        const double w = std::expm1(s * 0.25) / std::expm1(double{s});
        DAW_CHECK(near(interpolate(pt(0, 0.0f, AutomationCurve::exponential, s), pt(400, 1.0f), 100), w));
    }
    // s > 0 starts slowly (below linear), s < 0 starts fast.
    DAW_CHECK(interpolate(pt(0, 0.0f, AutomationCurve::exponential, 4), pt(100, 1.0f), 50) < 0.5f);
    DAW_CHECK(interpolate(pt(0, 0.0f, AutomationCurve::exponential, -4), pt(100, 1.0f), 50) > 0.5f);
    // A shape of ~0 is linear; a huge or NaN one is clamped, never NaN; a falling segment works.
    DAW_CHECK(near(interpolate(pt(0, 0.0f, AutomationCurve::exponential, 1e-6f), pt(100, 1.0f), 30), 0.3));
    const float huge = interpolate(pt(0, 0.0f, AutomationCurve::exponential, 1e9f), pt(100, 1.0f), 99);
    const float nan = interpolate(pt(0, 0.0f, AutomationCurve::exponential, std::nanf("")), pt(100, 1.0f), 50);
    DAW_CHECK(huge >= 0.0f && huge <= 1.0f && nan >= 0.0f && nan <= 1.0f);
    DAW_CHECK(near(interpolate(pt(0, 1.0f), pt(100, 0.0f), 25), 0.75));
    // Values outside 0…1 (never sent by the model) are clamped.
    DAW_CHECK(interpolate(pt(0, 2.0f), pt(100, 3.0f), 50) == 1.0f);

    // Player: before the first point holds it, after the last too; cursor and searches.
    AutomationPlayer player(1, 0, {pt(100, 0.0f), pt(200, 1.0f), pt(300, 0.5f, AutomationCurve::hold), pt(400, 0.0f)},
                            ParamMapping::identity());
    uint64_t violations = 0;
    bool walk = true;
    {
        RtScope scope;
        walk = walk && player.normalizedAt(0) == 0.0f;
        walk = walk && near(player.normalizedAt(150), 0.5);
        for (Tick t = 150; t < 340; t += 7) (void)player.normalizedAt(t);  // forward, block by block
        walk = walk && player.normalizedAt(350) == 0.5f;  // hold
        for (Tick t = 350; t < 500; t += 7) (void)player.normalizedAt(t);
        walk = walk && player.normalizedAt(10'000) == 0.0f;
        violations += scope.violations();
    }
    DAW_CHECK(walk);
    DAW_CHECK(player.searches() == 0);  // only forward steps of at most one segment
    {
        RtScope scope;
        walk = near(player.normalizedAt(120), 0.2);  // a jump back (loop wrap, locate): a search
        violations += scope.violations();
    }
    DAW_CHECK(walk && player.searches() == 1 && player.cursor() == 0);
    DAW_CHECK(violations == 0);

    // ParamMapping (AUTO-008).
    const ParamMapping lin{-1.0f, 1.0f, ParamMapping::Scale::linear};
    DAW_CHECK(lin.map(0.0f) == -1.0f && lin.map(0.5f) == 0.0f && lin.map(1.0f) == 1.0f && lin.map(7.0f) == 1.0f);
    DAW_CHECK(lin.map(std::nanf("")) == -1.0f);
    const ParamMapping log{20.0f, 20000.0f, ParamMapping::Scale::log};
    DAW_CHECK(nearRel(log.map(0.0f), 20.0) && nearRel(log.map(0.5f), 632.4555) && nearRel(log.map(1.0f), 20000.0));
    const ParamMapping fader = stripGainMapping();
    DAW_CHECK(fader.scale == ParamMapping::Scale::db && fader.map(0.0f) == 0.0f);
    DAW_CHECK(nearRel(fader.map(1.0f), ChannelStrip::kMaxGain) && nearRel(fader.map(5.0f / 6.0f), 1.0));
    DAW_CHECK(nearRel(fader.map(0.5f), std::pow(10.0, -24.0 / 20.0)));  // −60 + 72·0.5 = −24 dB
    const ParamMapping dbPositive{0.5f, 2.0f, ParamMapping::Scale::db};
    DAW_CHECK(nearRel(dbPositive.map(0.5f), 1.0));
    return checks;
}

CheckResult automationCompile() {
    CheckResult checks;
    LaneRig r;
    DAW_CHECK(r.ok);
    // player → compressor 40 → strip: a ParamInfo row with its own range.
    auto comp = r.rig.engine().params().allocate(Compressor::kNumParams, 0.0f);
    DAW_CHECK(comp.ok());
    if (!r.ok || !comp.ok()) return checks;
    GraphDescription d = r.d;
    d.nodes.push_back(NodeDesc{40, NodeKind::compressor, 1, comp.value(), Compressor::kNumParams, {}});
    d.edges[0] = EdgeDesc{1, 10, 40, EdgeKind::audio, 0};
    d.edges.push_back(EdgeDesc{3, 40, 20, EdgeKind::audio, 0});
    auto unowned = r.rig.engine().params().allocate(1, 0.0f);
    DAW_CHECK(unowned.ok());

    // Rejected: nothing about a bad lane is guessed.
    const auto rejects = [&](AutomationDesc lane) {
        GraphDescription bad = d;
        bad.automation.push_back(std::move(lane));
        auto built = r.rig.build(bad);
        return !built.ok() && built.error().code == ErrorCode::invalidArgument;
    };
    const float inf = std::numeric_limits<float>::infinity();
    DAW_CHECK(rejects({1, r.first, {pd(10, 0.5f), pd(5, 0.5f)}, true}));                 // unsorted
    DAW_CHECK(rejects({1, r.first, {pd(10, 0.5f), pd(10, 0.6f)}, true}));                // repeated tick
    DAW_CHECK(rejects({1, r.first, {pd(10, std::nanf(""))}, true}));                      // NaN value
    DAW_CHECK(rejects({1, r.first, {pd(10, 0.5f, 2, inf)}, true}));                       // infinite shape
    DAW_CHECK(rejects({1, r.first, {pd(10, 0.5f, 7)}, true}));                            // unknown curve
    DAW_CHECK(rejects({1, r.rig.engine().params().capacity(), {pd(10, 0.5f)}, true}));   // outside the table
    DAW_CHECK(rejects({1, r.first, {pd(10, 0.5f), pd(5, 0.5f)}, false}));  // validated even when off

    // Compiled: gain (db), pan (linear), threshold (linear −60…0). Left out: off, empty, phase
    // (not automatable), a slot no node owns.
    GraphDescription good = d;
    good.automation.push_back({1, r.first + ChannelStrip::kGain, {pd(0, 0.0f), pd(960, 1.0f)}, true});
    good.automation.push_back({2, r.first + ChannelStrip::kPan, {pd(0, 0.5f)}, true});
    good.automation.push_back({3, comp.value() + Compressor::kThreshold, {pd(0, 0.5f)}, true});
    good.automation.push_back({4, r.first + ChannelStrip::kMute, {pd(0, 1.0f)}, false});
    good.automation.push_back({5, r.first + ChannelStrip::kMute, {}, true});
    good.automation.push_back({6, r.first + ChannelStrip::kPhase, {pd(0, 1.0f)}, true});
    good.automation.push_back({8, unowned.value(), {pd(0, 1.0f)}, true});
    auto built = r.rig.build(good);
    DAW_CHECK(built.ok());
    if (!built.ok()) return checks;
    const AutomationSet* set = built.value()->automation();
    DAW_CHECK(set != nullptr && set->size() == 3);
    if (set == nullptr || set->size() != 3) return checks;
    DAW_CHECK(set->player(0).laneID() == 1 && set->player(0).target() == r.first);
    DAW_CHECK(set->player(0).mapping().scale == ParamMapping::Scale::db &&
              set->player(0).mapping().max == ChannelStrip::kMaxGain);
    DAW_CHECK(set->player(1).mapping().min == -1.0f && set->player(1).mapping().max == 1.0f &&
              set->player(1).mapping().scale == ParamMapping::Scale::linear);
    DAW_CHECK(set->player(2).mapping().min == -60.0f && set->player(2).mapping().max == 0.0f);
    DAW_CHECK(set->player(0).points().size() == 2 && set->player(0).points()[1].tick == 960);

    // No lanes, or none left: no set at all.
    auto plain = r.rig.build(d);
    DAW_CHECK(plain.ok() && plain.value()->automation() == nullptr);
    return checks;
}

CheckResult automationDrivesSlots() {
    CheckResult checks;
    LaneRig r;
    DAW_CHECK(r.ok);
    if (!r.ok) return checks;
    // AUTO-002: 0 → 1 over one bar (3840 ticks = 96 000 frames at 120 bpm, 48 kHz).
    r.lane({pd(0, 0.0f), pd(3840, 1.0f)});
    DAW_CHECK(r.rig.publish(r.d));
    DAW_CHECK(r.rig.transport().locate(0) && r.rig.transport().play());
    AutomationPlayer oracle(7, 0, {pt(0, 0.0f), pt(3840, 1.0f)}, stripGainMapping());

    // 500-frame blocks are 20 ticks: block k starts at tick 20k, and its last frame is the lane's
    // value there (the strip ramps from the previous block's value to it, ENG-022).
    constexpr uint32_t kBlock = 500;
    r.rig.renderFrames(110'000, [] { return kBlock; });
    bool follows = true;
    bool withinOneBlock = true;
    for (uint32_t k = 0; k < 220; ++k) {
        const double g = oracle.valueAt(Tick{20} * k);
        follows = follows && nearRel(r.rig.left()[k * kBlock + kBlock - 1], g * kH);
        // Every frame lies between the analytic gain one block earlier and at the frame itself.
        // From block 2 on: the db fader is discontinuous at 0 (silence), right after block 0.
        for (uint32_t i = 0; k >= 2 && i < kBlock; i += 97) {
            const int64_t frame = int64_t{k} * kBlock + i;
            const double now = oracle.valueAt(frame / kSamplesPerTick) * kH;
            const double before = oracle.valueAt(std::max<int64_t>(0, frame - kBlock) / kSamplesPerTick) * kH;
            const double out = r.rig.left()[static_cast<size_t>(frame)];
            withinOneBlock = withinOneBlock && out >= before - 1e-6 && out <= now + 1e-6;
        }
    }
    DAW_CHECK(follows);
    DAW_CHECK(withinOneBlock);
    DAW_CHECK(r.slot() == r.rig.engine().params().get(r.first) && nearRel(r.slot(), ChannelStrip::kMaxGain));

    // Past the last point the value holds and the slot isn't rewritten.
    const uint32_t generation = r.rig.engine().params().generation(r.first);
    r.rig.renderFrames(2 * kBlock, [] { return kBlock; });
    DAW_CHECK(r.rig.engine().params().generation(r.first) == generation);

    // AUTO-005 read: a write between blocks (SetParam) is overridden at the next block start.
    r.rig.engine().params().set(r.first, 0.25f);
    r.rig.clearOutput();
    r.rig.renderFrames(kBlock, [] { return kBlock; });
    DAW_CHECK(nearRel(r.rig.left()[kBlock - 1], ChannelStrip::kMaxGain * kH) && nearRel(r.slot(), ChannelStrip::kMaxGain));

    // While stopped: the lane's value at the playhead, written once per position.
    DAW_CHECK(r.rig.transport().stop());
    r.rig.renderFrames(kBlock, [] { return kBlock; });
    r.rig.engine().params().set(r.first, 0.25f);  // SetParam while stopped holds …
    r.rig.renderFrames(3 * kBlock, [] { return kBlock; });
    DAW_CHECK(r.slot() == 0.25f);
    DAW_CHECK(r.rig.transport().locate(1920));  // … until the playhead moves
    r.rig.renderFrames(kBlock, [] { return kBlock; });
    DAW_CHECK(r.slot() == oracle.valueAt(1920));
    DAW_CHECK(nearRel(r.slot(), std::pow(10.0, -24.0 / 20.0)));

    // AUTO-005 off: the lane is ignored, the slot keeps what was written.
    LaneRig off;
    off.lane({pd(0, 0.0f), pd(3840, 1.0f)}, false);
    DAW_CHECK(off.rig.publish(off.d));
    off.rig.engine().params().set(off.first, 0.7f);
    DAW_CHECK(off.rig.transport().locate(0) && off.rig.transport().play());
    off.rig.renderFrames(10 * kBlock, [] { return kBlock; });
    DAW_CHECK(off.slot() == 0.7f && nearRel(off.rig.left().back(), 0.7 * kH));

    DAW_CHECK(r.rig.violations() == 0 && off.rig.violations() == 0);
    return checks;
}

CheckResult automationLoopWrapJump() {
    CheckResult checks;
    // Loop ticks [960, 1920) = frames [24 000, 48 000); the lane rises 0.2 → 1 across it, so the
    // wrap falls from ~1 back to 0.2. 700-frame blocks: block 68 starts at 47 600 and wraps at
    // its frame 400; segment 2 starts at tick 960.
    constexpr uint32_t kBlock = 700;
    constexpr uint32_t kWrapBlock = 68, kWrapFrame = 400;
    for (const bool gainNode : {false, true}) {
        LaneRig r(gainNode);
        DAW_CHECK(r.ok);
        if (!r.ok) return checks;
        r.lane({pd(960, 0.2f), pd(1920, 1.0f)});
        DAW_CHECK(r.rig.publish(r.d));
        DAW_CHECK(r.rig.transport().setLoop(true, 960, 1920));
        DAW_CHECK(r.rig.transport().locate(0) && r.rig.transport().play());
        r.rig.renderFrames(int64_t{kBlock} * 72, [] { return kBlock; });
        AutomationPlayer oracle(7, 0, {pt(960, 0.2f), pt(1920, 1.0f)},
                                ParamMapping::from(gainNode ? GainNode::kParamInfo[GainNode::kLevel]
                                                            : ChannelStrip::kParamInfo[ChannelStrip::kGain]));
        const double s = r.scale();
        // Ticks at 120 bpm / 48 kHz: 25 frames each, so a block start s has first tick ceil(s / 25).
        const auto tickAt = [](int64_t sample) { return Tick{(sample + kSamplesPerTick - 1) / kSamplesPerTick}; };
        const double g67 = oracle.valueAt(tickAt(int64_t{kWrapBlock - 1} * kBlock));
        const double g0 = oracle.valueAt(tickAt(int64_t{kWrapBlock} * kBlock));
        const double g1 = oracle.valueAt(960);  // the second segment's start: the loop start
        DAW_CHECK(near(g1, oracle.mapping().map(0.2f)));
        const float* out = r.rig.left().data() + size_t{kWrapBlock} * kBlock;
        bool ramp = true, jump = true;
        for (uint32_t i = 0; i < kWrapFrame; ++i)
            ramp = ramp && nearRel(out[i], s * (g67 + (g0 - g67) * (i + 1) / kWrapFrame));
        for (uint32_t i = kWrapFrame; i < kBlock; ++i) jump = jump && nearRel(out[i], s * g1);
        DAW_CHECK(ramp);
        DAW_CHECK(jump);
        // The next block (transport frame 24 300, tick 972) ramps on from the loop-start value.
        const double g2 = oracle.valueAt(tickAt(24'000 + (kBlock - kWrapFrame)));
        bool next = true;
        for (uint32_t i = 0; i < kBlock; ++i) next = next && nearRel(out[kBlock + i], s * (g1 + (g2 - g1) * (i + 1) / kBlock));
        DAW_CHECK(next);
        DAW_CHECK(r.rig.violations() == 0);
    }

    // Without a lane, a wrap block ramps the whole block as before (no stale jump entry).
    LaneRig plain;
    DAW_CHECK(plain.rig.publish(plain.d));
    DAW_CHECK(plain.rig.transport().setLoop(true, 960, 1920));
    DAW_CHECK(plain.rig.transport().locate(0) && plain.rig.transport().play());
    plain.rig.renderFrames(int64_t{kBlock} * kWrapBlock, [] { return kBlock; });
    plain.rig.engine().params().set(plain.first, 2.0f);
    plain.rig.renderFrames(kBlock, [] { return kBlock; });
    const float* out = plain.rig.left().data() + size_t{kWrapBlock} * kBlock;
    bool whole = true;
    for (uint32_t i = 0; i < kBlock; ++i) whole = whole && nearRel(out[i], kH * (1.0 + 1.0 * (i + 1) / kBlock));
    DAW_CHECK(whole);
    DAW_CHECK(plain.rig.violations() == 0);
    return checks;
}

} // namespace daw::testing
