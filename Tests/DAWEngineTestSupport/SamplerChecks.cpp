// T-041 checks for the Sampler. Run from Tests/DAWEngineTests/SamplerTests.swift; see
// SamplerChecks.h for why they're C++ and how they drive the node.

#include "SamplerChecks.h"

#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdint>
#include <memory>
#include <numbers>
#include <random>
#include <string>
#include <utility>
#include <vector>

#include "NodeTestHarness.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/ProcessContext.h"
#include "core/RtTrap.h"
#include "nodes/Sampler.h"

using namespace daw;
using daw::testing::nodes::makeAsset;

namespace daw::testing {

namespace {

constexpr double kRate = 48000.0;

MidiEvent noteOn(uint32_t frame, uint8_t key, uint8_t velocity = 127, uint8_t channel = 0) {
    return MidiEvent{frame, 3, {uint8_t(0x90 | channel), key, velocity}};
}
MidiEvent noteOff(uint32_t frame, uint8_t key, uint8_t channel = 0) {
    return MidiEvent{frame, 3, {uint8_t(0x80 | channel), key, 64}};
}
MidiEvent cc(uint32_t frame, uint8_t controller, uint8_t value, uint8_t channel = 0) {
    return MidiEvent{frame, 3, {uint8_t(0xB0 | channel), controller, value}};
}
MidiEvent bend(uint32_t frame, int value, uint8_t channel = 0) {
    return MidiEvent{frame, 3, {uint8_t(0xE0 | channel), uint8_t(value & 0x7F), uint8_t((value >> 7) & 0x7F)}};
}

Sampler::Zone zone(uint64_t assetID, AudioAssetRef asset, uint8_t root = 60) {
    Sampler::Zone z;
    z.assetID = assetID;
    z.rootKey = root;
    z.asset = std::move(asset);
    return z;
}

AudioAssetRef constant(uint64_t id, int64_t frames, float value, double rate = kRate) {
    return makeAsset(id, 1, frames, [value](uint32_t, int64_t) { return value; }, rate);
}

AudioAssetRef sine(uint64_t id, double hz, int64_t frames) {
    return makeAsset(id, 1, frames, [hz](uint32_t, int64_t i) {
        return static_cast<float>(std::sin(2.0 * std::numbers::pi * hz * static_cast<double>(i) / kRate));
    });
}

// Drives a Sampler the way the Engine would, with its own param slots, in RtScopes.
class Driver {
public:
    // `params` overrides by index; the rest keep their defaults.
    explicit Driver(std::vector<Sampler::Zone> zones, std::vector<std::pair<uint32_t, float>> params = {}) {
        first_ = table_.allocate(Sampler::kNumParams).value();
        for (const ParamInfo& p : Sampler::kParamInfo) table_.set(first_ + p.index, p.def);
        for (auto [i, v] : params) table_.set(first_ + i, v);
        sampler_ = std::make_unique<Sampler>(std::move(zones), first_, Sampler::kNumParams);
        sampler_->prepare(PrepareInfo{kRate, kMaxBlock, 0, 2});
    }

    Sampler& sampler() { return *sampler_; }
    void setParam(uint32_t index, float value) { table_.set(first_ + index, value); }

    // One block with events at block frames.
    void render(uint32_t n, const std::vector<MidiEvent>& events = {}) {
        std::vector<float> l(n, -99.0f), r(n, -99.0f);
        float* ptrs[2] = {l.data(), r.data()};
        NodeIO io;
        io.audioOut = AudioBufferView{ptrs, 2, n};
        io.midiIn = MidiEventSpan(events.data(), events.size());
        const TransportBlock block{};  // an instrument doesn't follow the transport
        {
            RtScope scope;
            ProcessContext ctx{n, kRate, block, table_};
            sampler_->process(ctx, io);
            violations_ += scope.violations();
        }
        left_.insert(left_.end(), l.begin(), l.end());
        right_.insert(right_.end(), r.begin(), r.end());
    }

