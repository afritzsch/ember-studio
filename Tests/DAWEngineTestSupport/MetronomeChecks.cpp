// T-024 checks for the metronome (TIME-010, DSP-011). Run from
// Tests/DAWEngineTests/MetronomeTests.swift; see MetronomeChecks.h for why they're C++.

#include "MetronomeChecks.h"

#include <cmath>
#include <cstdint>
#include <limits>
#include <numbers>
#include <random>
#include <utility>
#include <vector>

#include "NodeTestHarness.h"
#include "TestNodes.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/ProcessContext.h"
#include "core/RtTrap.h"
#include "nodes/Metronome.h"
#include "time/TempoMap.h"

using namespace daw;
using namespace daw::testing::nodes;

namespace daw::testing {

namespace {

constexpr NodeID kMetronomeID = 10;
constexpr float kBeatAmp = 0.25f;   // default level
constexpr float kAccentAmp = 0.5f;  // default level · default accent
constexpr int64_t kNever = std::numeric_limits<int64_t>::max();

struct Sig {
    Tick tick;
    int32_t num, den;
};

// Independent of Metronome's own beat search: walks each signature's bars from its event
// to the next event (03: an event starts a new bar, cutting the bar before it short).
std::vector<std::pair<Tick, bool>> beatGrid(const std::vector<Sig>& sigs, Tick to) {
    std::vector<std::pair<Tick, bool>> beats;
    for (size_t i = 0; i < sigs.size(); ++i) {
        const Tick end = i + 1 < sigs.size() ? sigs[i + 1].tick : to;
        const Tick beat = Tick{kPPQ} * 4 / sigs[i].den;
        const Tick bar = beat * sigs[i].num;
        for (Tick t = sigs[i].tick; t < end && t < to; t += beat) beats.push_back({t, (t - sigs[i].tick) % bar == 0});
    }
    return beats;
}

struct Click {
    int64_t frame;
    bool accent;
    float amp;
    int64_t cutAt = kNever;  // the frame its 64-frame fade-out starts (locate, stop)
};

// The expected output: each click's shape scaled by its amp, faded from cutAt as Metronome does.
std::vector<float> synth(const std::vector<Click>& clicks, size_t total, const Metronome& shapes) {
    std::vector<float> out(total, 0.0f);
    constexpr float kRamp = 1.0f / static_cast<float>(Metronome::kFadeFrames);
    for (const Click& c : clicks) {
        const auto shape = c.accent ? shapes.accentClick() : shapes.beatClick();
        for (size_t k = 0; k < shape.size(); ++k) {
            const int64_t f = c.frame + static_cast<int64_t>(k);
            if (f < 0 || f >= static_cast<int64_t>(total)) continue;
            float s = c.amp * shape[k];
            if (f >= c.cutAt) {
                const int64_t j = f - c.cutAt;
                if (j >= static_cast<int64_t>(Metronome::kFadeFrames)) break;
                s *= static_cast<float>(static_cast<int64_t>(Metronome::kFadeFrames) - 1 - j) * kRamp;
            }
            out[static_cast<size_t>(f)] += s;
        }
    }
    return out;
}

double maxDiff(const std::vector<float>& a, const std::vector<float>& b) {
    if (a.size() != b.size()) return 1e9;
    double m = 0;
    for (size_t i = 0; i < a.size(); ++i) m = std::max(m, std::fabs(double{a[i]} - double{b[i]}));
    return m;
}

// The unit click shapes at the harness rate.
const Metronome& shapes() {
    static const Metronome m = [] {
        Metronome node(0, 0);
        node.prepare(PrepareInfo{kRate, kMaxBlock, 0, 2});
        return node;
    }();
    return m;
}

TempoMap makeMap(const GraphDescription& d) {
    TempoEventList tempos;
    TimeSigEventList sigs;
    for (const auto& t : d.tempo.tempos) tempos.push_back({t.tick, t.bpm});
    for (const auto& s : d.tempo.timeSigs) sigs.push_back({s.tick, s.num, s.den});
    return std::move(TempoMap::make(tempos, sigs, kRate)).value();
}

// master ← metronome (params [firstParam, firstParam + numParams)).
GraphDescription metronomeGraph(ParamID firstParam = 0, uint32_t numParams = 0) {
    GraphDescription d = baseDescription();
    d.nodes.push_back(NodeDesc{kMetronomeID, NodeKind::metronome, 1, firstParam, numParams, {}});
    d.edges.push_back(EdgeDesc{1, kMetronomeID, 1, EdgeKind::audio, 0});
    return d;
}

// Drives a Metronome directly with hand-made one-segment blocks.
struct DirectRig {
    explicit DirectRig(uint32_t numParams, uint32_t channels = 2) : params(4), node(0, numParams), channels(channels) {
        trapInstalled = RtTrap::install();  // no Engine here to install it (ENG-030)
        (void)params.allocate(Metronome::kNumParams, 0.0f);
        node.prepare(PrepareInfo{kRate, kMaxBlock, 0, channels});
    }

