// T-013 checks for the AudioClipPlayer. Run from Tests/DAWEngineTests/ClipPlayerTests.swift; see
// ClipPlayerChecks.h for why they're C++.

#include "ClipPlayerChecks.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <iterator>
#include <map>
#include <random>
#include <vector>

#include "NodeTestHarness.h"
#include "nodes/AudioClipPlayer.h"
#include "time/TempoMap.h"

using namespace daw;
using namespace daw::testing::nodes;

namespace daw::testing {

namespace {

constexpr NodeID kPlayer = 10;

// player → master.
GraphDescription playerGraph(std::vector<ClipDesc> clips, uint32_t configVersion = 1) {
    GraphDescription d = baseDescription();
    d.nodes.push_back(NodeDesc{kPlayer, NodeKind::audioClipPlayer, configVersion, 0, 0, {}});
    d.edges.push_back(EdgeDesc{1, kPlayer, 1, EdgeKind::audio, 0});
    d.audioClips = std::move(clips);
    return d;
}

TempoMap tempoOf(const GraphDescription& d) {
    TempoEventList tempos;
    for (const auto& t : d.tempo.tempos) tempos.push_back({t.tick, t.bpm});
    TimeSigEventList sigs;
    for (const auto& s : d.tempo.timeSigs) sigs.push_back({s.tick, s.num, s.den});
    return std::move(TempoMap::make(tempos, sigs, kRate)).value();
}

// The brute-force reference for DSP-001: every clip at every sample, in double. Clip positions
// are converted once up front, so the per-sample loop is cheap even in Debug.
class Oracle {
public:
    Oracle(const TempoMap& tempo, const std::vector<ClipDesc>& clips,
           const std::map<uint64_t, AudioAssetRef>& assets) {
        for (const ClipDesc& c : clips) {
            auto it = assets.find(c.assetID);
            if (c.length <= 0 || it == assets.end() || !it->second) continue;
            Placed p;
            p.asset = &*it->second;
            p.cs = tempo.tickToSample(c.start);
            p.ce = tempo.tickToSample(c.start + c.length);
            p.fi = tempo.tickToSample(c.start + std::clamp<Tick>(c.fadeIn, 0, c.length)) - p.cs;
            p.fo = p.ce - tempo.tickToSample(c.start + c.length - std::clamp<Tick>(c.fadeOut, 0, c.length));
            p.offset = c.sourceOffsetSamples;
            p.gain = c.gain;
            placed_.push_back(p);
        }
    }

