// T-089 checks for DW-063 (offline renders reset every node first). Run from
// Tests/DAWEngineTests/OfflineResetTests.swift; see OfflineResetChecks.h.

#include "OfflineResetChecks.h"

#include <cmath>
#include <cstdint>
#include <cstring>
#include <iterator>
#include <functional>
#include <memory>
#include <span>
#include <string>
#include <vector>

#include "NodeTestHarness.h"
#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ProcessContext.h"
#include "core/RtTrap.h"
#include "dsp/ParamInfo.h"
#include "io/OfflineDriver.h"
#include "nodes/ChannelStrip.h"
#include "nodes/Compressor.h"
#include "nodes/Delay.h"
#include "nodes/Eq.h"
#include "nodes/GainNode.h"
#include "nodes/Reverb.h"
#include "time/TempoMap.h"
#include "time/TransportBlock.h"

using namespace daw;

namespace daw::testing {

namespace {

using namespace nodes;
using Channels = std::vector<std::vector<float>>;

bool sameBits(const Channels& a, const Channels& b) {
    if (a.size() != b.size()) return false;
    for (size_t c = 0; c < a.size(); ++c) {
        if (a[c].size() != b[c].size()) return false;
        if (std::memcmp(a[c].data(), b[c].data(), a[c].size() * sizeof(float)) != 0) return false;
    }
    return true;
}

bool anyAbove(const std::vector<float>& x, size_t from, size_t to, float threshold) {
    for (size_t i = from; i < to && i < x.size(); ++i)
        if (std::fabs(x[i]) > threshold) return true;
    return false;
}

// Deterministic noise in [-amp, amp] (LCG), so every run and node sees the same input.
std::vector<float> noise(size_t n, float amp, uint32_t seed) {
    std::vector<float> out(n);
    uint32_t x = seed;
    for (float& s : out) {
        x = x * 1664525u + 1013904223u;
        s = amp * (static_cast<float>(x >> 8) / static_cast<float>(1u << 24) * 2.0f - 1.0f);
    }
    return out;
}

// Allocates `info.size()` slots at their defaults; returns the first.
ParamID defaults(ParamSlotTable& params, std::span<const ParamInfo> info) {
    auto first = params.allocate(static_cast<uint32_t>(info.size()), 0.0f);
    if (!first) return 0;
    for (const ParamInfo& p : info) params.set(first.value() + p.index, p.def);
    return first.value();
}

// player 10 (a 0.1 s noise burst from tick 0) → EQ 20 → compressor 30 → delay 40 → reverb 50 →
// strip 60 → master 1: every built-in effect with state, at its defaults, plus a +6 dB low shelf
// and the high-pass on (so the EQ has state) and a 3 s reverb (so the tail rings for a while).
struct TailRig {
    TailRig() {
        rig.addAsset(makeAsset(1, 2, 4800, [](uint32_t c, int64_t i) {
            static const std::vector<float> l = noise(4800, 0.5f, 7), r = noise(4800, 0.5f, 8);
            return c == 0 ? l[static_cast<size_t>(i)] : r[static_cast<size_t>(i)];
        }));
        ParamSlotTable& params = rig.engine().params();
        const ParamID eq = defaults(params, Eq::kParamInfo);
        params.set(eq + Eq::kHpOn, 1.0f);
        params.set(eq + Eq::kLowGain, 6.0f);
        const ParamID comp = defaults(params, Compressor::kParamInfo);
        const ParamID delay = defaults(params, Delay::kParamInfo);
        const ParamID reverb = defaults(params, Reverb::kParamInfo);
        params.set(reverb + Reverb::kDecay, 3.0f);
        params.set(reverb + Reverb::kMix, 0.5f);
        const ParamID strip = defaults(params, ChannelStrip::kParamInfo);
        d = baseDescription();
        d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
        d.nodes.push_back(NodeDesc{20, NodeKind::eq, 1, eq, Eq::kNumParams, {}});
        d.nodes.push_back(NodeDesc{30, NodeKind::compressor, 1, comp, Compressor::kNumParams, {}});
        d.nodes.push_back(NodeDesc{40, NodeKind::delay, 1, delay, Delay::kNumParams, {}});
        d.nodes.push_back(NodeDesc{50, NodeKind::reverb, 1, reverb, Reverb::kNumParams, {}});
        d.nodes.push_back(NodeDesc{60, NodeKind::channelStrip, 1, strip, ChannelStrip::kNumParams, {}});
        const NodeID chain[] = {10, 20, 30, 40, 50, 60, 1};
        for (uint64_t i = 0; i + 1 < std::size(chain); ++i)
            d.edges.push_back(EdgeDesc{100 + i, chain[i], chain[i + 1], EdgeKind::audio, 0});
        d.audioClips.push_back(clip(10, 1, 0, 192, 1));  // 4800 frames
        ok = rig.publish(d);
    }

