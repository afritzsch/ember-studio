// T-013 checks for the AudioClipPlayer. Run from Tests/DAWEngineTests/ClipPlayerTests.swift; see
// ClipPlayerChecks.h for why they're C++.

#include "ClipPlayerChecks.h"

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdint>
#include <iterator>
#include <map>
#include <numbers>
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

// The brute-force reference for DSP-001 and DSP-002 (06 "later clip wins"), written from the
// spec text rather than the player's code: every clip at every sample, in double. Clip positions
// and what lies under each clip are worked out once up front by scanning all clips, so the
// per-sample loop is cheap even in Debug.
class Oracle {
public:
    Oracle(const TempoMap& tempo, std::vector<ClipDesc> clips,
           const std::map<uint64_t, AudioAssetRef>& assets) {
        // Order: (start, clipID); "later" is later in it. Clips with length <= 0 don't exist.
        std::erase_if(clips, [](const ClipDesc& c) { return c.length <= 0; });
        std::sort(clips.begin(), clips.end(), [](const ClipDesc& a, const ClipDesc& b) {
            return a.start != b.start ? a.start < b.start : a.clipID < b.clipID;
        });
        for (size_t i = 0; i < clips.size(); ++i) {
            const ClipDesc& c = clips[i];
            Placed p;
            auto it = assets.find(c.assetID);
            p.asset = it != assets.end() && it->second ? &*it->second : nullptr;
            p.cs = tempo.tickToSample(c.start);
            p.ce = tempo.tickToSample(c.start + c.length);
            p.fi = tempo.tickToSample(c.start + std::clamp<Tick>(c.fadeIn, 0, c.length)) - p.cs;
            p.fo = p.ce - tempo.tickToSample(c.start + c.length - std::clamp<Tick>(c.fadeOut, 0, c.length));
            p.offset = c.sourceOffsetSamples;
            p.gain = c.gain;
            // Crossfades: in, over earlier clips with a strictly earlier start tick that still
            // cover cs (for at most as long as they do); out, if any earlier clip ends later.
            SamplePos under = INT64_MIN;
            bool outOver = false;
            for (size_t j = 0; j < i; ++j) {
                const SamplePos je = tempo.tickToSample(clips[j].start + clips[j].length);
                if (clips[j].start < c.start && je > p.cs) under = std::max(under, je);
                if (je > p.ce) outOver = true;
            }
            const SamplePos maxFade = std::min<SamplePos>(64, p.ce - p.cs);
            p.nIn = under == INT64_MIN ? 0 : std::min(maxFade, under - p.cs);
            p.nOut = outOver ? maxFade : 0;
            placed_.push_back(p);
        }
    }