    double operator()(SamplePos s, uint32_t channel) const {
        double sum = 0.0;
        for (const Placed& p : placed_) {
            if (s < p.cs || s >= p.ce) continue;
            const SamplePos src = p.offset + (s - p.cs);
            if (src < 0 || src >= p.asset->frames) continue;
            double g = p.gain;
            if (s - p.cs < p.fi) g *= double(s - p.cs) / double(p.fi);
            if (p.ce - 1 - s < p.fo) g *= double(p.ce - 1 - s) / double(p.fo);
            sum += g * p.asset->data[p.asset->channels > 1 ? channel : 0][src];
        }
        return sum;
    }

private:
    struct Placed {
        const AudioAsset* asset;
        SamplePos cs, ce, fi, fo;
        int64_t offset;
        double gain;
    };
    std::vector<Placed> placed_;
};

bool near(double a, double b, double tol = 1e-6) { return std::fabs(a - b) <= tol; }

uint32_t fixedBlock() { return 256; }

} // namespace

CheckResult clipPlayerPlacesClips() {
    CheckResult checks;
    Rig rig;
    // Stereo: L = i/1e4, R = −i/1e4; mono: 0.25 + i/1e5.
    rig.addAsset(makeAsset(7, 2, 5000, [](uint32_t c, int64_t i) { return (c == 0 ? 1.0f : -1.0f) * float(i) / 1e4f; }));
    rig.addAsset(makeAsset(8, 1, 5000, [](uint32_t, int64_t i) { return 0.25f + float(i) / 1e5f; }));
    const AudioAsset& stereo = *rig.asset(7);
    const AudioAsset& mono = *rig.asset(8);

    // Stereo clip at tick 40 (sample 1000) for 80 ticks (2000 samples), from source frame 100,
    // gain 0.5. Mono clip at tick 200 (sample 5000), 40 ticks, source offset 4500: only 500
    // source frames are left, so it goes silent half-way (sample 5500).
    DAW_CHECK(rig.publish(playerGraph({clip(kPlayer, 1, 40, 80, 7, 100, 0.5f),
                                       clip(kPlayer, 2, 200, 40, 8, 4500, 1.0f)})));
    DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
    rig.renderFrames(7000, fixedBlock);
    const auto& L = rig.left();
    const auto& R = rig.right();
    DAW_CHECK(L.size() == 7000);

    DAW_CHECK(L[999] == 0.0f && R[999] == 0.0f);
    DAW_CHECK(L[1000] == 0.5f * stereo.data[0][100] && R[1000] == 0.5f * stereo.data[1][100]);
    DAW_CHECK(L[1001] == 0.5f * stereo.data[0][101]);
    DAW_CHECK(L[2999] == 0.5f * stereo.data[0][2099] && R[2999] == 0.5f * stereo.data[1][2099]);
    DAW_CHECK(L[3000] == 0.0f && R[3000] == 0.0f);
    bool exact = true;
    for (int64_t s = 0; s < 7000; ++s) {
        float l = 0, r = 0;
        if (s >= 1000 && s < 3000) {
            l = 0.5f * stereo.data[0][s - 1000 + 100];
            r = 0.5f * stereo.data[1][s - 1000 + 100];
        } else if (s >= 5000 && s < 5500) {
            l = r = mono.data[0][s - 5000 + 4500];  // mono → L/R
        }
        exact = exact && L[s] == l && R[s] == r;
    }
    DAW_CHECK(exact);
    DAW_CHECK(rig.violations() == 0);
    return checks;
}

CheckResult clipPlayerFades() {
    CheckResult checks;
    Rig rig;
    rig.addAsset(makeAsset(1, 1, 20000, [](uint32_t, int64_t) { return 1.0f; }));

    // A: ticks 0..80 (samples 0..2000), fade in 4 ticks (100), out 8 ticks (200).
    // B: ticks 80..160 (2000..4000), fade in 8 (200), out 4 (100), gain 0.5.
    // C: ticks 200..208 (5000..5200), fades of 6 and 100 ticks: the fade-out is clamped to the
    //    clip (8 ticks = 200 samples) and both apply where they overlap.
    DAW_CHECK(rig.publish(playerGraph({clip(kPlayer, 1, 0, 80, 1, 0, 1.0f, 4, 8),
                                       clip(kPlayer, 2, 80, 80, 1, 0, 0.5f, 8, 4),
                                       clip(kPlayer, 3, 200, 8, 1, 0, 1.0f, 6, 100)})));
    DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
    rig.renderFrames(6000, [] { return 333u; });
    const auto& L = rig.left();
    const auto& R = rig.right();

    bool ok = true;
    for (int k = 0; k < 100; ++k) ok = ok && near(L[k], k / 100.0);                 // A in
    for (int s = 100; s < 1800; ++s) ok = ok && L[s] == 1.0f;                          // A body
    for (int j = 0; j < 200; ++j) ok = ok && near(L[1999 - j], j / 200.0);            // A out
    for (int k = 0; k < 200; ++k) ok = ok && near(L[2000 + k], 0.5 * k / 200.0);      // B in
    for (int s = 2200; s < 3900; ++s) ok = ok && L[s] == 0.5f;                         // B body
    for (int j = 0; j < 100; ++j) ok = ok && near(L[3999 - j], 0.5 * j / 100.0);      // B out
    for (int s = 4000; s < 5000; ++s) ok = ok && L[s] == 0.0f;
    for (int k = 0; k < 200; ++k)                                                      // C: both
        ok = ok && near(L[5000 + k], (k < 150 ? k / 150.0 : 1.0) * ((199 - k) / 200.0));
    for (int s = 5200; s < 6000; ++s) ok = ok && L[s] == 0.0f;
    for (size_t s = 0; s < L.size(); ++s) ok = ok && L[s] == R[s];
    DAW_CHECK(ok);
    DAW_CHECK(L[0] == 0.0f && L[1999] == 0.0f && L[2000] == 0.0f && L[3999] == 0.0f);
    DAW_CHECK(rig.violations() == 0);
    return checks;
}

CheckResult clipPlayerMatchesOracle() {
    CheckResult checks;
    for (uint32_t seed = 1; seed <= 4; ++seed) {
        std::mt19937 rng(seed);
        Rig rig;
        std::uniform_real_distribution<float> noise(-1.0f, 1.0f);
        rig.addAsset(makeAsset(1, 2, 60000, [&](uint32_t, int64_t) { return noise(rng); }));
        rig.addAsset(makeAsset(2, 1, 40000, [&](uint32_t, int64_t) { return noise(rng); }));
        rig.addAsset(makeAsset(3, 2, 500, [&](uint32_t, int64_t) { return noise(rng); }));
        std::map<uint64_t, AudioAssetRef> assets{{1, rig.asset(1)}, {2, rig.asset(2)}, {3, rig.asset(3)}};

        std::vector<ClipDesc> clips;
        std::uniform_int_distribution<int> clipCount(1, 60);
        const int n = clipCount(rng);
        for (int i = 0; i < n; ++i) {
            const Tick start = std::uniform_int_distribution<Tick>(0, 960 * 12)(rng);
            const Tick length = std::uniform_int_distribution<Tick>(-5, 960 * 2)(rng);
            const uint64_t asset = std::uniform_int_distribution<uint64_t>(1, 4)(rng);  // 4: missing
            const int64_t offset = std::uniform_int_distribution<int64_t>(-3000, 30000)(rng);
            const float gain = std::uniform_real_distribution<float>(0.0f, 1.5f)(rng);
            const Tick fadeIn = std::uniform_int_distribution<Tick>(0, 400)(rng);
            const Tick fadeOut = std::uniform_int_distribution<Tick>(0, 400)(rng);
            clips.push_back(clip(kPlayer, uint64_t(i + 1), start, length, asset, offset, gain, fadeIn, fadeOut));
        }
        GraphDescription d = playerGraph(clips);
        d.tempo.tempos = {{0, 120.0}, {960 * 3 + 17, 91.5}, {960 * 6, 173.0}, {960 * 9 + 480, 64.25}};
        const TempoMap tempo = tempoOf(d);
        DAW_CHECK(rig.publish(d));
        DAW_CHECK(rig.transport().locate(0) && rig.transport().play());

        const uint32_t sizes[] = {0, 1, 7, 64, 255, 256, 1000, 4096};
        std::uniform_int_distribution<size_t> pick(0, std::size(sizes) - 1);
        const int64_t total = tempo.tickToSample(960 * 15);
        rig.renderFrames(total, [&] { return sizes[pick(rng)]; });

        const auto& L = rig.left();
        const auto& R = rig.right();
        DAW_CHECK(int64_t(L.size()) == total);
        const Oracle oracle(tempo, clips, assets);
        int64_t bad = 0;
        for (int64_t s = 0; s < total; ++s) {
            if (!near(L[s], oracle(s, 0), 1e-5)) ++bad;
            if (!near(R[s], oracle(s, 1), 1e-5)) ++bad;
        }
        DAW_CHECK(bad == 0);
        DAW_CHECK(rig.violations() == 0);
    }
    return checks;
}

CheckResult clipPlayerLoopWrapCrossfade() {
    CheckResult checks;
    constexpr uint32_t K = AudioClipPlayer::kDeclickFrames;
    constexpr int64_t kLoopStart = 40 * kSamplesPerTick;  // tick 40
    constexpr int64_t kLoopEnd = 120 * kSamplesPerTick;   // tick 120: 2000-sample loop

    // A constant clip across the loop: crossfade weights sum to 1, so the output stays 1.
    {
        Rig rig;
        rig.addAsset(makeAsset(1, 1, 20000, [](uint32_t, int64_t) { return 1.0f; }));
        DAW_CHECK(rig.publish(playerGraph({clip(kPlayer, 1, 0, 400, 1)})));
        DAW_CHECK(rig.transport().setLoop(true, 40, 120) && rig.transport().locate(40) &&
                  rig.transport().play());
        rig.renderFrames(5 * (kLoopEnd - kLoopStart) + 77, fixedBlock);  // wraps mid-block
        bool flat = true;
        for (float x : rig.left()) flat = flat && near(x, 1.0, 1e-6);
        DAW_CHECK(flat);
        DAW_CHECK(rig.violations() == 0);
    }

    // A ramp (value = source frame / 1e4): after each wrap the output is the new pass fading in
    // plus the old pass, continuing past the loop end, fading out.
    {
        Rig rig;
        rig.addAsset(makeAsset(1, 2, 20000, [](uint32_t c, int64_t i) { return (c ? -1.0f : 1.0f) * float(i) / 1e4f; }));
        DAW_CHECK(rig.publish(playerGraph({clip(kPlayer, 1, 0, 400, 1)})));
        DAW_CHECK(rig.transport().setLoop(true, 40, 120) && rig.transport().locate(40) &&
                  rig.transport().play());
        const int64_t loop = kLoopEnd - kLoopStart;
        rig.renderFrames(3 * loop + 500, [] { return 300u; });
        const auto& L = rig.left();
        const auto& R = rig.right();
        auto src = [](int64_t timelineSample) { return double(timelineSample) / 1e4; };

        bool ok = true;
        // First pass: plain playback from the loop start, no fade-in.
        for (int64_t i = 0; i < loop; ++i) ok = ok && near(L[i], src(kLoopStart + i), 1e-6);
        for (int pass = 1; pass <= 3; ++pass) {
            const int64_t w = pass * loop;  // output index of the wrap
            for (uint32_t j = 0; j < K; ++j) {
                const double in = double(j + 1) / K, out = double(K - 1 - j) / K;
                const double expected = in * src(kLoopStart + j) + out * src(kLoopEnd + j);
                ok = ok && near(L[w + j], expected, 1e-6) && near(R[w + j], -expected, 1e-6);
            }
            for (int64_t i = K; i < std::min<int64_t>(loop, int64_t(L.size()) - w); ++i)
                ok = ok && near(L[w + i], src(kLoopStart + i), 1e-6);
        }
        DAW_CHECK(ok);
        // Click-free: no step at the wrap larger than a few ramp steps (the jump without the
        // crossfade would be (loopEnd − loopStart) / 1e4 = 0.2).
        double maxStep = 0;
        for (size_t i = 1; i < L.size(); ++i) maxStep = std::max(maxStep, std::fabs(double(L[i]) - L[i - 1]));
        DAW_CHECK(maxStep < 0.2 / K * 1.5);
        DAW_CHECK(rig.violations() == 0);
    }
    return checks;
}

CheckResult clipPlayerLocateResets() {
    CheckResult checks;
    Rig rig;
    rig.addAsset(makeAsset(1, 1, 40000, [](uint32_t, int64_t i) { return float(i) / 1e5f; }));
    DAW_CHECK(rig.publish(playerGraph({clip(kPlayer, 1, 0, 1600, 1)})));
    auto src = [](int64_t timelineSample) { return double(timelineSample) / 1e5; };

    DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
    rig.renderFrames(1024, fixedBlock);
    // TIME-008: locate while playing → reset(); the next block is the new position, no tail.
    DAW_CHECK(rig.transport().locate(400));  // sample 10000
    rig.renderFrames(1024, fixedBlock);
    bool ok = true;
    for (int64_t i = 0; i < 1024; ++i) ok = ok && near(rig.left()[1024 + i], src(10000 + i), 1e-6);
    DAW_CHECK(ok);

    // Stop, locate while stopped (no reset), play: the stopped block ends the pass, so playback
    // starts clean at the new position too.
    DAW_CHECK(rig.transport().stop());
    rig.render(256);
    DAW_CHECK(rig.transport().locate(800) && rig.transport().play());  // sample 20000
    rig.clearOutput();
    rig.renderFrames(512, fixedBlock);
    ok = true;
    for (int64_t i = 0; i < 512; ++i) ok = ok && near(rig.left()[i], src(20000 + i), 1e-6);
    DAW_CHECK(ok);
    DAW_CHECK(rig.violations() == 0);
    return checks;
}

CheckResult clipPlayerAssetsAndClipDelivery() {
    CheckResult checks;
    Rig rig;
    rig.addAsset(makeAsset(1, 1, 10000, [](uint32_t, int64_t) { return 1.0f; }));
    rig.addAsset(makeAsset(2, 1, 10000, [](uint32_t, int64_t) { return 0.5f; }));
    rig.addAsset(makeAsset(3, 1, 10000, [](uint32_t, int64_t) { return 1.0f; }, 44100.0));  // wrong rate
    const SharedAudioAsset* one = rig.asset(1).shared();
    DAW_CHECK(one->useCount() == 1);

    // Asset 9 isn't loaded and asset 3 isn't at the session rate: both silent (IO-031).
    DAW_CHECK(rig.publish(playerGraph({clip(kPlayer, 1, 0, 40, 1), clip(kPlayer, 2, 40, 40, 9),
                                       clip(kPlayer, 3, 80, 40, 3)})));
    DAW_CHECK(one->useCount() == 2);  // the player holds its own reference (DW-042)
    DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
    rig.renderFrames(3000, fixedBlock);
    bool ok = true;
    for (int s = 0; s < 1000; ++s) ok = ok && rig.left()[s] == 1.0f;
    for (int s = 1000; s < 3000; ++s) ok = ok && rig.left()[s] == 0.0f;
    DAW_CHECK(ok);
    DAW_CHECK(one->useCount() == 2);  // rendering never retains or releases

    // DW-051: clips are fixed per instance. Moving the clip without a configVersion bump reuses
    // the node, which keeps playing the old clips…
    DAW_CHECK(rig.transport().locate(0));
    DAW_CHECK(rig.publish(playerGraph({clip(kPlayer, 1, 0, 40, 2)}, 1)));
    rig.clearOutput();
    rig.renderFrames(1000, fixedBlock);
    DAW_CHECK(rig.left()[500] == 1.0f);
    // …and a bump delivers them to a new instance.
    DAW_CHECK(rig.transport().locate(0));
    DAW_CHECK(rig.publish(playerGraph({clip(kPlayer, 1, 0, 40, 2)}, 2)));
    rig.clearOutput();
    rig.renderFrames(1000, fixedBlock);
    DAW_CHECK(rig.left()[500] == 0.5f);

    // The old instance's reference to asset 1 goes when daw.reclaim destroys it, once no graph
    // uses it (ENG-013), never on the audio thread (violations stay 0).
    rig.render(256);
    DAW_CHECK(rig.reclaimPasses(3));
    DAW_CHECK(one->useCount() == 1);
    DAW_CHECK(rig.asset(2).shared()->useCount() == 2);

    // Dropping the player releases its last asset too.
    DAW_CHECK(rig.publish(baseDescription()));
    rig.render(256);
    rig.render(256);
    DAW_CHECK(rig.reclaimPasses(3));
    DAW_CHECK(rig.asset(2).shared()->useCount() == 1);
    DAW_CHECK(rig.violations() == 0);
    return checks;
}

} // namespace daw::testing
