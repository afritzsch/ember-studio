// T-012 checks for GraphDescription, GraphBuilder, GraphCompiler and the RenderGraph push ports.
// Run from Tests/DAWEngineTests/GraphTests.swift; see GraphChecks.h for why they're C++.

#include "GraphChecks.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <random>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#include <pthread.h>

#include "core/AudioBufferPool.h"
#include "core/Engine.h"
#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ProcessContext.h"
#include "core/Realtime.h"
#include "core/RenderGraph.h"
#include "core/RtTrap.h"
#include "daw/GraphDescription.h"
#include "graph/GraphBuilder.h"
#include "graph/GraphCompiler.h"
#include "graph/MasterNode.h"
#include "graph/NodeRegistry.h"
#include "graph/PassThrough.h"
#include "graph/TopoSort.h"

using namespace daw;
using namespace std::chrono_literals;

namespace daw::testing {

namespace {

// MARK: Harness

constexpr double kRate = 48000.0;
constexpr uint32_t kBlock = 256;

std::string currentThreadName() {
    char name[64] = {};
    pthread_getname_np(pthread_self(), name, sizeof name);
    return name;
}

template <class F>
bool eventually(F done, std::chrono::milliseconds timeout = 5000ms) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (!done()) {
        if (std::chrono::steady_clock::now() > deadline) return false;
        std::this_thread::sleep_for(1ms);
    }
    return true;
}

bool reclaimPasses(const Engine& engine, uint64_t n) {
    const uint64_t start = engine.reclaimer().passes();
    return eventually([&] { return engine.reclaimer().passes() >= start + n; });
}

// Owns the channel memory a RenderTarget points at.
struct Output {
    explicit Output(uint32_t frames = kBlock, uint32_t channels = 2)
        : data(channels, std::vector<float>(frames, -99.0f)) {
        for (auto& channel : data) ptrs.push_back(channel.data());
        target.output = AudioBufferView{ptrs.data(), channels, frames};
    }
    Output(const Output&) = delete;
    Output& operator=(const Output&) = delete;

    // Every channel's first `frames` frames are within `tolerance` (relative) of `value`.
    bool all(float value, uint32_t frames = kBlock, double tolerance = 0.0) const {
        for (const auto& channel : data)
            for (uint32_t f = 0; f < frames; ++f) {
                const double diff = std::fabs(double(channel[f]) - value);
                if (!(diff <= tolerance * std::max(1.0, std::fabs(double(value))))) return false;
            }
        return true;
    }

    std::vector<std::vector<float>> data;
    std::vector<float*> ptrs;
    RenderTarget target;
};

// One render inside the caller's own RtScope; returns what that scope counted (DW-019).
uint64_t renderCounted(Engine& engine, Output& out, uint32_t frames = kBlock) {
    RtScope scope;
    engine.render(out.target, frames);
    return scope.violations();
}

// MARK: Test nodes (TEST-004 style; test builds only)

// What happened to one node instance, readable from the test thread.
struct Stats {
    std::atomic<int> prepares{0}, resets{0}, releases{0}, destroys{0};
    std::mutex mutex;
    PrepareInfo prepared{};
    std::string createThread, prepareThread, destroyThread;
};

// Every instance the test registry has created, per NodeID, oldest first.
class TestLog {
public:
    std::shared_ptr<Stats> add(NodeID id) {
        auto stats = std::make_shared<Stats>();
        std::lock_guard lock(mutex_);
        instances_[id].push_back(stats);
        return stats;
    }
    std::vector<std::shared_ptr<Stats>> of(NodeID id) const {
        std::lock_guard lock(mutex_);
        auto it = instances_.find(id);
        return it == instances_.end() ? std::vector<std::shared_ptr<Stats>>{} : it->second;
    }
    int creates(NodeID id) const { return static_cast<int>(of(id).size()); }
    std::shared_ptr<Stats> latest(NodeID id) const {
        auto all = of(id);
        return all.empty() ? nullptr : all.back();
    }

private:
    mutable std::mutex mutex_;
    std::map<NodeID, std::vector<std::shared_ptr<Stats>>> instances_;
};

class TestNode final : public Node {
public:
    enum class Mode { constant, pass, sidechainSum, midiOnly };

    TestNode(Mode mode, float value, std::shared_ptr<Stats> stats)
        : mode_(mode), value_(value), stats_(std::move(stats)), rt_(stats_.get()) {}
    ~TestNode() override {
        {
            std::lock_guard lock(stats_->mutex);
            stats_->destroyThread = currentThreadName();
        }
        stats_->destroys.fetch_add(1);
    }

    void prepare(const PrepareInfo& info) override {
        {
            std::lock_guard lock(stats_->mutex);
            stats_->prepared = info;
            stats_->prepareThread = currentThreadName();
        }
        stats_->prepares.fetch_add(1);
    }
    void release() override { stats_->releases.fetch_add(1); }
    void reset() DAW_RT override { rt_->resets.fetch_add(1, std::memory_order_relaxed); }