    // Renders up to absolute frame `end`, events at absolute frames (sorted), in blocks from
    // `nextBlock()` (may return 0).
    template <class NextBlock>
    void renderUntil(int64_t end, const std::vector<std::pair<int64_t, MidiEvent>>& events, NextBlock&& nextBlock) {
        while (frame() < end) {
            const auto n = static_cast<uint32_t>(std::min<int64_t>(nextBlock(), end - frame()));
            std::vector<MidiEvent> block;
            // Events at or after the block start and before its end (0-frame blocks take none).
            for (; next_ < events.size() && events[next_].first < frame() + n; ++next_) {
                MidiEvent e = events[next_].second;
                e.frameOffset = static_cast<uint32_t>(events[next_].first - frame());
                block.push_back(e);
            }
            render(n, block);
        }
    }
    // Without events: for after the last event (or when there are none).
    void renderUntil(int64_t end, uint32_t blockSize) {
        while (frame() < end) render(static_cast<uint32_t>(std::min<int64_t>(blockSize, end - frame())));
    }

    int64_t frame() const { return static_cast<int64_t>(left_.size()); }
    const std::vector<float>& left() const { return left_; }
    const std::vector<float>& right() const { return right_; }
    uint64_t violations() const { return violations_; }

private:
    ParamSlotTable table_{64};
    ParamID first_ = 0;
    std::unique_ptr<Sampler> sampler_;
    std::vector<float> left_, right_;
    size_t next_ = 0;
    uint64_t violations_ = 0;
};

// Radix-2 FFT, in place.
void fft(std::vector<std::complex<double>>& a) {
    const size_t n = a.size();
    for (size_t i = 1, j = 0; i < n; ++i) {
        size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std::swap(a[i], a[j]);
    }
    for (size_t len = 2; len <= n; len <<= 1) {
        const double angle = -2.0 * std::numbers::pi / static_cast<double>(len);
        const std::complex<double> wl(std::cos(angle), std::sin(angle));
        for (size_t i = 0; i < n; i += len) {
            std::complex<double> w(1.0);
            for (size_t k = 0; k < len / 2; ++k, w *= wl) {
                const auto u = a[i + k], v = a[i + k + len / 2] * w;
                a[i + k] = u + v;
                a[i + k + len / 2] = u - v;
            }
        }
    }
}

// The strongest frequency in x[offset, offset + n) (n a power of two): Hann window, then a
// parabola through the log magnitudes of the peak bin and its neighbours (exact to well under
// a bin for a pure tone).
double peakFrequency(const std::vector<float>& x, size_t offset, size_t n) {
    std::vector<std::complex<double>> a(n);
    for (size_t i = 0; i < n; ++i) {
        const double w = 0.5 - 0.5 * std::cos(2.0 * std::numbers::pi * static_cast<double>(i) / static_cast<double>(n));
        a[i] = w * x[offset + i];
    }
    fft(a);
    size_t peak = 1;
    for (size_t k = 1; k < n / 2; ++k)
        if (std::abs(a[k]) > std::abs(a[peak])) peak = k;
    const double l = std::log(std::abs(a[peak - 1])), c = std::log(std::abs(a[peak])), r = std::log(std::abs(a[peak + 1]));
    const double delta = 0.5 * (l - r) / (l - 2.0 * c + r);
    return (static_cast<double>(peak) + delta) * kRate / static_cast<double>(n);
}

float maxStep(const std::vector<float>& x) {
    float m = 0.0f;
    for (size_t i = 1; i < x.size(); ++i) m = std::max(m, std::abs(x[i] - x[i - 1]));
    return m;
}

} // namespace

CheckResult samplerParsesZones() {
    CheckResult checks;
    auto zones = Sampler::parseZones(R"({"zones": [
        {"assetID": 9007199254740993, "rootKey": 69, "lowKey": 10, "highKey": 20, "lowVel": 5,
         "highVel": 99, "tune": -0.5, "gain": 0.25e1, "loopStart": 100, "loopEnd": 2000, "future": [1, {"x": null}]},
        {"assetID": 3}
    ], "other": true})");
    DAW_CHECK(zones.ok());
    if (zones.ok() && zones->size() == 2) {
        const Sampler::Zone& a = (*zones)[0];
        DAW_CHECK(a.assetID == 9007199254740993ull);  // exact beyond 2^53
        DAW_CHECK(a.rootKey == 69 && a.lowKey == 10 && a.highKey == 20 && a.lowVel == 5 && a.highVel == 99);
        DAW_CHECK(a.tune == -0.5f && a.gain == 2.5f && a.loopStart == 100 && a.loopEnd == 2000);
        const Sampler::Zone& b = (*zones)[1];
        DAW_CHECK(b.assetID == 3 && b.rootKey == 60 && b.lowKey == 0 && b.highKey == 127 && b.lowVel == 1 &&
                  b.highVel == 127 && b.tune == 0.0f && b.gain == 1.0f && b.loopStart == -1 && b.loopEnd == -1);
    } else {
        DAW_CHECK(false);
    }

    for (const char* empty : {"", "  \n", "{}", R"({"zones": []})"}) {
        auto none = Sampler::parseZones(empty);
        DAW_CHECK(none.ok() && none->empty());
    }

    const char* bad[] = {
        "[]", "{", R"({"zones": {}})", R"({"zones": [1]})", R"({"zones": [{}]})",
        R"({"zones": [{"assetID": -1}]})", R"({"zones": [{"assetID": 1.5}]})", R"({"zones": [{"assetID": "1"}]})",
        R"({"zones": [{"assetID": 1, "rootKey": 128}]})", R"({"zones": [{"assetID": 1, "lowKey": 70, "highKey": 60}]})",
        R"({"zones": [{"assetID": 1, "lowVel": 0}]})", R"({"zones": [{"assetID": 1, "lowVel": 90, "highVel": 80}]})",
        R"({"zones": [{"assetID": 1, "gain": -1}]})", R"({"zones": [{"assetID": 1, "tune": "x"}]})",
        R"({"zones": [{"assetID": 1, "loopStart": 5}]})", R"({"zones": [{"assetID": 1, "loopStart": 5, "loopEnd": 5}]})",
        R"({"zones": [{"assetID": 1, "loopStart": -2, "loopEnd": 5}]})", R"({"zones": [{"assetID": 1}]} x)",
    };
    for (const char* json : bad) {
        auto r = Sampler::parseZones(json);
        DAW_CHECK(!r.ok() && r.error().code == ErrorCode::invalidArgument);
    }

    // The registered factory resolves assets through the lookup; unknown assets stay empty.
    AudioAssetRef asset = constant(7, 100, 1.0f);
    NodeKindInfo info = Sampler::kindInfo([&](uint64_t id) { return id == 7 ? asset : AudioAssetRef{}; });
    NodeDesc desc{4, NodeKind::sampler, 1, 0, 0, R"({"zones": [{"assetID": 7}, {"assetID": 8}]})"};
    auto node = info.create(NodeCreateInfo{desc, {}, {}, kNoMeter, {}});
    DAW_CHECK(node.ok());
    if (node.ok()) {
        auto& sampler = static_cast<Sampler&>(*node.value());
        DAW_CHECK(sampler.zones().size() == 2 && sampler.zones()[0].asset.shared() == asset.shared() &&
                  !sampler.zones()[1].asset);
    }
    desc.configJSON = R"({"zones": [{"assetID": 7, "highKey": 200}]})";
    auto rejected = info.create(NodeCreateInfo{desc, {}, {}, kNoMeter, {}});
    DAW_CHECK(!rejected.ok() && rejected.error().code == ErrorCode::invalidArgument &&
              rejected.error().message.find("sampler 4") != std::string::npos);
    return checks;
}