    // Plays samples [pos, pos + n) (stopped if !playing) and appends the output.
    void process(uint32_t n, bool playing = true) {
        std::vector<float> l(n, -99.0f), r(n, -99.0f);
        float* out[2] = {l.data(), r.data()};
        NodeIO io;
        io.audioOut = AudioBufferView{out, channels, n};
        TransportBlock block{playing, false, 0, {}, &tempo};
        block.seg[0] = TransportSegment{pos, firstTickAtOrAfter(tempo, pos), firstTickAtOrAfter(tempo, pos + n), 0, n,
                                        false};
        if (playing && n > 0) block.numSegments = 1;
        ProcessContext ctx{n, kRate, block, params};
        {
            RtScope scope;
            node.process(ctx, io);
            violations += scope.violations();
        }
        if (playing) pos += n;
        left.insert(left.end(), l.begin(), l.end());
        right.insert(right.end(), r.begin(), r.end());
    }
    void reset() {
        RtScope scope;
        node.reset();
        violations += scope.violations();
    }

    ParamSlotTable params;
    Metronome node;
    uint32_t channels;
    TempoMap tempo;  // 120 bpm 4/4: a beat every 24000 samples
    SamplePos pos = 0;
    std::vector<float> left, right;
    uint64_t violations = 0;
    bool trapInstalled = false;
};

} // namespace

CheckResult metronomeNodeBasics() {
    CheckResult checks;
    DAW_CHECK(Metronome::kNumParams == 3);
    for (uint32_t i = 0; i < Metronome::kNumParams; ++i) DAW_CHECK(Metronome::kParamInfo[i].index == i);
    DAW_CHECK(Metronome::kParamInfo[Metronome::kOn].def == 1.0f);
    DAW_CHECK(Metronome::kParamInfo[Metronome::kLevel].def == kBeatAmp);
    DAW_CHECK(Metronome::kParamInfo[Metronome::kLevel].def * Metronome::kParamInfo[Metronome::kAccent].def == kAccentAmp);

    // The click shapes: 20 ms, amp · (1 − k/N)³ · cos(2π f k / rate), first sample exactly 1.
    const auto beat = shapes().beatClick();
    const auto accent = shapes().accentClick();
    DAW_CHECK(beat.size() == 960 && accent.size() == 960);
    DAW_CHECK(beat[0] == 1.0f && accent[0] == 1.0f);
    for (size_t k = 0; k < beat.size(); ++k) {
        const double env = std::pow(1.0 - static_cast<double>(k) / 960.0, 3.0);
        DAW_CHECK(std::fabs(beat[k] - env * std::cos(2 * std::numbers::pi * 1000.0 * static_cast<double>(k) / kRate)) < 1e-6);
        DAW_CHECK(std::fabs(accent[k] - env * std::cos(2 * std::numbers::pi * 1500.0 * static_cast<double>(k) / kRate)) < 1e-6);
    }
    // No discontinuity at the end: the last sample is next to 0.
    DAW_CHECK(std::fabs(beat.back()) < 1e-8 && std::fabs(accent.back()) < 1e-8);

    {
        // numParams 0: defaults (on, 0.25, ×2); tick 0 is a downbeat; the slots aren't read.
        DirectRig rig(0);
        DAW_CHECK(rig.trapInstalled);
        rig.params.set(Metronome::kOn, 0.0f);
        rig.process(0);  // ENG-004: a 0-frame block changes nothing
        rig.process(500);
        rig.process(23500);
        rig.process(1000);
        const auto want = synth({{0, true, kAccentAmp}, {24000, false, kBeatAmp}}, rig.left.size(), shapes());
        DAW_CHECK(maxDiff(rig.left, want) <= 1e-7);
        DAW_CHECK(rig.left == rig.right);
        DAW_CHECK(rig.left[0] == kAccentAmp && rig.left[24000] == kBeatAmp && rig.left[23999] == 0.0f);
        DAW_CHECK(rig.violations == 0);
    }
    {
        // Clamping: level 10 → +12 dB, accent −1 → 0 (a silent downbeat). NaN level → silence.
        DirectRig rig(Metronome::kNumParams, 1);  // mono output
        rig.params.set(Metronome::kOn, 1.0f);
        rig.params.set(Metronome::kLevel, 10.0f);
        rig.params.set(Metronome::kAccent, -1.0f);
        rig.process(24010);
        DAW_CHECK(rig.left[0] == 0.0f);
        DAW_CHECK(rig.left[24000] == Metronome::kMaxLevel);
        rig.params.set(Metronome::kLevel, std::numeric_limits<float>::quiet_NaN());
        rig.process(48000);
        float peak = 0;
        for (size_t i = 24960; i < rig.left.size(); ++i) peak = std::max(peak, std::fabs(rig.left[i]));
        DAW_CHECK(peak == 0.0f);
        rig.params.set(Metronome::kLevel, 1.0f);
        rig.params.set(Metronome::kOn, std::numeric_limits<float>::quiet_NaN());  // NaN is off
        rig.process(48000);
        for (size_t i = 72010; i < rig.left.size(); ++i) peak = std::max(peak, std::fabs(rig.left[i]));
        DAW_CHECK(peak == 0.0f);
        DAW_CHECK(rig.violations == 0);
    }
    {
        // TIME-008: reset() (a locate) fades the click in progress over 64 frames even when the
        // next segment continues the samples.
        DirectRig rig(0);
        rig.process(300);
        rig.reset();
        rig.process(300);
        Click c{0, true, kAccentAmp, 300};
        DAW_CHECK(maxDiff(rig.left, synth({c}, rig.left.size(), shapes())) <= 1e-7);
        DAW_CHECK(rig.left[300] != 0.0f && rig.left[363] == 0.0f);
        DAW_CHECK(rig.violations == 0);
    }
    return checks;
}

CheckResult metronomeClicksOnTempoMap() {
    CheckResult checks;
    // 3/4 for two bars, then 4/4 one beat into bar 3 (cut short), then 6/8 (480-tick beats).
    // Tempo changes off the beat grid, one at a tempo with fractional samples per tick.
    const std::vector<Sig> sigs{{0, 3, 4}, {6720, 4, 4}, {14400, 6, 8}};
    GraphDescription d = metronomeGraph();
    d.tempo.tempos = {{0, 120.0}, {4000, 90.0}, {9000, 173.5}, {15000, 60.0}};
    d.tempo.timeSigs.clear();
    for (const Sig& s : sigs) d.tempo.timeSigs.push_back({s.tick, s.num, s.den});
    const TempoMap map = makeMap(d);

    constexpr Tick kEnd = 20000;
    const auto total = static_cast<size_t>(map.tickToSample(kEnd));
    std::vector<Click> clicks;
    for (const auto& [tick, accent] : beatGrid(sigs, kEnd))
        clicks.push_back({map.tickToSample(tick), accent, accent ? kAccentAmp : kBeatAmp});
    // The grid as the spec describes it: downbeats at 0, 2880, 5760 (3/4), 6720 (the cut bar's
    // signature event), 10560 (4/4), 14400, 17280 (6/8).
    std::vector<Tick> downbeats;
    for (const auto& [tick, accent] : beatGrid(sigs, kEnd))
        if (accent) downbeats.push_back(tick);
    DAW_CHECK((downbeats == std::vector<Tick>{0, 2880, 5760, 6720, 10560, 14400, 17280}));
    const auto want = synth(clicks, total, shapes());

    for (uint32_t seed = 1; seed <= 3; ++seed) {
        Rig rig;
        DAW_CHECK(rig.publish(d));
        DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
        std::mt19937 rng(seed);
        std::uniform_int_distribution<uint32_t> size(0, 1024);
        rig.renderFrames(static_cast<int64_t>(total), [&] { return size(rng); });
        DAW_CHECK(maxDiff(rig.left(), want) <= 1e-6);
        DAW_CHECK(rig.left() == rig.right());
        // Sample-exact onsets: silence right before each click, its full amp on its sample.
        for (const Click& c : clicks) {
            const auto f = static_cast<size_t>(c.frame);
            DAW_CHECK(rig.left()[f] == c.amp);
            DAW_CHECK(f == 0 || rig.left()[f - 1] == 0.0f);
        }
        // And nothing else starts: every rise from silence is one of them.
        size_t onsets = 0;
        for (size_t i = 0; i < rig.left().size(); ++i)
            if (rig.left()[i] != 0.0f && (i == 0 || rig.left()[i - 1] == 0.0f)) ++onsets;
        DAW_CHECK(onsets == clicks.size());
        DAW_CHECK(rig.violations() == 0);
    }
    return checks;
}

CheckResult metronomeLoopWrap() {
    CheckResult checks;
    struct Case {
        Tick start, end;
    };
    // [480, 1930): beats 960 and 1920; the 1920 click is 250 samples from the loop end and rings
    // across the wrap. [2880, 3860): starts on a beat (a click on every wrap frame) while the
    // downbeat 3840 rings over it.
    for (const Case loop : {Case{480, 1930}, Case{2880, 3860}}) {
        GraphDescription d = metronomeGraph();
        const TempoMap map = makeMap(d);
        const SamplePos s = map.tickToSample(loop.start);
        const SamplePos e = map.tickToSample(loop.end);
        const int64_t length = e - s;
        constexpr int passes = 5;
        const auto total = static_cast<size_t>(length * passes);
        std::vector<Click> clicks;
        for (int k = 0; k < passes; ++k)
            for (const auto& [tick, accent] : beatGrid({{0, 4, 4}}, loop.end))
                if (tick >= loop.start)
                    clicks.push_back({k * length + map.tickToSample(tick) - s, accent, accent ? kAccentAmp : kBeatAmp});
        const auto want = synth(clicks, total, shapes());

        for (uint32_t variant = 0; variant < 3; ++variant) {
            Rig rig;
            DAW_CHECK(rig.publish(d));
            DAW_CHECK(rig.transport().setLoop(true, loop.start, loop.end) && rig.transport().locate(loop.start) &&
                      rig.transport().play());
            std::mt19937 rng(variant);
            std::uniform_int_distribution<uint32_t> size(0, 2048);
            // Fixed 777 (wraps mid-block), then random sizes.
            rig.renderFrames(static_cast<int64_t>(total), [&] { return variant == 0 ? 777u : size(rng); });
            DAW_CHECK(maxDiff(rig.left(), want) <= 1e-6);
            DAW_CHECK(rig.left() == rig.right());
            DAW_CHECK(rig.violations() == 0);
        }
        // The wrap frames: on a beat, the loop start's click starts there over the ringing one.
        if (loop.start == 2880) {
            const float wrap = want[static_cast<size_t>(length)];
            DAW_CHECK(wrap != kBeatAmp && std::fabs(wrap - kBeatAmp) < 0.1f);
        }
    }
    return checks;
}

CheckResult metronomeSwitchAndLevels() {
    CheckResult checks;
    Rig rig;
    ParamSlotTable& params = rig.engine().params();
    auto first = params.allocate(Metronome::kNumParams, 0.0f);
    DAW_CHECK(first.ok());
    if (!first.ok()) return checks;
    const ParamID p = first.value();
    params.set(p + Metronome::kOn, 1.0f);
    params.set(p + Metronome::kLevel, 0.25f);
    params.set(p + Metronome::kAccent, 2.0f);
    DAW_CHECK(rig.publish(metronomeGraph(p, Metronome::kNumParams)));
    DAW_CHECK(rig.transport().locate(0) && rig.transport().play());

    // 120 bpm 4/4: beats every 24000 samples, downbeats every 96000.
    std::vector<Click> clicks{{0, true, 0.5f}, {24000, false, 0.25f}};
    rig.renderFrames(24300, [] { return 128u; });
    params.set(p + Metronome::kOn, 0.0f);  // inside the 24000 click: it plays to its end
    rig.renderFrames(72500 - 24300, [] { return 128u; });
    params.set(p + Metronome::kLevel, 0.1f);
    params.set(p + Metronome::kOn, 1.0f);  // between beats: the next one (96000, bar 2) clicks
    clicks.push_back({96000, true, 0.2f});
    rig.renderFrames(96100 - 72500, [] { return 100u; });
    params.set(p + Metronome::kLevel, 0.4f);  // inside a click: it keeps 0.2
    params.set(p + Metronome::kAccent, 1.0f);
    clicks.push_back({120000, false, 0.4f});
    clicks.push_back({144000, false, 0.4f});
    rig.renderFrames(150000 - 96100, [] { return 333u; });

    DAW_CHECK(maxDiff(rig.left(), synth(clicks, rig.left().size(), shapes())) <= 1e-6);
    DAW_CHECK(rig.left()[96000] == 0.2f && rig.left()[120000] == 0.4f);
    DAW_CHECK(rig.violations() == 0);
    return checks;
}

CheckResult metronomeLocateAndStop() {
    CheckResult checks;
    const auto run = [&](Tick to, std::vector<Click> afterLocate) {
        Rig rig;
        DAW_CHECK(rig.publish(metronomeGraph()));
        DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
        rig.renderFrames(24200, [] { return 100u; });  // 200 frames into the beat-2 click
        DAW_CHECK(rig.transport().locate(to));
        rig.renderFrames(1000, [] { return 300u; });
        DAW_CHECK(rig.transport().stop());
        rig.renderFrames(30000, [] { return 256u; });  // stopped: no clicks
        std::vector<Click> clicks{{0, true, kAccentAmp}, {24000, false, kBeatAmp, 24200}};
        for (Click c : afterLocate) {
            c.frame += 24200;
            c.cutAt = 25200;  // stop cuts it with the same fade
            clicks.push_back(c);
        }
        const auto want = synth(clicks, rig.left().size(), shapes());
        DAW_CHECK(maxDiff(rig.left(), want) <= 1e-6);
        // Cut cleanly: the old click goes on at 63/64 on the locate frame, gone after 64.
        DAW_CHECK(std::fabs(rig.left()[24200] - want[24200]) <= 1e-7);
        for (size_t i = 25200 + Metronome::kFadeFrames; i < rig.left().size(); ++i)
            if (rig.left()[i] != 0.0f) {
                DAW_CHECK(rig.left()[i] == 0.0f);
                break;
            }
        DAW_CHECK(rig.violations() == 0);
    };
    // Tick 1910 is 250 samples before beat 3 (tick 1920).
    run(1910, {{250, false, kBeatAmp}});
    // Onto a downbeat: it clicks on the locate frame, over the old click's fade.
    run(3840, {{0, true, kAccentAmp}});
    return checks;
}

CheckResult metronomeWithGraphLatency() {
    CheckResult checks;
    constexpr uint32_t kLatency = 2048;
    Rig rig([](NodeRegistry& registry) {
        (void)registry.set(NodeKind::delay, {[](const NodeCreateInfo&) -> Result<std::unique_ptr<Node>> {
                               return std::unique_ptr<Node>(new FakeLatencyNode(kLatency));
                           }});
    });
    GraphDescription d = baseDescription();
    d.nodes.push_back(NodeDesc{kMetronomeID, NodeKind::metronome, 1, 0, 0, {}});
    d.nodes.push_back(NodeDesc{20, NodeKind::delay, 1, 0, 0, {}});
    d.edges.push_back(EdgeDesc{1, kMetronomeID, 20, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{2, 20, 1, EdgeKind::audio, 0});
    DAW_CHECK(rig.publish(d));
    DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
    rig.renderFrames(100000, [] { return 512u; });
    const auto want = synth({{0, true, kAccentAmp}, {24000, false, kBeatAmp}, {48000, false, kBeatAmp},
                             {72000, false, kBeatAmp}, {96000, true, kAccentAmp}},
                            rig.left().size(), shapes());
    DAW_CHECK(maxDiff(rig.left(), want) <= 1e-6);
    DAW_CHECK(rig.left()[0] == kAccentAmp && rig.left()[24000] == kBeatAmp);
    DAW_CHECK(rig.violations() == 0);
    return checks;
}

} // namespace daw::testing
