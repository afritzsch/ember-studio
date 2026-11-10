// T-064 checks for host-side bypass (10 PLUG-018). Run from Tests/DAWEngineTests/BypassTests.swift;
// see BypassChecks.h for why they're C++.

#include "BypassChecks.h"

#include <atomic>
#include <cmath>
#include <cstdio>
#include <memory>
#include <random>
#include <string>
#include <vector>

#include "core/Engine.h"
#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ProcessContext.h"
#include "core/Realtime.h"
#include "core/RenderGraph.h"
#include "core/RtTrap.h"
#include "daw/GraphDescription.h"
#include "graph/BypassNode.h"
#include "graph/GraphBuilder.h"
#include "graph/NodeRegistry.h"
#include "graph/PassThrough.h"

using namespace daw;

namespace daw::testing {

namespace {

constexpr double kRate = 48000.0;
constexpr uint32_t kBlock = 256;

// "noise <seed>": deterministic white noise in ±0.5, the same on both channels; two nodes with the
// same seed play the same signal. "dc <level>": a constant.
class SourceNode final : public Node {
public:
    explicit SourceNode(const std::string& config) {
        char kind[16] = {};
        double a = 0;
        std::sscanf(config.c_str(), "%15s %lf", kind, &a);
        dc_ = std::string(kind) == "dc";
        if (dc_) level_ = static_cast<float>(a);
        else state_ = static_cast<uint32_t>(a) * 2654435761u + 1;
    }
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext&, NodeIO& io) DAW_RT override {
        const AudioBufferView& out = io.audioOut;
        for (uint32_t f = 0; f < out.numFrames; ++f) {
            float x = level_;
            if (!dc_) {
                state_ = state_ * 1664525u + 1013904223u;
                x = static_cast<float>(state_ >> 8) / static_cast<float>(1u << 24) - 0.5f;
            }
            for (uint32_t c = 0; c < out.numChannels; ++c) out.channels[c][f] = x;
        }
    }

private:
    bool dc_ = false;
    float level_ = 0;
    uint32_t state_ = 1;
};

struct EffectStats {
    std::atomic<int> creates{0};
    std::atomic<uint64_t> processed{0};
    std::atomic<uint32_t> latency{0};  // the latest node's, settable by the test (MIX-024 style)
};

// "<latency> <gain>": its input delayed by `latency` and scaled by `gain`, a latent plugin
// stand-in whose own output is easy to tell from the dry signal (gain 0: silence).
class LatentEffect final : public Node {
public:
    static constexpr uint32_t kCapacity = 1u << 14;

    LatentEffect(const std::string& config, std::shared_ptr<EffectStats> stats) : stats_(std::move(stats)) {
        unsigned latency = 0;
        double gain = 1;
        std::sscanf(config.c_str(), "%u %lf", &latency, &gain);
        gain_ = static_cast<float>(gain);
        stats_->latency.store(latency);
        stats_->creates.fetch_add(1);
    }
    void prepare(const PrepareInfo&) override { ring_.assign(2 * kCapacity, 0.0f); }
    uint32_t latencySamples() const override { return stats_->latency.load(); }
    void process(ProcessContext&, NodeIO& io) DAW_RT override {
        stats_->processed.fetch_add(1, std::memory_order_relaxed);
        const uint32_t delay = stats_->latency.load(std::memory_order_relaxed) & (kCapacity - 1);
        const AudioBufferView& out = io.audioOut;
        for (uint32_t c = 0; c < out.numChannels && c < 2; ++c) {
            float* ring = ring_.data() + std::size_t{c} * kCapacity;
            const float* in = c < io.audioIn.numChannels ? io.audioIn.channels[c] : nullptr;
            for (uint32_t f = 0; f < out.numFrames; ++f) {
                const uint32_t at = write_ + f;
                ring[at & (kCapacity - 1)] = in ? in[f] : 0.0f;
                out.channels[c][f] = gain_ * ring[(at - delay) & (kCapacity - 1)];
            }
        }
        write_ += out.numFrames;
    }

private:
    std::shared_ptr<EffectStats> stats_;
    float gain_ = 1;
    std::vector<float> ring_;
    uint32_t write_ = 0;
};

// "<gain>" (default 1): input × gain; -1 inverts the phase.
class GainRouting final : public Node {
public:
    explicit GainRouting(const std::string& config) {
        if (!config.empty()) gain_ = std::stof(config);
    }
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext&, NodeIO& io) DAW_RT override {
        passThrough(io);
        const AudioBufferView& out = io.audioOut;
        for (uint32_t c = 0; c < out.numChannels; ++c)
            for (uint32_t f = 0; f < out.numFrames; ++f) out.channels[c][f] *= gain_;
    }

private:
    float gain_ = 1;
};