CheckResult samplerZoneMapping() {
    CheckResult checks;
    // Instant attack and release and no velocity curve, so each note is a plateau of its gain.
    const std::vector<std::pair<uint32_t, float>> flat = {
        {Sampler::kAttack, 0.0f}, {Sampler::kRelease, 0.0f}, {Sampler::kVelocity, 0.0f}};
    auto zones = [&] {
        std::vector<Sampler::Zone> z;
        z.push_back(zone(1, constant(1, 10000, 0.5f)));
        z.back().highKey = 59;
        z.push_back(zone(2, constant(2, 10000, 0.25f)));
        z.back().lowKey = 60;
        z.back().highVel = 100;
        z.push_back(zone(3, constant(3, 10000, 0.125f)));  // layered over zone 2 at velocity 90…100
        z.back().lowKey = 60;
        z.back().lowVel = 90;
        z.back().gain = 2.0f;
        z.push_back(zone(4, AudioAssetRef{}));  // not loaded: silent
        z.push_back(zone(5, constant(5, 10000, 1.0f, 44100.0)));  // wrong rate: silent
        return z;
    };
    struct Case { uint8_t key, velocity; float level; uint32_t voices; };
    for (const Case& c : {Case{50, 100, 0.5f, 1}, Case{59, 1, 0.5f, 1}, Case{60, 50, 0.25f, 1},
                          Case{70, 95, 0.5f, 2}, Case{70, 90, 0.5f, 2}, Case{70, 100, 0.5f, 2},
                          Case{70, 101, 0.25f, 1}, Case{127, 127, 0.25f, 1}}) {
        Driver d(zones(), flat);
        DAW_CHECK(!d.sampler().zones()[3].playable && !d.sampler().zones()[4].playable);
        d.render(64, {noteOn(10, c.key, c.velocity)});
        DAW_CHECK(d.left()[9] == 0.0f && d.left()[10] == c.level && d.left()[63] == c.level && d.right()[63] == c.level);
        DAW_CHECK(d.sampler().soundingVoices(0, c.key) == c.voices);
        d.render(64, {noteOff(5, c.key)});
        DAW_CHECK(d.left()[64 + 4] == c.level && d.left()[64 + 6] == 0.0f && d.sampler().soundingVoices() == 0);
        DAW_CHECK(d.violations() == 0);
    }

    // Stereo assets keep their channels; one-shot voices end at the asset's end.
    {
        std::vector<Sampler::Zone> z;
        z.push_back(zone(1, makeAsset(1, 2, 100, [](uint32_t c, int64_t) { return c == 0 ? 0.5f : -0.5f; })));
        Driver d(std::move(z), flat);
        d.render(256, {noteOn(0, 60)});
        DAW_CHECK(d.left()[0] == 0.5f && d.right()[0] == -0.5f && d.left()[99] == 0.5f && d.right()[99] == -0.5f);
        DAW_CHECK(d.left()[100] == 0.0f && d.right()[100] == 0.0f && d.sampler().soundingVoices() == 0);
        DAW_CHECK(d.violations() == 0);
    }
    // Loops keep a short asset playing; a loop past the asset's end is clamped to it.
    for (int64_t loopEnd : {int64_t{100}, int64_t{5000}}) {
        std::vector<Sampler::Zone> z;
        z.push_back(zone(1, constant(1, 100, 1.0f)));
        z.back().loopStart = 20;
        z.back().loopEnd = loopEnd;
        Driver d(std::move(z), flat);
        DAW_CHECK(d.sampler().zones()[0].looping && d.sampler().zones()[0].playLoopEnd == 100);
        d.render(4096, {noteOn(0, 60)});
        DAW_CHECK(std::all_of(d.left().begin(), d.left().end(), [](float v) { return v == 1.0f; }));
        DAW_CHECK(d.sampler().soundingVoices() == 1);
        DAW_CHECK(d.violations() == 0);
    }
    return checks;
}

