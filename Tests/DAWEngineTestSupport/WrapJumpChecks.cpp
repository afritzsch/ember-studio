// T-092 (DW-232) AUTO-003 checks for the built-in effects and instruments. Run from
// Tests/DAWEngineTests/WrapJumpTests.swift; see WrapJumpChecks.h.

#include "WrapJumpChecks.h"

#include <cmath>
#include <cstdint>
#include <functional>
#include <memory>
#include <random>
#include <utility>
#include <vector>

#include "NodeTestHarness.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/ProcessContext.h"
#include "core/RtTrap.h"
#include "nodes/Compressor.h"
#include "nodes/Delay.h"
#include "nodes/Eq.h"
#include "nodes/Metronome.h"
#include "nodes/Reverb.h"
#include "nodes/Sampler.h"
#include "time/TransportSegments.h"

using namespace daw;

namespace daw::testing {

namespace {

constexpr double kRate = 48000.0;
// The loop: ticks [960, 1920) = samples [24 000, 48 000) at the default 120 bpm (25 samples per
// tick). A wrap block plays the loop's last `wrap` samples, then the loop start.
constexpr SamplePos kLoopStart = 24'000, kLoopEnd = 48'000;

using Params = std::vector<std::pair<uint32_t, float>>;

std::vector<float> noise(size_t n, uint32_t seed, float amp) {
    std::mt19937 rng(seed);
    std::uniform_real_distribution<float> d(-amp, amp);
    std::vector<float> v(n);
    for (float& x : v) x = d(rng);
    return v;
}

bool same(const std::vector<float>& a, size_t aFrom, const std::vector<float>& b, size_t bFrom, size_t n) {
    if (a.size() < aFrom + n || b.size() < bFrom + n) return false;
    for (size_t i = 0; i < n; ++i)
        if (a[aFrom + i] != b[bFrom + i]) return false;
    return true;
}

// Drives one node directly, the way the Engine would: its own param slots, one block at a time,
// in RtScopes. Blocks play the timeline from `pos`; a wrap block registers after-wrap values
// like AutomationSet::apply does.
template <class NodeT>
struct WrapRig {
    template <class Make>
    explicit WrapRig(Make make, const Params& set = {}) : params(64) {
        trapInstalled = RtTrap::install();  // no Engine here to install it (ENG-030)
        first = params.allocate(NodeT::kNumParams).value();
        for (const ParamInfo& p : NodeT::kParamInfo) params.set(first + p.index, p.def);
        apply(set);
        node = make(first);
        node->prepare(PrepareInfo{kRate, kMaxBlock, 2, 2});
    }

    void apply(const Params& set) {
        for (auto [i, v] : set) params.set(first + i, v);
    }

    // Frames [from, from + n) of `in` (empty: no input). `wrap` > 0: the block wraps at that frame
    // and `after` are the automated params' values after the wrap.
    void process(const std::vector<float>& inL, const std::vector<float>& inR, size_t from, uint32_t n,
                 uint32_t wrap = 0, const Params& after = {}, const std::vector<MidiEvent>& midi = {}) {
        std::vector<float> l(n, -99.0f), r(n, -99.0f);
        float* out[2] = {l.data(), r.data()};
        float* in[2] = {nullptr, nullptr};
        std::vector<float> cl, cr;
        NodeIO io;
        if (!inL.empty()) {
            cl.assign(inL.begin() + static_cast<std::ptrdiff_t>(from), inL.begin() + static_cast<std::ptrdiff_t>(from + n));
            cr.assign(inR.begin() + static_cast<std::ptrdiff_t>(from), inR.begin() + static_cast<std::ptrdiff_t>(from + n));
            in[0] = cl.data();
            in[1] = cr.data();
            io.audioIn = AudioBufferView{in, 2, n};
        }
        io.audioOut = AudioBufferView{out, 2, n};
        io.midiIn = MidiEventSpan(midi.data(), midi.size());

        TransportBlock block{true, false, 1, {}, &tempo};
        if (wrap == 0) {
            block.seg[0] = TransportSegment{pos, firstTickAtOrAfter(tempo, pos), firstTickAtOrAfter(tempo, pos + n), 0, n,
                                            false};
            pos += n;
        } else {
            const SamplePos before = kLoopEnd - wrap;
            block.numSegments = 2;
            block.seg[0] = TransportSegment{before, firstTickAtOrAfter(tempo, before), 1920, 0, wrap, false};
            block.seg[1] = TransportSegment{kLoopStart, 960, firstTickAtOrAfter(tempo, kLoopStart + (n - wrap)), wrap,
                                            n - wrap, true};
            pos = kLoopStart + (n - wrap);
        }
        params.beginBlock();
        for (auto [i, v] : after) params.setAfterWrap(first + i, v);
        ProcessContext ctx{n, kRate, block, params};
        {
            RtScope scope;
            node->process(ctx, io);
            violations += scope.violations();
        }
        left.insert(left.end(), l.begin(), l.end());
        right.insert(right.end(), r.begin(), r.end());
    }