// sampler: SourceNode; delay: LatentEffect; channelStrip: GainRouting; master: the engine's.
NodeRegistry bypassRegistry(const std::shared_ptr<EffectStats>& stats) {
    NodeRegistry registry = NodeRegistry::withBuiltins();
    (void)registry.set(NodeKind::sampler, {[](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> {
                           return std::unique_ptr<Node>(new SourceNode(info.desc.configJSON));
                       }});
    (void)registry.set(NodeKind::delay, {[stats](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> {
                           return std::unique_ptr<Node>(new LatentEffect(info.desc.configJSON, stats));
                       }});
    (void)registry.set(NodeKind::channelStrip, {[](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> {
                           return std::unique_ptr<Node>(new GainRouting(info.desc.configJSON));
                       }});
    return registry;
}

struct Desc {
    GraphDescription d{1, {}, {}, {}, {}, {{{0, 120.0}}, {{0, 4, 4}}}, 0};
    uint64_t nextEdge = 1;

    Desc& node(NodeID id, NodeKind kind, std::string config = {}, ParamID bypass = kNoBypassParam) {
        d.nodes.push_back(NodeDesc{id, kind, 1, 0, 0, std::move(config), bypass});
        return *this;
    }
    Desc& master(NodeID id) {
        d.master = id;
        return node(id, NodeKind::master);
    }
    Desc& chain(std::initializer_list<NodeID> ids) {
        const NodeID* prev = nullptr;
        for (const NodeID& id : ids) {
            if (prev) d.edges.push_back(EdgeDesc{nextEdge++, *prev, id, EdgeKind::audio, 0});
            prev = &id;
        }
        return *this;
    }
};

// The null graph: noise(10) → effect(20, bypassable) → strip(21) → master(1), and the same noise
// (11) → strip(22, × -1) → master. PDC delays the plain path by the effect's latency.
Desc nullGraph(const std::string& effect, ParamID bypass) {
    Desc d;
    d.master(1)
        .node(10, NodeKind::sampler, "noise 7")
        .node(11, NodeKind::sampler, "noise 7")
        .node(20, NodeKind::delay, effect, bypass)
        .node(21, NodeKind::channelStrip)
        .node(22, NodeKind::channelStrip, "-1");
    d.chain({10, 20, 21, 1}).chain({11, 22, 1});
    return d;
}

class Capture {
public:
    void render(Engine& engine, uint32_t frames) {
        std::vector<float> l(frames, -99.0f), r(frames, -99.0f);
        float* ptrs[2] = {l.data(), r.data()};
        RenderTarget target;
        target.output = AudioBufferView{ptrs, 2, frames};
        {
            RtScope scope;
            engine.render(target, frames);
            violations += scope.violations();
        }
        left.insert(left.end(), l.begin(), l.end());
        right.insert(right.end(), r.begin(), r.end());
    }
    void renderRandom(Engine& engine, uint32_t total, std::mt19937& rng) {
        std::uniform_int_distribution<uint32_t> size(0, kBlock);
        for (uint32_t done = 0; done < total;) {
            const uint32_t n = std::min(size(rng), total - done);
            render(engine, n);
            done += n;
        }
    }
    void clear() {
        left.clear();
        right.clear();
    }
    // Largest |sample| in [from, to) of both channels.
    float peak(size_t from = 0, size_t to = SIZE_MAX) const {
        float p = 0;
        for (size_t f = from; f < std::min(to, left.size()); ++f)
            p = std::max({p, std::fabs(left[f]), std::fabs(right[f])});
        return p;
    }

    std::vector<float> left, right;
    uint64_t violations = 0;
};

bool publish(GraphBuilder& builder, Engine& engine, const GraphDescription& d, uint32_t* latency = nullptr) {
    auto graph = builder.build(d, engine.nodes(), engine.params());
    if (!graph) return false;
    if (latency) *latency = graph.value()->latency();
    engine.publish(std::move(graph).value());
    return true;
}

ParamID allocate(Engine& engine, float value) {
    auto id = engine.params().allocate(1, value);
    return id ? id.value() : kNoBypassParam;
}

} // namespace

// MARK: PLUG-018

CheckResult bypassLatentNull() {
    CheckResult checks;
    auto stats = std::make_shared<EffectStats>();
    Engine engine;
    GraphBuilder builder(bypassRegistry(stats), kRate, kBlock);
    const ParamID bypass = allocate(engine, 1.0f);
    DAW_CHECK(bypass != kNoBypassParam);

    uint32_t latency = 0;
    DAW_CHECK(publish(builder, engine, nullGraph("700 0", bypass).d, &latency));
    DAW_CHECK(latency == 700);  // PDC sees the effect's latency while it is bypassed
    std::mt19937 rng(64);
    Capture out;
    out.renderRandom(engine, 48000, rng);
    // Bypassed: the input delayed by exactly the latency PDC planned with, so the plain inverted
    // path cancels it sample for sample.
    DAW_CHECK(out.peak() == 0.0f);
    DAW_CHECK(stats->processed.load() == 0);  // never run while bypassed

    // Un-bypass with a slot write (no rebuild): the effect (× 0) runs; only the plain path is left.
    engine.params().set(bypass, 0.0f);
    out.clear();
    out.renderRandom(engine, 48000, rng);
    DAW_CHECK(out.peak(kBlock) > 0.4f);
    DAW_CHECK(stats->processed.load() > 0);

    // Bypass again: after the one crossfade block it nulls again.
    engine.params().set(bypass, 1.0f);
    out.clear();
    out.renderRandom(engine, 48000, rng);
    DAW_CHECK(out.peak(kBlock) == 0.0f);
    const uint64_t processed = stats->processed.load();
    out.renderRandom(engine, 4800, rng);
    DAW_CHECK(stats->processed.load() == processed);

    // Same latency either way, and one instance through all of it (no rebuild re-created it).
    engine.params().set(bypass, 0.0f);
    DAW_CHECK(publish(builder, engine, nullGraph("700 0", bypass).d, &latency));
    DAW_CHECK(latency == 700);
    DAW_CHECK(stats->creates.load() == 1);

    // Without a bypass slot the same description doesn't wrap the node.
    auto plain = builder.build(nullGraph("700 0", kNoBypassParam).d, engine.nodes(), engine.params());
    DAW_CHECK(plain.ok() && plain.value()->latency() == 700);
    DAW_CHECK(out.violations == 0);
    return checks;
}

CheckResult bypassCrossfadeAndRebuild() {
    CheckResult checks;

    // A toggle is a one-block linear crossfade: DC 1 into a (latency 0, × 0) effect.
    {
        auto stats = std::make_shared<EffectStats>();
        Engine engine;
        GraphBuilder builder(bypassRegistry(stats), kRate, kBlock);
        const ParamID bypass = allocate(engine, 0.0f);
        Desc d;
        d.master(1).node(10, NodeKind::sampler, "dc 1").node(20, NodeKind::delay, "0 0", bypass).chain({10, 20, 1});
        DAW_CHECK(publish(builder, engine, d.d));
        Capture out;
        out.render(engine, 100);
        DAW_CHECK(out.peak() == 0.0f);
        engine.params().set(bypass, 1.0f);
        out.clear();
        out.render(engine, 100);
        out.render(engine, 100);
        bool ramp = true;
        for (size_t f = 0; f < 100; ++f) ramp = ramp && std::fabs(out.left[f] - float(f + 1) / 100.0f) < 1e-6f;
        DAW_CHECK(ramp);
        DAW_CHECK(out.left[150] == 1.0f && out.right[199] == 1.0f);
        engine.params().set(bypass, 0.0f);
        out.clear();
        out.render(engine, 50);
        ramp = true;
        for (size_t f = 0; f < 50; ++f) ramp = ramp && std::fabs(out.left[f] - (1.0f - float(f + 1) / 50.0f)) < 1e-6f;
        DAW_CHECK(ramp);
        // NaN in the slot (never written) counts as not bypassed.
        engine.params().set(bypass, std::nanf(""));
        out.clear();
        out.render(engine, 50);
        DAW_CHECK(out.peak() == 0.0f);
        DAW_CHECK(out.violations == 0);
    }

    // A rebuild while bypassed carries the delay line over: bit-identical to no rebuild.
    {
        std::vector<float> reference;
        for (int rebuild = 0; rebuild < 2; ++rebuild) {
            auto stats = std::make_shared<EffectStats>();
            Engine engine;
            GraphBuilder builder(bypassRegistry(stats), kRate, kBlock);
            const ParamID bypass = allocate(engine, 1.0f);
            Desc d;
            d.master(1).node(10, NodeKind::sampler, "noise 3").node(20, NodeKind::delay, "300 0.5", bypass);
            d.chain({10, 20, 1});
            DAW_CHECK(publish(builder, engine, d.d));
            Capture out;
            for (int block = 0; block < 60; ++block) {
                if (rebuild && block % 3 == 2) {
                    ++d.d.version;
                    DAW_CHECK(publish(builder, engine, d.d));
                }
                out.render(engine, 97);
            }
            if (!rebuild) reference = out.left;
            else DAW_CHECK(out.left == reference);
            DAW_CHECK(out.peak() > 0.4f);
            DAW_CHECK(out.violations == 0);
        }
    }

    // A latency that outgrows the line (MIX-024 rebuild) gets a new one and stays aligned.
    {
        auto stats = std::make_shared<EffectStats>();
        Engine engine;
        GraphBuilder builder(bypassRegistry(stats), kRate, kBlock);
        const ParamID bypass = allocate(engine, 1.0f);
        Desc d = nullGraph("300 0", bypass);
        DAW_CHECK(publish(builder, engine, d.d));
        std::mt19937 rng(5);
        Capture out;
        out.renderRandom(engine, 4800, rng);
        DAW_CHECK(out.peak() == 0.0f);
        stats->latency.store(5000);
        ++d.d.version;
        uint32_t latency = 0;
        DAW_CHECK(publish(builder, engine, d.d, &latency));
        DAW_CHECK(latency == 5000);
        out.clear();
        out.renderRandom(engine, 24000, rng);
        DAW_CHECK(out.peak(6000) == 0.0f);  // both paths' new lines are full by then
        DAW_CHECK(out.violations == 0);
    }

    // An unallocated bypass slot is rejected before anything is touched.
    {
        auto stats = std::make_shared<EffectStats>();
        Engine engine;
        GraphBuilder builder(bypassRegistry(stats), kRate, kBlock);
        auto rejected = builder.build(nullGraph("10 1", 4000).d, engine.nodes(), engine.params());
        DAW_CHECK(!rejected.ok() && rejected.error().code == ErrorCode::invalidArgument);
        DAW_CHECK(stats->creates.load() == 0);
    }
    return checks;
}

} // namespace daw::testing