CheckResult samplerPitch() {
    CheckResult checks;
    const std::vector<std::pair<uint32_t, float>> instant = {{Sampler::kAttack, 0.0f}};
    // Rate 1: Hermite at integer positions is the sample itself.
    {
        AudioAssetRef asset = sine(1, 440.0, 48000);
        std::vector<Sampler::Zone> z{zone(1, asset, 69)};
        Driver d(std::move(z), instant);
        d.render(4096, {noteOn(0, 69)});
        d.renderUntil(20000, 1000);
        bool exact = true;
        for (int64_t i = 0; i < 20000; ++i) exact = exact && d.left()[size_t(i)] == asset->data[0][i];
        DAW_CHECK(exact);
        DAW_CHECK(d.violations() == 0);
    }
    // Hermite, not linear: at a fractional rate (a fifth up) the output tracks the ideal
    // resampled sine within 1e-4; linear interpolation is off by ~4e-4 at this frequency.
    {
        std::vector<Sampler::Zone> z{zone(1, sine(1, 440.0, 48000), 69)};
        Driver d(std::move(z), instant);
        d.render(4096, {noteOn(0, 76)});
        d.renderUntil(20000, 1000);
        const double rate = std::exp2(7.0 / 12.0);
        double worst = 0;
        for (int64_t i = 0; i < 20000; ++i)
            worst = std::max(worst, std::abs(d.left()[size_t(i)] -
                                             std::sin(2.0 * std::numbers::pi * 440.0 * rate * double(i) / kRate)));
        DAW_CHECK(worst < 1e-4);
        DAW_CHECK(d.violations() == 0);
    }
    // DSP-021 acceptance: A4 root, play A5 → 880 Hz (and A4 itself, and tune +12 on the root).
    struct Case { uint8_t key; float tune; double hz; };
    for (const Case& c : {Case{81, 0.0f, 880.0}, Case{69, 0.0f, 440.0}, Case{69, 12.0f, 880.0}, Case{76, 0.0f, 440.0 * std::exp2(7.0 / 12.0)}}) {
        std::vector<Sampler::Zone> z{zone(1, sine(1, 440.0, 4 * 48000), 69)};
        z[0].tune = c.tune;
        Driver d(std::move(z), instant);
        d.render(1024, {noteOn(0, c.key)});
        d.renderUntil(1024 + 32768, 512);
        const double hz = peakFrequency(d.left(), 1024, 32768);
        DAW_CHECK(std::abs(hz - c.hz) <= 1.0);
        DAW_CHECK(d.violations() == 0);
    }
    return checks;
}