    void process(ProcessContext&, NodeIO& io) DAW_RT override {
        const AudioBufferView& out = io.audioOut;
        switch (mode_) {
        case Mode::constant:
            for (uint32_t c = 0; c < out.numChannels; ++c)
                for (uint32_t f = 0; f < out.numFrames; ++f) out.channels[c][f] = value_;
            break;
        case Mode::pass:
            passThrough(io);
            break;
        case Mode::sidechainSum:
            for (uint32_t c = 0; c < out.numChannels; ++c)
                for (uint32_t f = 0; f < out.numFrames; ++f) {
                    float x = 0.0f;
                    if (c < io.audioIn.numChannels) x += io.audioIn.channels[c][f];
                    if (c < io.sidechain.numChannels) x += io.sidechain.channels[c][f];
                    out.channels[c][f] = x;
                }
            break;
        case Mode::midiOnly:
            break;
        }
    }

private:
    Mode mode_;
    float value_;
    std::shared_ptr<Stats> stats_;
    Stats* rt_;  // the audio thread never touches the shared_ptr
};

// Sources (audioClipPlayer, sampler) output their configJSON parsed as a float; the effect kinds
// pass their input through; compressor outputs input + sidechain; midiClipPlayer has no audio
// output. bus and master are the engine's own (NodeRegistry::withBuiltins).
NodeRegistry testRegistry(std::shared_ptr<TestLog> log) {
    NodeRegistry registry = NodeRegistry::withBuiltins();
    auto factory = [log](TestNode::Mode mode) {
        return [log, mode](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> {
            auto stats = log->add(info.desc.id);
            {
                std::lock_guard lock(stats->mutex);
                stats->createThread = currentThreadName();
            }
            const float value = std::strtof(info.desc.configJSON.c_str(), nullptr);
            return std::unique_ptr<Node>(new TestNode(mode, value, std::move(stats)));
        };
    };
    using M = TestNode::Mode;
    (void)registry.set(NodeKind::audioClipPlayer, {factory(M::constant)});
    (void)registry.set(NodeKind::sampler, {factory(M::constant)});
    (void)registry.set(NodeKind::midiClipPlayer, {factory(M::midiOnly), false});
    for (NodeKind k : {NodeKind::channelStrip, NodeKind::gain, NodeKind::eq, NodeKind::delay, NodeKind::reverb})
        (void)registry.set(k, {factory(M::pass)});
    (void)registry.set(NodeKind::compressor, {factory(M::sidechainSum)});
    return registry;
}

// MARK: Descriptions

struct Desc {
    GraphDescription d{1, {}, {}, {}, {}, {{{0, 120.0}}, {{0, 4, 4}}}, 0};
    uint64_t nextEdge = 1;

    Desc& node(NodeID id, NodeKind kind, std::string config = {}, uint32_t version = 1,
               ParamID firstParam = 0, uint32_t numParams = 0) {
        d.nodes.push_back(NodeDesc{id, kind, version, firstParam, numParams, std::move(config)});
        return *this;
    }
    Desc& source(NodeID id, float value) { return node(id, NodeKind::audioClipPlayer, std::to_string(value)); }
    Desc& strip(NodeID id) { return node(id, NodeKind::channelStrip); }
    Desc& master(NodeID id, ParamID firstParam = 0, uint32_t numParams = 0) {
        d.master = id;
        return node(id, NodeKind::master, {}, 1, firstParam, numParams);
    }
    Desc& edge(NodeID from, NodeID to, EdgeKind kind = EdgeKind::audio, uint8_t port = 0) {
        d.edges.push_back(EdgeDesc{nextEdge++, from, to, kind, port});
        return *this;
    }
    Desc& chain(std::initializer_list<NodeID> ids) {
        const NodeID* prev = nullptr;
        for (const NodeID& id : ids) {
            if (prev) edge(*prev, id);
            prev = &id;
        }
        return *this;
    }
};

// What the test nodes compute (all channels, all frames carry one value): the oracle for
// summing and liveness checks.
double evaluate(const GraphDescription& d, NodeID id, std::unordered_map<NodeID, double>& memo) {
    if (auto it = memo.find(id); it != memo.end()) return it->second;
    const NodeDesc* node = nullptr;
    for (const NodeDesc& n : d.nodes)
        if (n.id == id) node = &n;
    double value = 0;
    switch (node->kind) {
    case NodeKind::audioClipPlayer:
    case NodeKind::sampler:
        value = std::strtof(node->configJSON.c_str(), nullptr);
        break;
    case NodeKind::midiClipPlayer:
        break;
    default:
        for (const EdgeDesc& e : d.edges) {
            if (e.to != id || e.kind == EdgeKind::midi) continue;
            if (e.kind == EdgeKind::sidechain && node->kind != NodeKind::compressor) continue;
            value += evaluate(d, e.from, memo);
        }
    }
    memo[id] = value;
    return value;
}

double evaluate(const GraphDescription& d) {
    std::unordered_map<NodeID, double> memo;
    return evaluate(d, d.master, memo);
}

// Max audio + sidechain edges into one node, and the most nodes on one path (MIX-003's bound).
uint32_t fanInPlusDepth(const GraphDescription& d) {
    std::unordered_map<NodeID, uint32_t> fanIn;
    for (const EdgeDesc& e : d.edges)
        if (e.kind != EdgeKind::midi) ++fanIn[e.to];
    uint32_t maxFanIn = 0;
    for (auto& [id, n] : fanIn) maxFanIn = std::max(maxFanIn, n);
    std::unordered_map<NodeID, uint32_t> depth;
    std::function<uint32_t(NodeID)> depthOf = [&](NodeID id) -> uint32_t {
        if (auto it = depth.find(id); it != depth.end()) return it->second;
        uint32_t best = 0;
        for (const EdgeDesc& e : d.edges)
            if (e.to == id && e.kind != EdgeKind::midi) best = std::max(best, depthOf(e.from));
        return depth[id] = best + 1;
    };
    uint32_t maxDepth = 0;
    for (const NodeDesc& n : d.nodes) maxDepth = std::max(maxDepth, depthOf(n.id));
    return maxFanIn + maxDepth;
}

// The step that renders `id`, or -1.
int stepOf(const RenderGraph& graph, const NodePool& pool, NodeID id) {
    const auto node = pool.get(id);
    for (uint32_t s = 0; s < graph.numSteps(); ++s)
        if (graph.node(s) == node.get()) return static_cast<int>(s);
    return -1;
}

std::unique_ptr<RenderGraph> take(Result<std::unique_ptr<RenderGraph>>&& r) {
    return r ? std::move(r).value() : nullptr;
}

bool failsWith(const Result<std::unique_ptr<RenderGraph>>& r, ErrorCode code) {
    return !r.ok() && r.error().code == code;
}

// MARK: Random graphs

// A random DAG of up to `maxNodes` nodes (test kinds, master last), then shuffled and given
// random IDs so the builder can't rely on description order.
GraphDescription randomGraph(std::mt19937& rng, uint32_t maxNodes) {
    auto uniform = [&](int lo, int hi) { return std::uniform_int_distribution<int>(lo, hi)(rng); };
    const uint32_t n = static_cast<uint32_t>(uniform(2, static_cast<int>(maxNodes)));
    Desc d;
    std::vector<NodeID> ids(n);
    std::vector<NodeKind> kinds(n);
    for (uint32_t i = 0; i < n; ++i) ids[i] = static_cast<NodeID>(i + 1) * 7919 % 1'000'003 + 1;
    std::vector<uint32_t> audio, midi;  // creation indices that produce audio / MIDI

    for (uint32_t i = 0; i + 1 < n; ++i) {
        const int roll = uniform(0, 99);
        NodeKind kind = roll < 30 ? NodeKind::audioClipPlayer
                        : roll < 58 ? NodeKind::channelStrip
                        : roll < 73 ? NodeKind::bus
                        : roll < 88 ? NodeKind::compressor
                        : roll < 94 ? NodeKind::midiClipPlayer
                                    : NodeKind::sampler;
        kinds[i] = kind;
        if (kind == NodeKind::audioClipPlayer || kind == NodeKind::sampler)
            d.node(ids[i], kind, std::to_string(0.25f * float(uniform(1, 4))));
        else
            d.node(ids[i], kind);
        if (kind == NodeKind::sampler && !midi.empty() && uniform(0, 1))
            d.edge(ids[midi[uniform(0, int(midi.size()) - 1)]], ids[i], EdgeKind::midi);
        if (kind == NodeKind::channelStrip || kind == NodeKind::bus || kind == NodeKind::compressor) {
            if (!audio.empty()) {
                for (int k = uniform(0, 3); k > 0; --k)
                    d.edge(ids[audio[uniform(0, int(audio.size()) - 1)]], ids[i]);
                if (kind == NodeKind::compressor)
                    for (int k = uniform(0, 2); k > 0; --k)
                        d.edge(ids[audio[uniform(0, int(audio.size()) - 1)]], ids[i], EdgeKind::sidechain);
            }
        }
        (kind == NodeKind::midiClipPlayer ? midi : audio).push_back(i);
    }
    d.master(ids[n - 1]);
    if (!audio.empty())
        for (int k = uniform(1, 4); k > 0; --k) d.edge(ids[audio[uniform(0, int(audio.size()) - 1)]], ids[n - 1]);

    std::shuffle(d.d.nodes.begin(), d.d.nodes.end(), rng);
    std::shuffle(d.d.edges.begin(), d.d.edges.end(), rng);
    return d.d;
}

// A random mixer-shaped project: up to `maxTracks` tracks (player → strip → master or a bus),
// up to 10 buses (bus → [compressor] → strip → master or an earlier bus), sends (gain → bus)
// and sidechains from track strips into bus compressors. Shuffled.
GraphDescription randomMixer(std::mt19937& rng, uint32_t maxTracks) {
    auto uniform = [&](int lo, int hi) { return std::uniform_int_distribution<int>(lo, hi)(rng); };
    Desc d;
    d.master(1);
    const int numBuses = uniform(0, 10);
    std::vector<NodeID> busInputs, compressors;
    for (int b = 0; b < numBuses; ++b) {
        const NodeID bus = 100 + b, comp = 150 + b, strip = 200 + b;
        d.node(bus, NodeKind::bus).strip(strip);
        if (uniform(0, 2) == 0) {
            d.node(comp, NodeKind::compressor).chain({bus, comp, strip});
            compressors.push_back(comp);
        } else {
            d.edge(bus, strip);
        }
        d.edge(strip, b == 0 || uniform(0, 1) ? NodeID{1} : busInputs[uniform(0, b - 1)]);
        busInputs.push_back(bus);
    }
    const int numTracks = uniform(1, static_cast<int>(maxTracks));
    for (int t = 0; t < numTracks; ++t) {
        const NodeID player = 1000 + t, strip = 2000 + t;
        d.source(player, 0.125f * float(t % 5 + 1)).strip(strip).edge(player, strip);
        d.edge(strip, busInputs.empty() || uniform(0, 1) ? NodeID{1} : busInputs[uniform(0, numBuses - 1)]);
        if (!busInputs.empty() && uniform(0, 3) == 0) {
            const NodeID send = 3000 + t;
            d.node(send, NodeKind::gain).chain({strip, send, busInputs[uniform(0, numBuses - 1)]});
        }
        if (!compressors.empty() && uniform(0, 9) == 0)
            d.edge(strip, compressors[uniform(0, int(compressors.size()) - 1)], EdgeKind::sidechain);
    }
    std::shuffle(d.d.nodes.begin(), d.d.nodes.end(), rng);
    std::shuffle(d.d.edges.begin(), d.d.edges.end(), rng);
    return d.d;
}

} // namespace

// MARK: MIX-001

CheckResult graphBuildsAndRenders() {
    CheckResult checks;
    Engine engine;
    auto log = std::make_shared<TestLog>();
    GraphBuilder builder(testRegistry(log), 44100.0, 512);
    Desc d;
    d.master(1).source(10, 0.25f).strip(11).chain({10, 11, 1});
    d.d.version = 7;

    auto graph = take(builder.build(d.d, engine.nodes(), engine.params()));
    DAW_CHECK(graph != nullptr);
    if (!graph) return checks;
    DAW_CHECK(graph->numSteps() == 3);
    DAW_CHECK(graph->sampleRate() == 44100.0 && graph->maxBlock() == 512);
    DAW_CHECK(graph->version() == 7);
    DAW_CHECK(engine.nodes().size() == 3);
    // ENG-013: created through the registry and prepared at the builder's format, before publish.
    for (NodeID id : {NodeID{10}, NodeID{11}}) {
        DAW_CHECK(log->creates(id) == 1);
        auto stats = log->latest(id);
        DAW_CHECK(stats && stats->prepares == 1);
        if (!stats) continue;
        std::lock_guard lock(stats->mutex);
        DAW_CHECK(stats->prepared.sampleRate == 44100.0 && stats->prepared.maxBlock == 512);
        DAW_CHECK(stats->prepared.numIn == 2 && stats->prepared.numOut == 2);
    }
    // MIX-009: the master runs last; the order follows the edges.
    DAW_CHECK(stepOf(*graph, engine.nodes(), 10) == 0);
    DAW_CHECK(stepOf(*graph, engine.nodes(), 11) == 1);
    DAW_CHECK(stepOf(*graph, engine.nodes(), 1) == 2);

    engine.publish(std::move(graph));
    Output out(512);
    DAW_CHECK(renderCounted(engine, out, 512) == 0);
    DAW_CHECK(out.all(0.25f, 512));
    return checks;
}

CheckResult graphCompilesOnCompileThread() {
    CheckResult checks;
    Engine engine;
    auto log = std::make_shared<TestLog>();
    auto describe = [](uint64_t version, float value) {
        Desc d;
        d.master(1).source(10, value).strip(11).chain({10, 11, 1});
        d.d.version = version;
        d.d.nodes[1].configVersion = static_cast<uint32_t>(version);  // a new source each time
        return d.d;
    };
    {
        GraphCompiler compiler(engine, testRegistry(log), kRate, kBlock);
        const uint64_t first = compiler.submit(describe(1, 0.5f));
        DAW_CHECK(compiler.wait(first, 5000ms));
        auto status = compiler.status();
        DAW_CHECK(status.completed == first && status.publishedVersion == 1 && !status.lastError);
        // MIX-001: built (factory and prepare included) on daw.compile.
        if (auto stats = log->latest(10)) {
            std::lock_guard lock(stats->mutex);
            DAW_CHECK(stats->createThread == "daw.compile");
            DAW_CHECK(stats->prepareThread == "daw.compile");
        } else {
            DAW_CHECK(!"source was never created");
        }
        Output out;
        DAW_CHECK(renderCounted(engine, out) == 0);
        DAW_CHECK(out.all(0.5f));

        // A failing description is reported and leaves the published graph alone.
        GraphDescription cyclic = describe(2, 0.75f);
        cyclic.edges.push_back({99, 11, 10, EdgeKind::audio, 0});
        const uint64_t bad = compiler.submit(cyclic);
        DAW_CHECK(compiler.wait(bad, 5000ms));
        status = compiler.status();
        DAW_CHECK(status.publishedVersion == 1);
        DAW_CHECK(status.lastError && status.lastError->code == ErrorCode::invalidArgument);
        DAW_CHECK(renderCounted(engine, out) == 0);
        DAW_CHECK(out.all(0.5f));

        // A burst coalesces; the last description wins.
        uint64_t last = 0;
        for (uint64_t v = 3; v <= 20; ++v) last = compiler.submit(describe(v, 0.0625f * float(v)));
        DAW_CHECK(compiler.wait(last, 5000ms));
        status = compiler.status();
        DAW_CHECK(status.completed == last && status.publishedVersion == 20 && !status.lastError);
        DAW_CHECK(renderCounted(engine, out) == 0);
        DAW_CHECK(out.all(0.0625f * 20));
    }
    return checks;
}

CheckResult graphRejectsMalformed() {
    CheckResult checks;
    Engine engine;
    auto log = std::make_shared<TestLog>();
    GraphBuilder builder(testRegistry(log), kRate, kBlock);
    auto build = [&](const Desc& d) { return builder.build(d.d, engine.nodes(), engine.params()); };
    auto base = [] {
        Desc d;
        d.master(1).source(10, 0.5f).strip(11).chain({10, 11, 1});
        return d;
    };

    { Desc d = base(); d.source(10, 1.0f); DAW_CHECK(failsWith(build(d), ErrorCode::invalidArgument)); }  // duplicate ID
    { Desc d = base(); d.node(20, NodeKind::auPlugin); DAW_CHECK(failsWith(build(d), ErrorCode::unsupported)); }
    { Desc d = base(); d.node(20, static_cast<NodeKind>(999)); DAW_CHECK(failsWith(build(d), ErrorCode::unsupported)); }
    { Desc d = base(); d.edge(10, 42); DAW_CHECK(failsWith(build(d), ErrorCode::invalidArgument)); }   // unknown node
    { Desc d = base(); d.d.edges.push_back(d.d.edges[0]); DAW_CHECK(failsWith(build(d), ErrorCode::invalidArgument)); }  // edge ID
    { Desc d = base(); d.d.edges[0].kind = static_cast<EdgeKind>(9); DAW_CHECK(failsWith(build(d), ErrorCode::invalidArgument)); }
    // MIX-004: toPort is 0 for every edge kind in v1.
    { Desc d = base(); d.d.edges[0].toPort = 1; DAW_CHECK(failsWith(build(d), ErrorCode::invalidArgument)); }
    { Desc d = base(); d.edge(10, 1, EdgeKind::sidechain, 1); DAW_CHECK(failsWith(build(d), ErrorCode::invalidArgument)); }
    { Desc d = base(); d.node(20, NodeKind::midiClipPlayer).node(21, NodeKind::sampler).edge(20, 21, EdgeKind::midi, 2);
      DAW_CHECK(failsWith(build(d), ErrorCode::invalidArgument)); }
    // Audio out of a MIDI-only node.
    { Desc d = base(); d.node(20, NodeKind::midiClipPlayer).edge(20, 11); DAW_CHECK(failsWith(build(d), ErrorCode::invalidArgument)); }
    { Desc d = base(); d.node(20, NodeKind::midiClipPlayer).edge(20, 11, EdgeKind::sidechain);
      DAW_CHECK(failsWith(build(d), ErrorCode::invalidArgument)); }
    // MIX-009: exactly one master, of kind master, with nothing after it.
    { Desc d = base(); d.edge(1, 11); DAW_CHECK(failsWith(build(d), ErrorCode::invalidArgument)); }
    { Desc d = base(); d.d.master = 0; DAW_CHECK(failsWith(build(d), ErrorCode::invalidArgument)); }
    { Desc d = base(); d.d.master = 11; DAW_CHECK(failsWith(build(d), ErrorCode::invalidArgument)); }
    { Desc d = base(); d.node(2, NodeKind::master); DAW_CHECK(failsWith(build(d), ErrorCode::invalidArgument)); }
    { Desc d; d.d.master = 5; DAW_CHECK(failsWith(build(d), ErrorCode::invalidArgument)); }
    // TIME-003: the tempo map is checked too.
    { Desc d = base(); d.d.tempo.tempos.clear(); DAW_CHECK(failsWith(build(d), ErrorCode::invalidArgument)); }
    { Desc d = base(); d.d.tempo.timeSigs[0].den = 3; DAW_CHECK(failsWith(build(d), ErrorCode::invalidArgument)); }

    // Nothing above reached the pool.
    DAW_CHECK(engine.nodes().size() == 0);
    DAW_CHECK(log->creates(10) == 0);

    // An empty description is a graph that renders silence (ENG-015 shape).
    auto empty = take(build(Desc{}));
    DAW_CHECK(empty && empty->numSteps() == 0 && empty->master(64).empty());
    engine.publish(std::move(empty));
    Output out;
    DAW_CHECK(renderCounted(engine, out) == 0);
    DAW_CHECK(out.all(0.0f));
    return checks;
}

// MARK: MIX-002

CheckResult graphCycleRejected() {
    CheckResult checks;
    Engine engine;
    auto log = std::make_shared<TestLog>();
    GraphBuilder builder(testRegistry(log), kRate, kBlock);
    auto message = [&](const Desc& d) -> std::string {
        auto r = builder.build(d.d, engine.nodes(), engine.params());
        if (r.ok() || r.error().code != ErrorCode::invalidArgument) return "<no error>";
        return r.error().message;
    };

    // 1 → [2 → 3 → 4 → 2] → 5 → master: only 2, 3, 4 are on the cycle.
    {
        Desc d;
        d.master(100).source(1, 1).strip(2).strip(3).strip(4).strip(5);
        d.chain({1, 2, 3, 4, 2}).chain({4, 5, 100});
        DAW_CHECK(message(d) == "cycle: 2, 3, 4");
    }
    // Self-loop.
    {
        Desc d;
        d.master(100).source(1, 1).strip(6).chain({1, 6, 6, 100});
        DAW_CHECK(message(d) == "cycle: 6");
    }
    // A sidechain edge closes it.
    {
        Desc d;
        d.master(100).node(2, NodeKind::compressor).strip(3).source(1, 1);
        d.chain({1, 2, 3, 100}).edge(3, 2, EdgeKind::sidechain);
        DAW_CHECK(message(d) == "cycle: 2, 3");
    }
    // So does a MIDI edge.
    {
        Desc d;
        d.master(100).strip(2).strip(3).source(1, 1);
        d.chain({1, 2, 3, 100}).edge(3, 2, EdgeKind::midi);
        DAW_CHECK(message(d) == "cycle: 2, 3");
    }
    // Two cycles and the path between them; the tail after them is left out.
    {
        Desc d;
        d.master(100).strip(2).strip(3).strip(4).strip(5).strip(6).source(1, 1);
        d.chain({1, 2, 3, 2}).chain({3, 4, 5, 4}).chain({5, 6, 100});
        DAW_CHECK(message(d) == "cycle: 2, 3, 4, 5");
    }
    DAW_CHECK(engine.nodes().size() == 0);  // rejected before any node was made
    return checks;
}

CheckResult topoSortRandomDAGs() {
    CheckResult checks;
    std::mt19937 rng(12);
    for (int iteration = 0; iteration < 500; ++iteration) {
        const uint32_t n = std::uniform_int_distribution<uint32_t>(1, 60)(rng);
        std::vector<uint32_t> rank(n);  // a hidden topological order
        for (uint32_t i = 0; i < n; ++i) rank[i] = i;
        std::shuffle(rank.begin(), rank.end(), rng);
        std::vector<uint32_t> byRank(n);
        for (uint32_t i = 0; i < n; ++i) byRank[rank[i]] = i;
        std::vector<TopoEdge> edges;
        const uint32_t numEdges = std::uniform_int_distribution<uint32_t>(0, 3 * n)(rng);
        for (uint32_t e = 0; e < numEdges && n > 1; ++e) {
            uint32_t a = std::uniform_int_distribution<uint32_t>(0, n - 1)(rng);
            uint32_t b = std::uniform_int_distribution<uint32_t>(0, n - 1)(rng);
            if (a == b) continue;
            if (a > b) std::swap(a, b);
            edges.push_back({byRank[a], byRank[b]});  // forward in the hidden order
        }
        const uint32_t last = byRank[n - 1];  // a sink by construction

        TopoSortResult sorted = topoSort(n, edges, last);
        DAW_CHECK(sorted.cycle.empty());
        DAW_CHECK(sorted.order.size() == n);
        if (sorted.order.size() != n) continue;
        std::vector<uint32_t> pos(n, kNoNode);
        for (uint32_t i = 0; i < n; ++i) pos[sorted.order[i]] = i;
        DAW_CHECK(std::find(pos.begin(), pos.end(), kNoNode) == pos.end());  // a permutation
        for (const TopoEdge& e : edges) DAW_CHECK(pos[e.from] < pos[e.to]);
        DAW_CHECK(sorted.order.back() == last);

        // Plant a cycle among three nodes: those three (at least) are reported, and only nodes
        // that really are on or between cycles.
        if (n >= 3) {
            auto cyclic = edges;
            cyclic.push_back({byRank[n - 1], byRank[0]});
            cyclic.push_back({byRank[0], byRank[n / 2]});
            cyclic.push_back({byRank[n / 2], byRank[n - 1]});
            TopoSortResult bad = topoSort(n, cyclic);
            DAW_CHECK(bad.order.empty());
            for (uint32_t r : {0u, n / 2, n - 1})
                DAW_CHECK(std::binary_search(bad.cycle.begin(), bad.cycle.end(), byRank[r]));
        }
    }
    return checks;
}

// MARK: MIX-003

CheckResult bufferLivenessHundredTracks() {
    CheckResult checks;
    Engine engine;
    auto log = std::make_shared<TestLog>();
    std::mt19937 rng(100);

    auto track = [](Desc& d, uint32_t i) {  // player → strip; returns the strip
        const NodeID player = 1000 + i, strip = 2000 + i;
        d.source(player, 0.125f * float(i % 7 + 1)).strip(strip).edge(player, strip);
        return strip;
    };
    std::vector<Desc> shapes;
    {   // Flat: every track straight into the master.
        Desc d;
        d.master(1);
        for (uint32_t i = 0; i < 100; ++i) d.edge(track(d, i), 1);
        shapes.push_back(d);
    }
    {   // Grouped: 10 buses of 10 tracks, bus → bus strip → master.
        Desc d;
        d.master(1);
        for (uint32_t b = 0; b < 10; ++b) {
            const NodeID bus = 100 + b, busStrip = 200 + b;
            d.node(bus, NodeKind::bus).strip(busStrip).chain({bus, busStrip, 1});
            for (uint32_t i = 0; i < 10; ++i) d.edge(track(d, b * 10 + i), bus);
        }
        shapes.push_back(d);
    }
    {   // Mixed: 60 direct, 40 in 4 buses (one with a compressor keyed from track 0), every
        // track sending to a reverb bus. Shuffled, so description order doesn't help.
        Desc d;
        d.master(1).node(300, NodeKind::bus).node(301, NodeKind::reverb).strip(302).chain({300, 301, 302, 1});
        for (uint32_t b = 0; b < 4; ++b) {
            const NodeID bus = 100 + b, busStrip = 200 + b;
            d.node(bus, NodeKind::bus).strip(busStrip);
            if (b == 0) d.node(150, NodeKind::compressor).chain({bus, 150, busStrip});
            else d.edge(bus, busStrip);
            d.edge(busStrip, 1);
        }
        for (uint32_t i = 0; i < 100; ++i) {
            const NodeID strip = track(d, i), send = 3000 + i;
            d.edge(strip, i < 60 ? NodeID{1} : NodeID{100 + (i - 60) / 10});
            d.node(send, NodeKind::gain).chain({strip, send, 300});
        }
        d.edge(2000, 150, EdgeKind::sidechain);
        std::shuffle(d.d.nodes.begin(), d.d.nodes.end(), rng);
        std::shuffle(d.d.edges.begin(), d.d.edges.end(), rng);
        shapes.push_back(d);
    }

    for (size_t i = 0; i < shapes.size(); ++i) {
        GraphBuilder builder(testRegistry(log), kRate, kBlock);
        auto graph = take(builder.build(shapes[i].d, engine.nodes(), engine.params()));
        DAW_CHECK(graph != nullptr);
        if (!graph) continue;
        const uint32_t buffers = graph->buffers().numBuffers();
        DAW_CHECK(buffers <= fanInPlusDepth(shapes[i].d));  // MIX-003 acceptance
        // Pushed summing keeps it near the depth (3 for flat, 5 for grouped), not the fan-in.
        DAW_CHECK(i != 0 || buffers <= 4);
        DAW_CHECK(i != 1 || buffers <= 6);
        engine.publish(std::move(graph));
        Output out;
        DAW_CHECK(renderCounted(engine, out) == 0);
        DAW_CHECK(out.all(static_cast<float>(evaluate(shapes[i].d)), kBlock, 1e-6));
        engine.publish(nullptr);
        engine.nodes().clear();
    }
    return checks;
}

CheckResult bufferLivenessRandomMixers() {
    CheckResult checks;
    Engine engine;
    auto log = std::make_shared<TestLog>();
    std::mt19937 rng(5);
    Output out(64);
    for (int iteration = 0; iteration < 200; ++iteration) {
        const GraphDescription desc = randomMixer(rng, 100);
        GraphBuilder builder(testRegistry(log), kRate, 64);
        auto graph = take(builder.build(desc, engine.nodes(), engine.params()));
        DAW_CHECK(graph != nullptr);
        if (!graph) continue;
        DAW_CHECK(graph->buffers().numBuffers() <= fanInPlusDepth(desc));  // MIX-003
        engine.publish(std::move(graph));
        DAW_CHECK(renderCounted(engine, out, 64) == 0);
        DAW_CHECK(out.all(static_cast<float>(evaluate(desc)), 64, 1e-6));
        engine.nodes().clear();
    }
    return checks;
}

CheckResult bufferLivenessRandomGraphs() {
    CheckResult checks;
    Engine engine;
    auto log = std::make_shared<TestLog>();
    std::mt19937 rng(3);
    Output out(64);
    for (int iteration = 0; iteration < 300; ++iteration) {
        const GraphDescription desc = randomGraph(rng, 40);
        GraphBuilder builder(testRegistry(log), kRate, 64);
        auto graph = take(builder.build(desc, engine.nodes(), engine.params()));
        DAW_CHECK(graph != nullptr);
        if (!graph) continue;
        engine.publish(std::move(graph));
        DAW_CHECK(renderCounted(engine, out, 64) == 0);
        DAW_CHECK(out.all(static_cast<float>(evaluate(desc)), 64, 1e-5));
        engine.nodes().clear();
    }
    return checks;
}

// MARK: MIX-004

CheckResult summingAndPorts() {
    CheckResult checks;
    Engine engine;
    auto log = std::make_shared<TestLog>();
    GraphBuilder builder(testRegistry(log), kRate, kBlock);
    Desc d;
    d.master(1);
    // Two tracks into a bus, plus one direct: 0.25 + 0.5 + 1.
    d.source(10, 0.25f).source(11, 0.5f).node(20, NodeKind::bus).source(12, 1.0f);
    d.chain({10, 20, 1}).edge(11, 20).edge(12, 1);
    // Sidechain feeds the sidechain port: comp(0.125 main, 2 sidechain) = 2.125.
    d.source(13, 0.125f).source(14, 2.0f).node(30, NodeKind::compressor);
    d.chain({13, 30, 1}).edge(14, 30, EdgeKind::sidechain);
    // One producer into both ports of a node: 4 + 4.
    d.source(15, 4.0f).node(31, NodeKind::compressor).chain({15, 31, 1}).edge(15, 31, EdgeKind::sidechain);
    // Two parallel edges into one port sum twice; fan-out to two buses: 8·2 + 16·2.
    d.source(16, 8.0f).node(21, NodeKind::bus).chain({16, 21, 1}).edge(16, 21);
    d.source(17, 16.0f).node(22, NodeKind::bus).node(23, NodeKind::bus);
    d.chain({17, 22, 1}).chain({17, 23, 1});

    const float expected = 0.25f + 0.5f + 1.0f + 2.125f + 8.0f + 16.0f + 32.0f;
    DAW_CHECK(evaluate(d.d) == expected);
    auto graph = take(builder.build(d.d, engine.nodes(), engine.params()));
    DAW_CHECK(graph != nullptr);
    engine.publish(std::move(graph));
    Output out;
    DAW_CHECK(renderCounted(engine, out) == 0);
    DAW_CHECK(out.all(expected));
    // A second block sums afresh rather than accumulating onto the last one.
    DAW_CHECK(renderCounted(engine, out) == 0);
    DAW_CHECK(out.all(expected));
    return checks;
}

// MARK: MIX-009

CheckResult masterNodeAndLimiter() {
    CheckResult checks;
    Engine engine;
    auto log = std::make_shared<TestLog>();
    GraphBuilder builder(testRegistry(log), kRate, kBlock);
    Output out;

    // Off by default: a master without params never clips. Listed first, with a dangling
    // track that doesn't reach it, and still the last step.
    {
        Desc d;
        d.master(1).source(10, 1.5f).edge(10, 1).source(20, 9.0f).strip(21).edge(20, 21);
        auto graph = take(builder.build(d.d, engine.nodes(), engine.params()));
        DAW_CHECK(graph != nullptr);
        if (!graph) return checks;
        DAW_CHECK(stepOf(*graph, engine.nodes(), 1) == static_cast<int>(graph->numSteps()) - 1);
        engine.publish(std::move(graph));
        DAW_CHECK(renderCounted(engine, out) == 0);
        DAW_CHECK(out.all(1.5f));
    }

    // With a limiter param: off at 0, on at 1 (no rebuild), clips both ways and NaN.
    auto param = engine.params().allocate(1, 0.0f);
    DAW_CHECK(param.ok());
    if (!param) return checks;
    for (float value : {1.5f, -3.0f, std::nanf("")}) {
        Desc d;
        d.master(1, param.value(), 1).node(10, NodeKind::audioClipPlayer, std::isnan(value) ? "nan" : std::to_string(value));
        d.edge(10, 1);
        d.d.nodes[1].configVersion = static_cast<uint32_t>(log->creates(10) + 1);
        engine.params().set(param.value(), 0.0f);
        auto graph = take(builder.build(d.d, engine.nodes(), engine.params()));
        DAW_CHECK(graph != nullptr);
        engine.publish(std::move(graph));
        auto* master = static_cast<MasterNode*>(engine.nodes().get(1).get());
        const uint64_t before = master->clippedSamples();  // the master instance is reused

        DAW_CHECK(renderCounted(engine, out) == 0);
        DAW_CHECK(std::isnan(value) ? std::isnan(out.data[0][0]) : out.all(value));
        DAW_CHECK(master->clippedSamples() == before);

        engine.params().set(param.value(), 1.0f);
        DAW_CHECK(renderCounted(engine, out) == 0);
        DAW_CHECK(out.all(std::isnan(value) ? 0.0f : value > 0 ? 1.0f : -1.0f));
        DAW_CHECK(master->clippedSamples() == before + 2 * kBlock);  // every sample, both channels
    }

    // In range: untouched and not counted.
    {
        Desc d;
        d.master(1, param.value(), 1).source(10, -1.0f).edge(10, 1);
        d.d.nodes[1].configVersion = 100;
        auto graph = take(builder.build(d.d, engine.nodes(), engine.params()));
        engine.publish(std::move(graph));
        auto* master = static_cast<MasterNode*>(engine.nodes().get(1).get());
        const uint64_t before = master->clippedSamples();
        DAW_CHECK(renderCounted(engine, out) == 0);
        DAW_CHECK(out.all(-1.0f));
        DAW_CHECK(master->clippedSamples() == before);
    }
    return checks;
}

// MARK: DW-036, DW-030

CheckResult nodeInstancesAcrossBuilds() {
    CheckResult checks;
    Engine engine;
    auto log = std::make_shared<TestLog>();
    GraphBuilder builder(testRegistry(log), kRate, kBlock);
    NodePool& pool = engine.nodes();
    auto build = [&](const Desc& d) { return take(builder.build(d.d, pool, engine.params())); };

    Desc v1;
    v1.master(1).source(10, 0.5f).strip(11).strip(12).chain({10, 11, 12, 1});
    auto g1 = build(v1);
    DAW_CHECK(g1 != nullptr);
    engine.publish(std::move(g1));
    const Node* source = pool.get(10).get();
    const Node* strip11 = pool.get(11).get();
    auto old11 = log->latest(11);
    auto old12 = log->latest(12);

    // Same description: every instance reused, nothing re-created or re-prepared.
    auto same = build(v1);
    DAW_CHECK(same != nullptr);
    DAW_CHECK(pool.get(10).get() == source && pool.get(11).get() == strip11);
    DAW_CHECK(log->creates(10) == 1 && log->latest(10)->prepares == 1);
    same.reset();  // never published, so it can go here

    // v2: strip 11's config changes, 12 goes, 13 comes.
    Desc v2;
    v2.master(1).source(10, 0.5f).node(11, NodeKind::channelStrip, {}, 2).strip(13).chain({10, 11, 13, 1});
    auto g2 = build(v2);
    DAW_CHECK(g2 != nullptr);
    DAW_CHECK(pool.get(10).get() == source);           // unchanged: reused
    DAW_CHECK(log->creates(10) == 1 && log->latest(10)->prepares == 1);
    DAW_CHECK(pool.get(11).get() != strip11);          // new instance under the same ID…
    DAW_CHECK(log->creates(11) == 2 && log->latest(11)->prepares == 1);  // …prepared before publish
    DAW_CHECK(old11->prepares == 1);                   // the live one was never re-prepared
    DAW_CHECK(pool.get(12) == nullptr);                // dropped from the pool…
    DAW_CHECK(pool.get(13) != nullptr);
    DAW_CHECK(reclaimPasses(engine, 2));
    DAW_CHECK(old11->releases == 0 && old11->destroys == 0);  // …but g1 still renders them
    DAW_CHECK(old12->releases == 0 && old12->destroys == 0);

    // A failed build changes nothing.
    {
        Desc broken = v2;
        broken.edge(13, 11);
        DAW_CHECK(!builder.build(broken.d, pool, engine.params()).ok());
        DAW_CHECK(pool.size() == 4 && pool.get(13) != nullptr);
    }

    engine.publish(std::move(g2));
    Output out;
    DAW_CHECK(renderCounted(engine, out) == 0);
    DAW_CHECK(out.all(0.5f));
    // g1 is retired: its nodes that no pool or graph holds are released and destroyed on reclaim.
    DAW_CHECK(eventually([&] { return old11->destroys == 1 && old12->destroys == 1; }));
    DAW_CHECK(old11->releases == 1 && old12->releases == 1);
    {
        std::lock_guard lock(old12->mutex);
        DAW_CHECK(old12->destroyThread == "daw.reclaim");
    }
    DAW_CHECK(log->latest(10)->destroys == 0);

    // A param range change also needs a new instance (the node captured its ParamIDs), and so
    // does a kind change.
    auto params = engine.params().allocate(2);
    DAW_CHECK(params.ok());
    Desc v3 = v2;
    v3.d.nodes[2].firstParam = params.value();
    v3.d.nodes[2].numParams = 2;
    v3.d.nodes[3].kind = NodeKind::gain;
    const Node* strip11v2 = pool.get(11).get();
    const Node* strip13 = pool.get(13).get();
    auto g3 = build(v3);
    DAW_CHECK(g3 != nullptr);
    DAW_CHECK(pool.get(11).get() != strip11v2 && log->creates(11) == 3);
    DAW_CHECK(pool.get(13).get() != strip13 && log->creates(13) == 2);
    DAW_CHECK(pool.get(10).get() == source);
    engine.publish(std::move(g3));
    return checks;
}

CheckResult paramRangesValidated() {
    CheckResult checks;
    Engine engine;
    auto log = std::make_shared<TestLog>();
    GraphBuilder builder(testRegistry(log), kRate, kBlock);
    ParamSlotTable& params = engine.params();
    auto build = [&](ParamID first, uint32_t count) {
        Desc d;
        d.master(1).node(10, NodeKind::channelStrip, {}, 1, first, count).source(11, 1).chain({11, 10, 1});
        return builder.build(d.d, engine.nodes(), params);
    };

    const uint32_t capacity = params.capacity();
    DAW_CHECK(failsWith(build(capacity - 1, 2), ErrorCode::invalidArgument));       // past the end
    DAW_CHECK(failsWith(build(capacity, 1), ErrorCode::invalidArgument));
    DAW_CHECK(failsWith(build(0xFFFF'FFFFu, 2), ErrorCode::invalidArgument));       // wraps in 32 bits
    DAW_CHECK(failsWith(build(10, 1), ErrorCode::invalidArgument));                 // never allocated
    auto range = params.allocate(4);
    DAW_CHECK(range.ok());
    if (!range) return checks;
    DAW_CHECK(params.free(range.value() + 3, 1).ok());
    DAW_CHECK(failsWith(build(range.value(), 4), ErrorCode::invalidArgument));      // last one freed
    DAW_CHECK(engine.nodes().size() == 0);  // rejected before any node was made

    DAW_CHECK(build(range.value(), 3).ok());
    DAW_CHECK(build(0xFFFF'FFFFu, 0).ok());  // no params: firstParam is ignored
    return checks;
}

// MARK: TIME-003, TIME-008 hooks

CheckResult tempoMapAndLocateReset() {
    CheckResult checks;
    Engine engine;
    auto log = std::make_shared<TestLog>();
    GraphBuilder builder(testRegistry(log), 44100.0, kBlock);

    Desc d;
    d.master(1).source(10, 0.5f).strip(11).chain({10, 11, 1});
    d.node(20, NodeKind::midiClipPlayer).node(21, NodeKind::sampler, "0.25").strip(22);
    d.chain({21, 22, 1}).edge(20, 21, EdgeKind::midi);
    d.d.tempo = {{{0, 120.0}, {1920, 60.0}}, {{0, 4, 4}}};
    // List the sampler before its MIDI source: the MIDI edge must still order them.
    std::swap(d.d.nodes[3], d.d.nodes[4]);

    auto graph = take(builder.build(d.d, engine.nodes(), engine.params()));
    DAW_CHECK(graph != nullptr);
    if (!graph) return checks;

    // TIME-003: built at the builder's rate and owned by the graph.
    const TempoMap& tempo = graph->tempoMap();
    DAW_CHECK(tempo.sampleRate() == 44100.0);
    DAW_CHECK(tempo.tickToSample(960) == 22050);
    DAW_CHECK(tempo.tickToSample(1920 + 960) == 44100 + 44100);

    const NodePool& pool = engine.nodes();
    DAW_CHECK(stepOf(*graph, pool, 20) < stepOf(*graph, pool, 21));  // MIDI edges order nodes

    // TIME-008: exactly the clip players are flagged, and only they are reset.
    for (NodeID id : {NodeID{1}, NodeID{10}, NodeID{11}, NodeID{20}, NodeID{21}, NodeID{22}}) {
        const int step = stepOf(*graph, pool, id);
        DAW_CHECK(step >= 0);
        if (step >= 0)
            DAW_CHECK(graph->resetsOnLocate(static_cast<uint32_t>(step)) == (id == 10 || id == 20));
    }
    uint64_t violations = 99;
    {
        RtScope scope;
        graph->resetTimelineNodes();
        violations = scope.violations();
    }
    DAW_CHECK(violations == 0);
    DAW_CHECK(log->latest(10)->resets == 1 && log->latest(20)->resets == 1);
    DAW_CHECK(log->latest(11)->resets == 0 && log->latest(21)->resets == 0 && log->latest(22)->resets == 0);

    // The MIDI-only node gets no audio buffer, and the graph still renders.
    engine.publish(std::move(graph));
    Output out;
    DAW_CHECK(renderCounted(engine, out) == 0);
    DAW_CHECK(out.all(0.75f));

    // RenderGraph::create on its own: default map at the graph's rate; a map at another rate
    // is rejected.
    auto make = [](std::optional<TempoMap> tempo) {
        RenderGraphDesc desc;
        desc.sampleRate = 44100.0;
        desc.maxBlock = 128;
        desc.tempo = std::move(tempo);
        return RenderGraph::create(std::move(desc));
    };
    auto plain = make(std::nullopt);
    DAW_CHECK(plain.ok());
    if (plain) {
        DAW_CHECK(plain.value()->tempoMap().sampleRate() == 44100.0);
        DAW_CHECK(plain.value()->tempoMap().bpmAt(0) == 120.0);
    }
    DAW_CHECK(!make(TempoMap()).ok());  // 48 kHz
    return checks;
}

// MARK: RenderGraph push ports

CheckResult renderGraphFeedValidation() {
    CheckResult checks;
    auto log = std::make_shared<TestLog>();
    auto node = [&](TestNode::Mode mode, float value) {
        auto n = std::make_shared<TestNode>(mode, value, log->add(0));
        n->prepare({kRate, kBlock, 2, 2});
        return std::shared_ptr<Node>(std::move(n));
    };
    using M = TestNode::Mode;
    auto step = [](std::shared_ptr<Node> n, uint32_t output, RenderPortDesc input = {},
                   std::vector<RenderFeedDesc> feeds = {}, RenderPortDesc sidechain = {}) {
        RenderStepDesc s;
        s.node = std::move(n);
        s.output = output;
        s.input = std::move(input);
        s.sidechain = std::move(sidechain);
        s.feeds = std::move(feeds);
        return s;
    };
    auto create = [](std::vector<RenderStepDesc> steps, uint32_t numBuffers, uint32_t master) {
        RenderGraphDesc desc;
        desc.maxBlock = kBlock;
        desc.buffers = std::move(AudioBufferPool::create(numBuffers, 2, kBlock)).value();
        desc.steps = std::move(steps);
        desc.master = master;
        return RenderGraph::create(std::move(desc));
    };
    auto a = node(M::constant, 0.25f), b = node(M::constant, 0.5f), pass = node(M::pass, 0);

    // 0.25 copied, 0.5 added into buffer 1, which the last step reads; buffer 0 is reused.
    auto ok = create({step(a, 0, {}, {{1, false}}), step(b, 2, {}, {{1, true}}),
                      step(pass, 0, {{}, 1, true})},
                     3, 0);
    DAW_CHECK(ok.ok());
    if (ok) {
        Engine engine;
        engine.publish(std::move(ok).value());
        Output out;
        for (int block = 0; block < 3; ++block) {
            DAW_CHECK(renderCounted(engine, out) == 0);
            DAW_CHECK(out.all(0.75f));
        }
    }

    DAW_CHECK(!create({step(pass, 0, {{1}, 2, true})}, 3, 0).ok());               // fed with sources
    DAW_CHECK(!create({step(pass, 0, {{}, kNoBuffer, true})}, 3, 0).ok());        // fed, no buffer
    DAW_CHECK(!create({step(pass, 0, {{}, 0, true})}, 3, 0).ok());                // fed buffer is the output
    DAW_CHECK(!create({step(pass, 0, {{}, 1, true}, {}, {{}, 0, true})}, 3, 0).ok());  // sidechain too
    DAW_CHECK(!create({step(a, kNoBuffer, {}, {{1, false}})}, 3, 0).ok());        // feed without output
    DAW_CHECK(!create({step(a, 0, {}, {{7, false}})}, 3, 0).ok());                // feed out of range
    DAW_CHECK(!create({step(a, 0, {}, {{0, false}})}, 3, 0).ok());                // feed into own output
    DAW_CHECK(create({step(pass, 0, {{}, 1, true}, {{1, false}})}, 3, 0).ok());   // into its read input: fine
    // Pull ports: the main gather buffer can't be a sidechain source (gathered first).
    DAW_CHECK(!create({step(a, 1), step(pass, 0, {{1}, 2}, {}, {{2}, 3})}, 4, 0).ok());
    return checks;
}

} // namespace daw::testing