    // Exports ticks [from, to) through OfflineDriver into its sink; empty on failure.
    Channels exportRange(Tick from, Tick to, uint64_t& violations) {
        ExportSpec spec;
        spec.tail.enabled = false;
        spec.blockSize = 512;
        Channels out(2);
        spec.sink = [&](const AudioBufferView& block) {
            for (uint32_t c = 0; c < 2 && c < block.numChannels; ++c)
                out[c].insert(out[c].end(), block.channels[c], block.channels[c] + block.numFrames);
        };
        OfflineDriver driver;
        if (!driver.render(rig.engine(), from, to, spec, nullptr).ok()) return {};
        violations += driver.lastRender().rtViolations;
        return out;
    }

    Rig rig;
    GraphDescription d;
    bool ok = false;
};

} // namespace

CheckResult offlineResetsEveryNode() {
    CheckResult checks;
    uint64_t violations = 0;
    // Ticks 0..960: the burst and 0.4 s of its tails.
    TailRig fresh;
    DAW_CHECK(fresh.ok);
    if (!fresh.ok) return checks;
    const Channels reference = fresh.exportRange(0, 960, violations);
    DAW_CHECK(reference.size() == 2 && reference[0].size() == 24000);
    DAW_CHECK(anyAbove(reference[0], 6000, 24000, 1e-3f));  // the tails ring after the burst

    TailRig r;
    DAW_CHECK(r.ok);
    if (!r.ok) return checks;
    Transport& transport = r.rig.transport();
    // An export on an engine that never played: the same bits as on the other fresh engine.
    DAW_CHECK(sameBits(r.exportRange(0, 960, violations), reference));

    // Live playback of the burst, stopped while the delay and reverb ring.
    DAW_CHECK(transport.locate(0) && transport.play());
    r.rig.renderFrames(9600, [] { return 512u; });
    DAW_CHECK(transport.stop());
    r.rig.renderFrames(512, [] { return 512u; });  // stopped: the effects keep ringing
    DAW_CHECK(anyAbove(r.rig.left(), r.rig.left().size() - 512, r.rig.left().size(), 1e-3f));
    // DW-063: the export starts from a clean state anyway.
    DAW_CHECK(sameBits(r.exportRange(0, 960, violations), reference));

    // An export cut off mid-tail (ticks 0..200, ending right after the burst), then the full one.
    const Channels cut = r.exportRange(0, 200, violations);
    DAW_CHECK(cut.size() == 2 && anyAbove(cut[0], cut[0].size() - 256, cut[0].size(), 1e-3f));
    DAW_CHECK(sameBits(r.exportRange(0, 960, violations), reference));

    // TIME-008 unchanged live: a locate while playing resets only the timeline nodes, so the tail
    // of the burst still sounds after a jump to silence (tick 4000, far past the clip).
    r.rig.clearOutput();
    DAW_CHECK(transport.locate(0) && transport.play());
    r.rig.renderFrames(6144, [] { return 512u; });
    DAW_CHECK(transport.locate(4000));
    r.rig.renderFrames(2048, [] { return 512u; });
    DAW_CHECK(anyAbove(r.rig.left(), 6144, 6144 + 2048, 1e-3f));
    DAW_CHECK(transport.stop());

    DAW_CHECK(violations == 0);
    DAW_CHECK(r.rig.violations() == 0 && fresh.rig.violations() == 0);
    return checks;
}

namespace {

// Drives one node directly: prepares it, processes stereo input in 512-frame blocks.
struct NodeDriver {
    NodeDriver(std::unique_ptr<Node> n, ParamSlotTable& p) : node(std::move(n)), params(p) {
        node->prepare(PrepareInfo{kRate, kMaxBlock, 2, 2});
    }
    Channels run(const std::vector<float>& l, const std::vector<float>& r) {
        Channels out(2);
        for (size_t from = 0; from < l.size(); from += 512) {
            const auto n = static_cast<uint32_t>(std::min<size_t>(512, l.size() - from));
            std::vector<float> inL(l.begin() + static_cast<std::ptrdiff_t>(from),
                                   l.begin() + static_cast<std::ptrdiff_t>(from + n));
            std::vector<float> inR(r.begin() + static_cast<std::ptrdiff_t>(from),
                                   r.begin() + static_cast<std::ptrdiff_t>(from + n));
            std::vector<float> oL(n, -99.0f), oR(n, -99.0f);
            float* in[2] = {inL.data(), inR.data()};
            float* outp[2] = {oL.data(), oR.data()};
            NodeIO io;
            io.audioIn = AudioBufferView{in, 2, n};
            io.audioOut = AudioBufferView{outp, 2, n};
            TransportBlock block{false, false, 0, {}, &tempo};
            ProcessContext ctx{n, kRate, block, params};
            {
                RtScope scope;
                node->process(ctx, io);
                violations += scope.violations();
            }
            out[0].insert(out[0].end(), oL.begin(), oL.end());
            out[1].insert(out[1].end(), oR.begin(), oR.end());
        }
        return out;
    }
    void reset() {
        RtScope scope;
        node->reset();
        violations += scope.violations();
    }
    std::unique_ptr<Node> node;
    ParamSlotTable& params;
    TempoMap tempo;
    uint64_t violations = 0;
};

} // namespace

CheckResult builtinResetMatchesFreshNode() {
    CheckResult checks;
    (void)RtTrap::install();  // no Engine here to install it (ENG-030)
    struct Kind {
        const char* name;
        std::span<const ParamInfo> info;
        std::function<std::unique_ptr<Node>(ParamID)> make;
        std::function<void(ParamSlotTable&, ParamID)> tweak;
    };
    const std::vector<Kind> kinds = {
        {"reverb", Reverb::kParamInfo, [](ParamID p) { return std::make_unique<Reverb>(p, Reverb::kNumParams); },
         [](ParamSlotTable& t, ParamID p) { t.set(p + Reverb::kDecay, 3.0f); }},
        {"delay", Delay::kParamInfo, [](ParamID p) { return std::make_unique<Delay>(p, Delay::kNumParams); }, {}},
        {"compressor", Compressor::kParamInfo,
         [](ParamID p) { return std::make_unique<Compressor>(p, Compressor::kNumParams); }, {}},
        {"eq", Eq::kParamInfo, [](ParamID p) { return std::make_unique<Eq>(p, Eq::kNumParams); },
         [](ParamSlotTable& t, ParamID p) {
             t.set(p + Eq::kHpOn, 1.0f);
             t.set(p + Eq::kLowGain, 6.0f);
         }},
        {"strip", ChannelStrip::kParamInfo, [](ParamID p) { return std::make_unique<ChannelStrip>(p); }, {}},
        {"gain", GainNode::kParamInfo, [](ParamID p) { return std::make_unique<GainNode>(p, GainNode::kNumParams); },
         {}},
    };
    const std::vector<float> loudL = noise(24000, 0.8f, 1), loudR = noise(24000, 0.8f, 2);
    const std::vector<float> testL = noise(12000, 0.3f, 3), testR = noise(12000, 0.3f, 4);
    for (const Kind& k : kinds) {
        ParamSlotTable params(64);
        const ParamID first = defaults(params, k.info);
        if (k.tweak) k.tweak(params, first);
        NodeDriver used(k.make(first), params);
        NodeDriver fresh(k.make(first), params);
        // Play something else at other settings, so state and smoothers sit elsewhere.
        for (const ParamInfo& p : k.info) params.set(first + p.index, p.max);
        (void)used.run(loudL, loudR);
        for (const ParamInfo& p : k.info) params.set(first + p.index, p.def);
        if (k.tweak) k.tweak(params, first);
        used.reset();
        const Channels a = used.run(testL, testR);
        const Channels b = fresh.run(testL, testR);
        if (!sameBits(a, b)) {
            const std::string what = std::string("check failed: reset() of ") + k.name + " differs from a fresh node";
            checks.fail(what.c_str(), __FILE__, __LINE__);
        }
        DAW_CHECK(used.violations == 0 && fresh.violations == 0);
    }
    return checks;
}

} // namespace daw::testing