CheckResult samplerEnvelope() {
    CheckResult checks;
    // A looped constant 1.0, so the output is the envelope itself.
    auto dc = [] {
        std::vector<Sampler::Zone> z{zone(1, constant(1, 1000, 1.0f))};
        z[0].loopStart = 0;
        z[0].loopEnd = 1000;
        return z;
    };
    // 480-frame (10 ms) attack, decay and release; sustain 0.5. Note-on at 1000, off at 3000.
    const std::vector<std::pair<uint32_t, float>> adsr = {
        {Sampler::kAttack, 0.01f}, {Sampler::kDecay, 0.01f}, {Sampler::kSustain, 0.5f}, {Sampler::kRelease, 0.01f}};
    const std::vector<std::pair<int64_t, MidiEvent>> events = {{1000, noteOn(0, 60)}, {3000, noteOff(0, 60)}};

    Driver reference(dc(), adsr);
    reference.renderUntil(4000, events, [] { return 4000u; });
    const std::vector<float>& env = reference.left();
    DAW_CHECK(env[999] == 0.0f);                                    // nothing before the note-on frame
    DAW_CHECK(std::abs(env[1000] - 1.0f / 480.0f) < 1e-6f);        // attack starts on it
    DAW_CHECK(std::abs(env[1239] - 0.5f) < 1e-3f);                 // halfway up
    const auto top = std::max_element(env.begin(), env.end()) - env.begin();
    DAW_CHECK(env[size_t(top)] == 1.0f && top >= 1478 && top <= 1480);  // peak after 480 frames
    DAW_CHECK(std::abs(env[size_t(top) + 240] - 0.75f) < 2e-3f);   // decaying, halfway to sustain
    DAW_CHECK(env[2500] == 0.5f && env[2999] == 0.5f);              // sustain
    DAW_CHECK(env[3000] < 0.5f && env[3000] > 0.498f);              // release starts on the off frame
    DAW_CHECK(std::abs(env[3239] - 0.25f) < 1e-3f);
    DAW_CHECK(env[3481] == 0.0f && env[3999] == 0.0f);              // and ends after 480 frames
    DAW_CHECK(reference.sampler().soundingVoices() == 0);
    DAW_CHECK(maxStep(env) < 1.1f / 480.0f);                        // no step anywhere

    // Sample-accurate: the same output in any block size, events mid-block or on boundaries.
    for (uint32_t seed = 1; seed <= 6; ++seed) {
        std::mt19937 rng(seed);
        std::uniform_int_distribution<uint32_t> size(0, 700);
        Driver d(dc(), adsr);
        const uint32_t fixed = seed == 1 ? 1u : seed == 2 ? 1000u : 0u;
        d.renderUntil(4000, events, [&] { return fixed ? fixed : size(rng); });
        DAW_CHECK(d.left() == env && d.right() == env);
        DAW_CHECK(d.violations() == 0);
    }

    // Velocity curve: (1 − s) + s · (v/127)².
    struct Case { float sensitivity; uint8_t velocity; float gain; };
    const float v64 = (64.0f / 127.0f) * (64.0f / 127.0f);
    for (const Case& c : {Case{1.0f, 64, v64}, Case{1.0f, 127, 1.0f}, Case{0.5f, 64, 0.5f + 0.5f * v64},
                          Case{0.0f, 1, 1.0f}}) {
        Driver d(dc(), {{Sampler::kAttack, 0.0f}, {Sampler::kVelocity, c.sensitivity}});
        d.render(64, {noteOn(0, 60, c.velocity)});
        DAW_CHECK(std::abs(d.left()[63] - c.gain) < 1e-6f);
        DAW_CHECK(d.violations() == 0);
    }
    return checks;
}