    ParamSlotTable params;
    ParamID first = 0;
    std::unique_ptr<NodeT> node;
    TempoMap tempo;
    SamplePos pos = 0;
    std::vector<float> left, right;
    uint64_t violations = 0;
    bool trapInstalled = false;
};

template <class NodeT>
auto plain() {
    return [](ParamID first) { return std::make_unique<NodeT>(first, NodeT::kNumParams); };
}

// The shared shape of the effect checks: `warm` frames of input at `a`, then a block of `n`
// frames wrapping at `wrap` with `b` after the wrap, then a block of `n` at `b` (automation
// writes the lane's value there). The reference runs the same input at `b` from its first block
// (every node jumps to its slots on its first block): from the start when the node's state
// doesn't depend on the params that change (`refFromWrap` false: a delay or reverb's lines
// don't depend on the mix), else from the wrap frame, where the node under test still has the
// zero state of an identity path. Before the wrap the output must pass `beforeWrap`; from the
// wrap on it must be the reference's bits.
template <class NodeT, class BeforeWrap>
void checkEffect(CheckResult& checks, const Params& a, const Params& b, uint32_t warm, bool refFromWrap,
                 BeforeWrap&& beforeWrap) {
    constexpr uint32_t kBlock = 512, kWrap = 200;
    const size_t total = size_t{warm} + 2 * kBlock;
    const std::vector<float> inL = noise(total, 1, 0.5f), inR = noise(total, 2, 0.5f);

    WrapRig<NodeT> rig(plain<NodeT>(), a);
    WrapRig<NodeT> ref(plain<NodeT>(), b);
    for (uint32_t done = 0; done < warm; done += kBlock) {
        rig.process(inL, inR, done, kBlock);
        if (!refFromWrap) ref.process(inL, inR, done, kBlock);
    }
    rig.process(inL, inR, warm, kBlock, kWrap, b);
    rig.apply(b);
    rig.process(inL, inR, warm + kBlock, kBlock);
    // The reference splits the wrap block at the wrap frame: the same frames at `b`, no ramp.
    if (refFromWrap) ref.left.assign(size_t{warm} + kWrap, 0.0f), ref.right.assign(size_t{warm} + kWrap, 0.0f);
    else ref.process(inL, inR, warm, kWrap);
    ref.process(inL, inR, warm + kWrap, kBlock - kWrap);
    ref.process(inL, inR, warm + kBlock, kBlock);

    bool before = true;
    for (uint32_t i = 0; i < kWrap; ++i) before = before && beforeWrap(rig, inL, inR, size_t{warm} + i);
    DAW_CHECK(before);
    // From the wrap frame on, and through the next block: the after-wrap values, nothing ramped.
    const size_t from = size_t{warm} + kWrap, n = 2 * kBlock - kWrap;
    DAW_CHECK(same(rig.left, from, ref.left, from, n));
    DAW_CHECK(same(rig.right, from, ref.right, from, n));
    DAW_CHECK(rig.violations == 0 && ref.violations == 0);
}

} // namespace

CheckResult wrapJumpEq() {
    CheckResult checks;
    // All bands at 0 dB are H(z) = 1 (bit for bit, zero state), so before the wrap the output is
    // the input; from the wrap on, an EQ with peak 1 at +12 dB from its first block.
    const Params a{}, b{{Eq::kPeak1Gain, 12.0f}};
    checkEffect<Eq>(checks, a, b, 1024, true, [](const auto& rig, const auto& inL, const auto& inR, size_t i) {
        return rig.left[i] == inL[i] && rig.right[i] == inR[i];
    });

    // A wrap block without a lane ramps the whole block, as before: the same bits as a plain
    // block with the same slot change.
    constexpr uint32_t kBlock = 512;
    const std::vector<float> inL = noise(2 * kBlock, 3, 0.5f), inR = noise(2 * kBlock, 4, 0.5f);
    WrapRig<Eq> wrapped(plain<Eq>()), straight(plain<Eq>());
    wrapped.process(inL, inR, 0, kBlock);
    straight.process(inL, inR, 0, kBlock);
    wrapped.apply({{Eq::kPeak1Gain, 12.0f}});
    straight.apply({{Eq::kPeak1Gain, 12.0f}});
    wrapped.process(inL, inR, kBlock, kBlock, 200);
    straight.process(inL, inR, kBlock, kBlock);
    DAW_CHECK(same(wrapped.left, 0, straight.left, 0, 2 * kBlock));
    DAW_CHECK(same(wrapped.right, 0, straight.right, 0, 2 * kBlock));
    // A lane on another node's slot (beyond this EQ's params) doesn't make it jump.
    WrapRig<Eq> other(plain<Eq>());
    other.process(inL, inR, 0, kBlock);
    other.apply({{Eq::kPeak1Gain, 12.0f}});
    other.process(inL, inR, kBlock, kBlock, 200, {{Eq::kNumParams, 0.5f}});
    DAW_CHECK(same(other.left, 0, straight.left, 0, 2 * kBlock));
    DAW_CHECK(wrapped.violations == 0 && straight.violations == 0 && other.violations == 0);
    return checks;
}

CheckResult wrapJumpCompressor() {
    CheckResult checks;
    // Threshold 0 dB with a 6 dB knee: the ±0.5 input (≤ −6 dBFS) is below the knee (−3 dB), so
    // before the wrap the gain is exactly 1 and the envelope rests at 0. From the wrap on it
    // compresses at −40 dB with +12 dB makeup, as a compressor at those values from its first
    // block (whose envelope also starts at 0).
    const Params a{{Compressor::kThreshold, 0.0f}, {Compressor::kMakeup, 0.0f}};
    const Params b{{Compressor::kThreshold, -40.0f}, {Compressor::kMakeup, 12.0f}};
    checkEffect<Compressor>(checks, a, b, 1024, true, [](const auto& rig, const auto& inL, const auto& inR, size_t i) {
        return rig.left[i] == inL[i] && rig.right[i] == inR[i];
    });
    return checks;
}

CheckResult wrapJumpDelay() {
    CheckResult checks;
    // A 2 ms delay (96 frames, so echoes sound inside the blocks). Mix 0 is the dry signal; the
    // lines don't depend on the mix, so from the wrap on the output is a mix-1 delay's echoes.
    const Params a{{Delay::kSync, 0.0f}, {Delay::kTime, 2.0f}, {Delay::kMix, 0.0f}};
    const Params b{{Delay::kSync, 0.0f}, {Delay::kTime, 2.0f}, {Delay::kMix, 1.0f}};
    checkEffect<Delay>(checks, a, b, 1024, false, [](const auto& rig, const auto& inL, const auto& inR, size_t i) {
        return rig.left[i] == inL[i] && rig.right[i] == inR[i];
    });
    return checks;
}

CheckResult wrapJumpReverb() {
    CheckResult checks;
    // Mix 0 → 1; the network doesn't depend on the mix. 4096 frames of warm-up, so the tail
    // (≥ 10 ms pre-delay + ~29 ms shortest line at size 0.5) is in the wet signal at the wrap.
    const Params a{{Reverb::kMix, 0.0f}}, b{{Reverb::kMix, 1.0f}};
    checkEffect<Reverb>(checks, a, b, 4096, false, [](const auto& rig, const auto& inL, const auto& inR, size_t i) {
        return rig.left[i] == inL[i] && rig.right[i] == inR[i];
    });
    return checks;
}

CheckResult wrapJumpSampler() {
    CheckResult checks;
    // A note at the wrap frame (the loop start's note) starts with the after-wrap attack: 0.5 s
    // instead of the 2 ms before it. The reference is a sampler at 0.5 s playing the note at
    // frame 0 of its first block.
    const AudioAssetRef asset = testing::nodes::makeAsset(5, 1, 48'000, [](uint32_t, int64_t i) {
        return static_cast<float>(std::sin(0.05 * static_cast<double>(i)));
    });
    DAW_CHECK(asset);
    if (!asset) return checks;
    auto make = [&asset](ParamID first) {
        Sampler::Zone z;
        z.assetID = 5;
        z.rootKey = 60;
        z.asset = asset;
        return std::make_unique<Sampler>(std::vector<Sampler::Zone>{z}, first, Sampler::kNumParams);
    };
    constexpr uint32_t kBlock = 512, kWrap = 200;
    const MidiEvent on{kWrap, 3, {0x90, 60, 100}};
    const MidiEvent onAt0{0, 3, {0x90, 60, 100}};
    WrapRig<Sampler> rig(make, {{Sampler::kAttack, 0.002f}});
    WrapRig<Sampler> ref(make, {{Sampler::kAttack, 0.5f}});
    rig.process({}, {}, 0, kBlock, kWrap, {{Sampler::kAttack, 0.5f}}, {on});
    rig.apply({{Sampler::kAttack, 0.5f}});
    rig.process({}, {}, 0, kBlock);
    ref.process({}, {}, 0, kBlock - kWrap, 0, {}, {onAt0});
    ref.process({}, {}, 0, kBlock);