    double operator()(SamplePos s, uint32_t channel) const {
        double sum = 0.0, trans = 1.0;
        for (size_t i = placed_.size(); i-- > 0;) {  // the latest clip first
            const Placed& p = placed_[i];
            if (s < p.cs || s >= p.ce) continue;
            double f = 1.0;
            if (s - p.cs < p.nIn) f = std::min(f, double(s - p.cs + 1) / double(p.nIn));
            if (p.ce - 1 - s < p.nOut) f = std::min(f, double(p.ce - s) / double(p.nOut));
            const double cover = std::sin(f * std::numbers::pi / 2), pass = std::cos(f * std::numbers::pi / 2);
            const SamplePos src = p.offset + (s - p.cs);
            const bool playable = p.asset && p.asset->sampleRate == kRate;
            if (playable && src >= 0 && src < p.asset->frames) {
                double g = p.gain;
                if (s - p.cs < p.fi) g *= double(s - p.cs) / double(p.fi);
                if (p.ce - 1 - s < p.fo) g *= double(p.ce - 1 - s) / double(p.fo);
                sum += trans * cover * g * p.asset->data[p.asset->channels > 1 ? channel : 0][src];
            }
            trans *= pass;
        }
        return sum;
    }

private:
    struct Placed {
        const AudioAsset* asset;
        SamplePos cs, ce, fi, fo, nIn, nOut;
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
    for (uint32_t seed = 1; seed <= 8; ++seed) {
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
        // DSP-002: some equal starts (the clip ID breaks the tie) and the descriptors shuffled, so
        // the player must sort by (start, clipID) itself.
        for (size_t i = 1; i < clips.size(); i += 4) clips[i].start = clips[i - 1].start;
        std::shuffle(clips.begin(), clips.end(), rng);
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

CheckResult clipPlayerOverlapCrossfades() {
    CheckResult checks;
    // Asset 1 is (L, R) = (1, 0) and asset 2 is (0, 1): a clip on asset 1 shows its weight on the
    // left channel, one on asset 2 on the right. kSamplesPerTick = 25, so tick 40 is sample 1000.
    auto rigWith = [](Rig& rig) {
        rig.addAsset(makeAsset(1, 2, 400000, [](uint32_t c, int64_t) { return c == 0 ? 1.0f : 0.0f; }));
        rig.addAsset(makeAsset(2, 2, 400000, [](uint32_t c, int64_t) { return c == 0 ? 0.0f : 1.0f; }));
    };
    auto render = [&](Rig& rig, std::vector<ClipDesc> clips, int64_t frames) {
        DAW_CHECK(rig.publish(playerGraph(std::move(clips))));
        DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
        rig.renderFrames(frames, [] { return 100u; });  // boundaries fall mid-block
        DAW_CHECK(rig.violations() == 0);
    };
    // Equal-power weights at frame k of an n-frame crossfade (06, DSP-002).
    auto in = [](int64_t k, int64_t n) { return std::sin(double(k + 1) / double(n) * std::numbers::pi / 2); };
    auto out = [](int64_t k, int64_t n) { return std::cos(double(k + 1) / double(n) * std::numbers::pi / 2); };
    // Expects (L, R) = (under, over) on [from, to).
    auto flat = [](const Rig& rig, int64_t from, int64_t to, double under, double over) {
        bool ok = true;
        for (int64_t s = from; s < to; ++s) ok = ok && rig.left()[s] == under && rig.right()[s] == over;
        return ok;
    };

    // Nested: W (ticks 40..80 = samples 1000..2000) inside U (0..160). W fades in over U at 1000,
    // hides it, and fades out at its end while U fades back in; the weights' squares sum to 1.
    {
        Rig rig;
        rigWith(rig);
        render(rig, {clip(kPlayer, 1, 0, 160, 1), clip(kPlayer, 2, 40, 40, 2)}, 4000);
        const auto& L = rig.left();
        const auto& R = rig.right();
        DAW_CHECK(flat(rig, 0, 1000, 1, 0));
        bool ok = true, power = true;
        for (int64_t k = 0; k < 64; ++k) {
            ok = ok && near(R[1000 + k], in(k, 64)) && near(L[1000 + k], out(k, 64));
            ok = ok && near(R[1999 - k], in(k, 64)) && near(L[1999 - k], out(k, 64));
        }
        for (int64_t s = 900; s < 2100; ++s) power = power && near(double(L[s]) * L[s] + double(R[s]) * R[s], 1.0);
        DAW_CHECK(ok);
        DAW_CHECK(power);
        DAW_CHECK(R[1000] > 0.0f && R[1000] < 0.03f);  // sin(π/128): already slightly in
        DAW_CHECK(flat(rig, 1064, 1936, 0, 1));         // later clip wins: U silent, not summed
        DAW_CHECK(flat(rig, 2000, 4000, 1, 0));
    }

    // Partial overlap: W (40..160) starts over U (0..80) and outlives it. Fade-in only; U ends
    // hidden at 2000 and W ends with nothing underneath, so it stops as in DSP-001.
    {
        Rig rig;
        rigWith(rig);
        render(rig, {clip(kPlayer, 1, 0, 80, 1), clip(kPlayer, 2, 40, 120, 2)}, 5000);
        bool ok = true;
        for (int64_t k = 0; k < 64; ++k)
            ok = ok && near(rig.right()[1000 + k], in(k, 64)) && near(rig.left()[1000 + k], out(k, 64));
        DAW_CHECK(ok);
        DAW_CHECK(flat(rig, 1064, 4000, 0, 1));
        DAW_CHECK(flat(rig, 4000, 5000, 0, 0));
    }

    // Short overlap: U (0..1020 samples) ends 20 samples into W, so the fade-in lasts 20.
    {
        Rig rig;
        rigWith(rig);
        auto u = clip(kPlayer, 1, 0, 40, 1);
        u.length = 41;  // ticks 0..41 = samples 0..1025: 25 samples of overlap
        render(rig, {u, clip(kPlayer, 2, 40, 40, 2)}, 3000);
        bool ok = true;
        for (int64_t k = 0; k < 25; ++k)
            ok = ok && near(rig.right()[1000 + k], in(k, 25)) && near(rig.left()[1000 + k], out(k, 25));
        DAW_CHECK(ok);
        DAW_CHECK(flat(rig, 1025, 2000, 0, 1));  // no dip once U has ended
    }

    // Equal starts: the larger clip ID wins from its first sample, no fade-in. Here the shorter
    // clip is later, so the longer one fades back in at its end.
    {
        Rig rig;
        rigWith(rig);
        render(rig, {clip(kPlayer, 2, 40, 40, 2), clip(kPlayer, 1, 40, 80, 1)}, 4000);
        DAW_CHECK(flat(rig, 0, 1000, 0, 0));
        DAW_CHECK(flat(rig, 1000, 1936, 0, 1));
        bool ok = true;
        for (int64_t k = 0; k < 64; ++k)
            ok = ok && near(rig.right()[1999 - k], in(k, 64)) && near(rig.left()[1999 - k], out(k, 64));
        DAW_CHECK(ok);
        DAW_CHECK(flat(rig, 2000, 3000, 1, 0));
    }
    // …and with the IDs swapped the longer clip wins throughout; the shorter is never heard.
    {
        Rig rig;
        rigWith(rig);
        render(rig, {clip(kPlayer, 1, 40, 40, 2), clip(kPlayer, 2, 40, 80, 1)}, 4000);
        DAW_CHECK(flat(rig, 1000, 3000, 1, 0));
    }

    // A winner shorter than two crossfades (2 ticks = 50 samples) inside U: both fades last 50
    // and the one less far along counts, so W never reaches full cover; equal power throughout.
    {
        Rig rig;
        rigWith(rig);
        render(rig, {clip(kPlayer, 1, 0, 160, 1), clip(kPlayer, 2, 40, 2, 2)}, 2000);
        bool ok = true;
        for (int64_t k = 0; k < 50; ++k) {
            const int64_t d = std::min<int64_t>(k, 49 - k);
            ok = ok && near(rig.right()[1000 + k], in(d, 50)) && near(rig.left()[1000 + k], out(d, 50));
        }
        DAW_CHECK(ok);
        DAW_CHECK(flat(rig, 1050, 2000, 1, 0));
    }

    // Clip fades and gain shape the winner's own audio only, and a winner with a missing asset
    // still hides U (with silence).
    {
        Rig rig;
        rigWith(rig);
        render(rig, {clip(kPlayer, 1, 0, 160, 1), clip(kPlayer, 2, 40, 40, 2, 0, 0.5f, 0, 20),
                     clip(kPlayer, 3, 100, 20, 9)}, 4000);
        DAW_CHECK(flat(rig, 1064, 1500, 0, 0.5f));
        DAW_CHECK(rig.left()[1800] == 0.0f && near(rig.right()[1800], 0.5 * 199.0 / 500.0));
        DAW_CHECK(flat(rig, 2564, 2936, 0, 0));  // missing asset: silence over U
        DAW_CHECK(flat(rig, 3000, 4000, 1, 0));
    }

    // Three layers: X (60..100) starts inside W (40..80), itself inside U (0..160). At X's start
    // W and the hidden U both sit under it; each weight is its own sin times the later cos.
    {
        Rig rig;
        rigWith(rig);
        rig.addAsset(makeAsset(3, 1, 400000, [](uint32_t, int64_t) { return 0.0f; }));  // silent X
        render(rig, {clip(kPlayer, 1, 0, 160, 1), clip(kPlayer, 2, 40, 40, 2), clip(kPlayer, 3, 60, 40, 3)}, 4000);
        bool ok = true;
        for (int64_t k = 0; k < 64; ++k) ok = ok && near(rig.right()[1500 + k], out(k, 64)) && rig.left()[1500 + k] == 0.0f;
        DAW_CHECK(ok);
        DAW_CHECK(flat(rig, 1564, 2436, 0, 0));
        // X fades out over U at its end (W ended hidden at 2000).
        ok = true;
        for (int64_t k = 0; k < 64; ++k) ok = ok && near(rig.left()[2499 - k], out(k, 64)) && rig.right()[2499 - k] == 0.0f;
        DAW_CHECK(ok);
    }

    // Adjacent clips (end == start) don't overlap: no crossfade, as in DSP-001.
    {
        Rig rig;
        rigWith(rig);
        render(rig, {clip(kPlayer, 1, 0, 40, 1), clip(kPlayer, 2, 40, 40, 2)}, 3000);
        DAW_CHECK(flat(rig, 0, 1000, 1, 0));
        DAW_CHECK(flat(rig, 1000, 2000, 0, 1));
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