CheckResult samplerVoiceStealing() {
    CheckResult checks;
    auto dc = [] {
        std::vector<Sampler::Zone> z{zone(1, constant(1, 1000, 1.0f))};
        z[0].loopStart = 0;
        z[0].loopEnd = 1000;
        return z;
    };
    // DSP-022 acceptance: 40 held notes, one every 100 frames, in random block sizes.
    {
        std::vector<std::pair<int64_t, MidiEvent>> events;
        for (uint8_t i = 0; i < 40; ++i) events.push_back({100 * int64_t(i), noteOn(0, uint8_t(30 + i))});
        std::mt19937 rng(41);
        std::uniform_int_distribution<uint32_t> size(1, 300);
        Driver d(dc());
        int maxFading = 0;
        d.renderUntil(4400, events, [&] {  // past the last note's steal fade (5 ms = 240 frames)
            maxFading = std::max<int>(maxFading, int(d.sampler().fadingVoices()));
            DAW_CHECK(d.sampler().soundingVoices() <= Sampler::kMaxVoices);
            return size(rng);
        });
        DAW_CHECK(d.sampler().soundingVoices() == 32 && d.sampler().fadingVoices() == 0 && maxFading >= 1);
        for (uint8_t key = 30; key < 70; ++key)  // the 8 oldest went
            DAW_CHECK(d.sampler().soundingVoices(0, key) == (key < 38 ? 0u : 1u));
        // No clicks: the steal fades (1/240 per frame) and attacks (1/96) are the only slopes.
        DAW_CHECK(maxStep(d.left()) < 1.0f / 240.0f + 1.0f / 96.0f + 1e-4f);
        DAW_CHECK(d.left().back() == 32.0f);
        DAW_CHECK(d.violations() == 0);
    }
    // Released notes go first: 32 held, release key 50 (long release), then a new note.
    {
        Driver d(dc(), {{Sampler::kRelease, 20.0f}});
        std::vector<MidiEvent> on;
        for (uint8_t i = 0; i < 32; ++i) on.push_back(noteOn(i, uint8_t(30 + i)));
        d.render(256, on);
        d.render(256, {noteOff(0, 50)});
        DAW_CHECK(d.sampler().soundingVoices() == 32 && d.sampler().soundingVoices(0, 50) == 1);
        d.render(256, {noteOn(200, 100)});  // the steal fade is 56 frames in at the block's end
        DAW_CHECK(d.sampler().soundingVoices(0, 50) == 0 && d.sampler().soundingVoices(0, 30) == 1 &&
                  d.sampler().soundingVoices(0, 100) == 1 && d.sampler().fadingVoices() == 1);
        DAW_CHECK(d.violations() == 0);
    }
    // A burst on one frame that steals more than the fade slots hold stays bounded.
    {
        Driver d(dc());
        std::vector<MidiEvent> burst;
        for (uint8_t i = 0; i < 100; ++i) burst.push_back(noteOn(7, uint8_t(i), 127, uint8_t(i % 16)));
        d.render(64, burst);
        DAW_CHECK(d.sampler().soundingVoices() == 32 && d.sampler().fadingVoices() <= 32);
        d.renderUntil(1000, 64);
        DAW_CHECK(d.sampler().fadingVoices() == 0);
        DAW_CHECK(d.violations() == 0);
    }
    return checks;
}