    bool silentBefore = true;
    for (uint32_t i = 0; i < kWrap; ++i) silentBefore = silentBefore && rig.left[i] == 0.0f && rig.right[i] == 0.0f;
    DAW_CHECK(silentBefore);
    const size_t n = 2 * kBlock - kWrap;
    DAW_CHECK(same(rig.left, kWrap, ref.left, 0, n));
    DAW_CHECK(same(rig.right, kWrap, ref.right, 0, n));
    // Not the 2 ms attack: that is at full level after 96 frames; the 0.5 s one is ~1 % after 300.
    float peak = 0.0f;
    for (size_t i = kWrap; i < kWrap + 300; ++i) peak = std::fmax(peak, std::fabs(rig.left[i]));
    DAW_CHECK(peak > 0.0f && peak < 0.05f);
    DAW_CHECK(rig.violations == 0 && ref.violations == 0);
    return checks;
}

CheckResult wrapJumpMetronome() {
    CheckResult checks;
    // The loop starts on beat 2 (tick 960). Its click latches the after-wrap level 1, not the 0.25
    // before the wrap: the reference is a metronome at level 1 playing from the loop start.
    constexpr uint32_t kBlock = 512, kWrap = 200;
    WrapRig<Metronome> rig(plain<Metronome>(), {{Metronome::kLevel, 0.25f}});
    WrapRig<Metronome> ref(plain<Metronome>(), {{Metronome::kLevel, 1.0f}});
    rig.pos = kLoopEnd - 2 * kBlock;
    rig.process({}, {}, 0, kBlock);  // a click-free stretch before the wrap (beat 1920 is at 48 000)
    rig.process({}, {}, 0, kBlock, kWrap, {{Metronome::kLevel, 1.0f}});
    rig.apply({{Metronome::kLevel, 1.0f}});
    rig.process({}, {}, 0, kBlock);
    ref.pos = kLoopStart;
    ref.process({}, {}, 0, kBlock - kWrap);
    ref.process({}, {}, 0, kBlock);

    bool silentBefore = true;
    for (uint32_t i = 0; i < kBlock + kWrap; ++i) silentBefore = silentBefore && rig.left[i] == 0.0f;
    DAW_CHECK(silentBefore);
    DAW_CHECK(rig.left.size() == 3 * kBlock && rig.left[kBlock + kWrap] == 1.0f);  // the click's first sample is its amp
    const size_t n = 2 * kBlock - kWrap;
    DAW_CHECK(same(rig.left, kBlock + kWrap, ref.left, 0, n));
    DAW_CHECK(same(rig.right, kBlock + kWrap, ref.right, 0, n));
    DAW_CHECK(rig.violations == 0 && ref.violations == 0);
    return checks;
}

} // namespace daw::testing