CheckResult samplerPedalBendAllNotesOff() {
    CheckResult checks;
    auto dc = [] {
        std::vector<Sampler::Zone> z{zone(1, constant(1, 1000, 1.0f))};
        z[0].loopStart = 0;
        z[0].loopEnd = 1000;
        return z;
    };
    const std::vector<std::pair<uint32_t, float>> quick = {{Sampler::kAttack, 0.0f}, {Sampler::kRelease, 0.01f}};

    // CC 64: a note-off while the pedal is down waits for the pedal; velocity-0 note-ons too.
    {
        Driver d(dc(), quick);
        d.render(256, {noteOn(0, 60), noteOn(0, 62), cc(10, 64, 127), noteOff(20, 60),
                       MidiEvent{30, 3, {0x90, 62, 0}}});
        d.renderUntil(3000, 512);
        DAW_CHECK(d.sampler().soundingVoices() == 2 && d.left().back() == 2.0f);
        d.render(1024, {cc(100, 64, 0)});  // pedal up at frame 3100: both release over 480 frames
        DAW_CHECK(d.left()[3099] == 2.0f && d.left()[3100] < 2.0f && d.left()[3581] == 0.0f);
        DAW_CHECK(d.sampler().soundingVoices() == 0);
        // Pedal values below 64 are "up"; a held note with the pedal released plays on.
        d.render(64, {cc(0, 64, 63), noteOn(1, 60)});
        d.render(64, {noteOff(0, 60)});
        d.renderUntil(d.frame() + 600, 64);
        DAW_CHECK(d.sampler().soundingVoices() == 0);
        DAW_CHECK(d.violations() == 0);
    }
    // DW-100: CC 123 releases the held notes on its channel only; the pedal still holds them.
    {
        Driver d(dc(), quick);
        d.render(64, {noteOn(0, 60, 127, 0), noteOn(0, 62, 127, 0), noteOn(0, 60, 127, 1), cc(1, 64, 127, 2),
                      noteOn(2, 64, 127, 2)});
        d.render(64, {cc(0, 123, 0, 0), cc(0, 123, 0, 2)});
        d.renderUntil(1000, 64);
        DAW_CHECK(d.sampler().soundingVoices(0, 60) == 0 && d.sampler().soundingVoices(0, 62) == 0);
        DAW_CHECK(d.sampler().soundingVoices(1, 60) == 1 && d.sampler().soundingVoices(2, 64) == 1);
        d.render(64, {cc(0, 64, 0, 2)});
        d.renderUntil(2000, 64);
        DAW_CHECK(d.sampler().soundingVoices() == 1 && d.sampler().soundingVoices(1, 60) == 1);
        DAW_CHECK(d.violations() == 0);
    }
    // Pitch bend: ±2 semitones at the ends, centre back to the note, on its own channel only.
    struct Case { int value; uint8_t channel; double hz; };
    for (const Case& c : {Case{16383, 0, 440.0 * std::exp2(2.0 / 12.0)}, Case{0, 0, 440.0 * std::exp2(-2.0 / 12.0)},
                          Case{8192, 0, 440.0}, Case{16383, 1, 440.0 * std::exp2(-2.0 / 12.0)}}) {
        std::vector<Sampler::Zone> z{zone(1, sine(1, 440.0, 4 * 48000), 69)};
        Driver d(std::move(z), {{Sampler::kAttack, 0.0f}});
        d.render(1024, {bend(0, 0), noteOn(0, 69), bend(512, c.value, c.channel)});  // channel 0 starts bent down
        d.renderUntil(1024 + 32768, 512);
        DAW_CHECK(std::abs(peakFrequency(d.left(), 1024, 32768) - c.hz) <= 1.0);
        DAW_CHECK(d.violations() == 0);
    }
    return checks;
}

CheckResult samplerThroughGraphBuilder() {
    CheckResult checks;
    nodes::Rig rig;
    rig.addAsset(constant(7, 48000, 0.5f));

    // midi_tempo's MIDI track: player 2 ─midi→ sampler 4 → master.
    auto desc = [](std::string config, uint32_t version = 1) {
        GraphDescription d = nodes::baseDescription();
        d.nodes.push_back(NodeDesc{2, NodeKind::midiClipPlayer, 1, 0, 0, {}});
        d.nodes.push_back(NodeDesc{4, NodeKind::sampler, version, 0, 0, std::move(config)});
        d.edges.push_back(EdgeDesc{1, 2, 4, EdgeKind::midi, 0});
        d.edges.push_back(EdgeDesc{2, 4, 1, EdgeKind::audio, 0});
        d.notes.push_back(NoteDesc{2, 0, 960, 60, 100, 0});
        return d;
    };
    DAW_CHECK(rig.publish(desc(R"({"zones": [{"assetID": 7, "rootKey": 60}]})")));
    auto node = rig.engine().nodes().get(4);
    DAW_CHECK(node != nullptr);
    if (node) {
        auto& sampler = static_cast<Sampler&>(*node);
        DAW_CHECK(sampler.zones().size() == 1 && sampler.zones()[0].playable);
    }
    // The fixture's sampler has no config at all (a new instance: configVersion bumped).
    DAW_CHECK(rig.publish(desc("", 2)));
    node = rig.engine().nodes().get(4);
    DAW_CHECK(node != nullptr && static_cast<Sampler&>(*node).zones().empty());

    DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
    rig.renderFrames(48000, [] { return 512u; });
    DAW_CHECK(rig.violations() == 0);

    // A bad config fails the build.
    auto bad = rig.build(desc(R"({"zones": [{"assetID": 7, "lowKey": 99, "highKey": 1}]})", 3));
    DAW_CHECK(!bad.ok() && bad.error().code == ErrorCode::invalidArgument);
    return checks;
}

} // namespace daw::testing
