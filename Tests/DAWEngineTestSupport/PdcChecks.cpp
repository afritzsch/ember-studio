// T-021 checks for PDC (05 MIX-020..024). Run from Tests/DAWEngineTests/PdcTests.swift; see
// PdcChecks.h for why they're C++.

#include "PdcChecks.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <numbers>
#include <random>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#include "NodeTestHarness.h"
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
#include "graph/NodeRegistry.h"
#include "graph/PassThrough.h"
#include "io/OfflineDriver.h"
#include "nodes/BuiltinNodes.h"
#include "time/TransportSegments.h"

using namespace daw;
using namespace std::chrono_literals;

namespace daw::testing {

namespace {

constexpr double kRate = 48000.0;

template <class F>
bool eventually(F done, std::chrono::milliseconds timeout = 5000ms) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (!done()) {
        if (std::chrono::steady_clock::now() > deadline) return false;
        std::this_thread::sleep_for(1ms);
    }
    return true;
}

// MARK: Test nodes (TEST-004 style; test builds only)

// TEST-004 FakeLatencyNode(n): delays its main input by latencySamples() and reports it. The
// latency may change after prepare (MIX-024): the delay follows from the next block, and the
// node tells the engine through the LatencyReporter its factory got.
class FakeLatencyNode final : public Node {
public:
    static constexpr uint32_t kCapacity = 1u << 16;  // the longest delay it can apply

    FakeLatencyNode(uint32_t latency, LatencyReporter reporter)
        : latency_(latency), reporter_(std::move(reporter)) {}

    void prepare(const PrepareInfo&) override { ring_.assign(2 * kCapacity, 0.0f); }
    uint32_t latencySamples() const override { return latency_.load(std::memory_order_relaxed); }

    // Non-RT, test thread.
    void setLatency(uint32_t latency) {
        latency_.store(latency, std::memory_order_relaxed);
        reporter_.changed();
    }

    void process(ProcessContext&, NodeIO& io) DAW_RT override {
        const uint32_t delay = latency_.load(std::memory_order_relaxed) & (kCapacity - 1);
        const AudioBufferView& out = io.audioOut;
        for (uint32_t c = 0; c < out.numChannels && c < 2; ++c) {
            float* ring = ring_.data() + std::size_t{c} * kCapacity;
            const float* in = c < io.audioIn.numChannels ? io.audioIn.channels[c] : nullptr;
            for (uint32_t f = 0; f < out.numFrames; ++f) {
                const uint32_t at = write_ + f;
                ring[at & (kCapacity - 1)] = in ? in[f] : 0.0f;
                out.channels[c][f] = ring[(at - delay) & (kCapacity - 1)];
            }
        }
        write_ += out.numFrames;
    }

private:
    std::atomic<uint32_t> latency_;
    LatencyReporter reporter_;
    std::vector<float> ring_;
    uint32_t write_ = 0;
};

// Free-running sources: they count the frames they have rendered, whatever the transport does.
//   "impulse <first> <period> <amp>": amp at frames first, first + period, … (period 0: once)
//   "sine <hz> <amp>"
class SourceNode final : public Node {
public:
    explicit SourceNode(const std::string& config) {
        char kind[16] = {};
        double a = 0, b = 0, c = 0;
        std::sscanf(config.c_str(), "%15s %lf %lf %lf", kind, &a, &b, &c);
        sine_ = std::string(kind) == "sine";
        if (sine_) {
            hz_ = a;
            amp_ = static_cast<float>(b);
        } else {
            first_ = static_cast<uint64_t>(a);
            period_ = static_cast<uint64_t>(b);
            amp_ = static_cast<float>(c);
        }
    }
    void prepare(const PrepareInfo&) override {}

    void process(ProcessContext&, NodeIO& io) DAW_RT override {
        const AudioBufferView& out = io.audioOut;
        for (uint32_t f = 0; f < out.numFrames; ++f) {
            const uint64_t n = frame_ + f;
            float x = 0.0f;
            if (sine_) {
                x = amp_ * static_cast<float>(std::sin(2.0 * std::numbers::pi * hz_ * double(n) / kRate));
            } else if (n == first_ || (period_ > 0 && n > first_ && (n - first_) % period_ == 0)) {
                x = amp_;
            }
            for (uint32_t c = 0; c < out.numChannels; ++c) out.channels[c][f] = x;
        }
        frame_ += out.numFrames;
    }

private:
    bool sine_ = false;
    double hz_ = 0;
    float amp_ = 0;
    uint64_t first_ = 0, period_ = 0, frame_ = 0;
};

// A timeline node (registered as audioClipPlayer, so the graph schedules it early): every frame
// a segment covers carries its timeline sample position + 1, so silence (0) stands out.
class TimelineProbe final : public Node {
public:
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        const AudioBufferView& out = io.audioOut;
        for (uint32_t c = 0; c < out.numChannels; ++c)
            for (uint32_t f = 0; f < out.numFrames; ++f) out.channels[c][f] = 0.0f;
        forEachSegment(ctx.transport, [&](const TransportSegment& seg) DAW_RT {
            for (uint32_t c = 0; c < out.numChannels; ++c)
                for (uint32_t i = 0; i < seg.numFrames; ++i)
                    out.channels[c][seg.frameOffset + i] = static_cast<float>(seg.startSample + i + 1);
        });
    }
};

class RoutingNode final : public Node {
public:
    explicit RoutingNode(bool sidechainSum) : sidechainSum_(sidechainSum) {}
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext&, NodeIO& io) DAW_RT override {
        passThrough(io);
        if (!sidechainSum_) return;
        const AudioBufferView& out = io.audioOut;
        for (uint32_t c = 0; c < out.numChannels && c < io.sidechain.numChannels; ++c)
            for (uint32_t f = 0; f < out.numFrames; ++f) out.channels[c][f] += io.sidechain.channels[c][f];
    }

private:
    bool sidechainSum_;
};

// The latest FakeLatencyNode each NodeID got, for MIX-024.
class LatencyNodes {
public:
    void add(NodeID id, FakeLatencyNode* node) {
        std::lock_guard lock(mutex_);
        nodes_[id] = node;
        ++creates_[id];
    }
    FakeLatencyNode* get(NodeID id) const {
        std::lock_guard lock(mutex_);
        auto it = nodes_.find(id);
        return it == nodes_.end() ? nullptr : it->second;
    }
    int creates(NodeID id) const {
        std::lock_guard lock(mutex_);
        auto it = creates_.find(id);
        return it == creates_.end() ? 0 : it->second;
    }

private:
    mutable std::mutex mutex_;
    std::map<NodeID, FakeLatencyNode*> nodes_;
    std::map<NodeID, int> creates_;
};

// sampler: SourceNode(configJSON); delay: FakeLatencyNode(configJSON); audioClipPlayer:
// TimelineProbe; channelStrip, gain, bus (built in): pass through; compressor: input +
// sidechain; midiClipPlayer: no audio. master is the engine's own.
NodeRegistry pdcRegistry(std::shared_ptr<LatencyNodes> latencyNodes = std::make_shared<LatencyNodes>()) {
    NodeRegistry registry = NodeRegistry::withBuiltins();
    auto make = [](auto f) {
        return [f](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> { return f(info); };
    };
    (void)registry.set(NodeKind::sampler, {make([](const NodeCreateInfo& info) {
                           return std::unique_ptr<Node>(new SourceNode(info.desc.configJSON));
                       })});
    (void)registry.set(NodeKind::delay, {make([latencyNodes](const NodeCreateInfo& info) {
                           const auto n = static_cast<uint32_t>(std::stoul(info.desc.configJSON));
                           auto node = std::make_unique<FakeLatencyNode>(n, info.latency);
                           latencyNodes->add(info.desc.id, node.get());
                           return std::unique_ptr<Node>(std::move(node));
                       })});
    (void)registry.set(NodeKind::audioClipPlayer, {make([](const NodeCreateInfo&) {
                           return std::unique_ptr<Node>(new TimelineProbe);
                       })});
    for (NodeKind k : {NodeKind::channelStrip, NodeKind::gain})
        (void)registry.set(k, {make([](const NodeCreateInfo&) {
                               return std::unique_ptr<Node>(new RoutingNode(false));
                           })});
    (void)registry.set(NodeKind::compressor, {make([](const NodeCreateInfo&) {
                           return std::unique_ptr<Node>(new RoutingNode(true));
                       })});
    (void)registry.set(NodeKind::midiClipPlayer, {make([](const NodeCreateInfo&) {
                                                      return std::unique_ptr<Node>(new RoutingNode(false));
                                                  }),
                                                  false});
    return registry;
}

// MARK: Descriptions

struct Desc {
    GraphDescription d{1, {}, {}, {}, {}, {{{0, 120.0}}, {{0, 4, 4}}}, 0};
    uint64_t nextEdge = 1;

    Desc& node(NodeID id, NodeKind kind, std::string config = {}) {
        d.nodes.push_back(NodeDesc{id, kind, 1, 0, 0, std::move(config)});
        return *this;
    }
    Desc& impulse(NodeID id, uint64_t first, float amp, uint64_t period = 0) {
        return node(id, NodeKind::sampler,
                    "impulse " + std::to_string(first) + " " + std::to_string(period) + " " + std::to_string(amp));
    }
    Desc& sine(NodeID id, double hz, float amp) {
        return node(id, NodeKind::sampler, "sine " + std::to_string(hz) + " " + std::to_string(amp));
    }
    Desc& latency(NodeID id, uint32_t samples) { return node(id, NodeKind::delay, std::to_string(samples)); }
    Desc& probe(NodeID id) { return node(id, NodeKind::audioClipPlayer); }
    Desc& strip(NodeID id) { return node(id, NodeKind::channelStrip); }
    Desc& master(NodeID id) {
        d.master = id;
        return node(id, NodeKind::master);
    }
    Desc& edge(NodeID from, NodeID to, EdgeKind kind = EdgeKind::audio) {
        d.edges.push_back(EdgeDesc{nextEdge++, from, to, kind, 0});
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

const NodeDesc* findNode(const GraphDescription& d, NodeID id) {
    for (const NodeDesc& n : d.nodes)
        if (n.id == id) return &n;
    return nullptr;
}

// The oracles for impulse graphs: the summed amplitude reaching `id` (every path counts once),
// and its path latency computed straight from the definition (MIX-020), brute force.
double amplitude(const GraphDescription& d, NodeID id) {
    const NodeDesc* node = findNode(d, id);
    if (node->kind == NodeKind::sampler) {
        double first = 0, period = 0, amp = 0;
        std::sscanf(node->configJSON.c_str(), "impulse %lf %lf %lf", &first, &period, &amp);
        return amp;
    }
    double sum = 0;
    for (const EdgeDesc& e : d.edges)
        if (e.to == id && e.kind == EdgeKind::audio) sum += amplitude(d, e.from);
    return sum;
}

uint64_t pathLatency(const GraphDescription& d, NodeID id) {
    const NodeDesc* node = findNode(d, id);
    uint64_t arrival = 0;
    for (const EdgeDesc& e : d.edges)
        if (e.to == id) arrival = std::max(arrival, pathLatency(d, e.from));
    return arrival + (node->kind == NodeKind::delay ? std::stoul(node->configJSON) : 0);
}

// MARK: Rendering

// Renders into a growing stereo capture; every render runs in its own RtScope (DW-019).
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
    void renderBlocks(Engine& engine, int blocks, uint32_t frames) {
        for (int i = 0; i < blocks; ++i) render(engine, frames);
    }

    std::vector<float> left, right;
    uint64_t violations = 0;
};

std::unique_ptr<RenderGraph> take(Result<std::unique_ptr<RenderGraph>>&& r) {
    return r ? std::move(r).value() : nullptr;
}

bool publish(GraphBuilder& builder, Engine& engine, const GraphDescription& d) {
    auto graph = take(builder.build(d, engine.nodes(), engine.params()));
    if (!graph) return false;
    engine.publish(std::move(graph));
    return true;
}

// Applies queued transport commands with a 0-frame block.
void applyCommands(Engine& engine, Capture& capture) { capture.render(engine, 0); }

} // namespace

// MARK: MIX-020

CheckResult pdcPathLatency() {
    CheckResult checks;
    Engine engine;
    GraphBuilder builder(pdcRegistry(), kRate, 256);

    // A → strip → master                        path 0
    // B → lat 500 → strip → bus                  500
    // C → lat 200 → lat 100 → bus                300
    // bus → lat 50 → strip → master              max(500, 300) + 50 = 550
    Desc d;
    d.master(1).impulse(10, 10, 1.0f).impulse(20, 10, 2.0f).impulse(30, 10, 4.0f);
    d.strip(11).latency(21, 500).strip(22).latency(31, 200).latency(32, 100);
    d.node(40, NodeKind::bus).latency(41, 50).strip(42);
    d.chain({10, 11, 1}).chain({20, 21, 22, 40}).chain({30, 31, 32, 40}).chain({40, 41, 42, 1});

    auto graph = take(builder.build(d.d, engine.nodes(), engine.params()));
    DAW_CHECK(graph != nullptr);
    if (!graph) return checks;
    DAW_CHECK(graph->latency() == 550);
    std::map<NodeID, uint32_t> table;
    for (const NodeLatency& n : graph->nodeLatencies()) table[n.node] = n.samples;
    DAW_CHECK((table == std::map<NodeID, uint32_t>{{21, 500}, {31, 200}, {32, 100}, {41, 50}}));

    engine.publish(std::move(graph));
    Capture out;
    out.renderBlocks(engine, 4, 256);
    // MIX-021 on top: all three impulses (1 + 2 + 4) land together at 10 + 550.
    for (size_t f = 0; f < out.left.size(); ++f) {
        const float expected = f == 560 ? 7.0f : 0.0f;
        if (out.left[f] != expected || out.right[f] != expected) {
            DAW_CHECK(out.left[f] == expected);
            break;
        }
    }
    // ENG-050: the table and graph latency reach telemetry; outputLatency adds the device's.
    engine.telemetry().setDeviceOutputLatency(100);
    out.render(engine, 0);
    const TelemetrySnapshot snap = engine.telemetry().snapshot();
    DAW_CHECK(snap.graphLatency == 550 && snap.outputLatency == 650 && snap.numNodeLatencies == 4);
    NodeLatency entries[8] = {};
    const uint32_t n = engine.telemetry().nodeLatencies(entries, 8);
    std::map<NodeID, uint32_t> published;
    for (uint32_t i = 0; i < n; ++i) published[entries[i].node] = entries[i].samples;
    DAW_CHECK(published == table);

    // MIDI edges count toward arrival (the instrument's audio leaves that late): a 700-sample
    // node feeding a sampler over MIDI makes the graph latency 700.
    Desc m = d;
    m.latency(50, 700).impulse(51, 10, 8.0f).edge(50, 51, EdgeKind::midi).edge(51, 1);
    auto midi = take(builder.build(m.d, engine.nodes(), engine.params()));
    DAW_CHECK(midi && midi->latency() == 700);

    // Path latencies beyond kMaxGraphLatency are rejected.
    Desc big;
    big.master(1).impulse(10, 0, 1.0f);
    NodeID prev = 10;
    for (NodeID id = 100; id < 120; ++id) {
        big.latency(id, 60000).edge(prev, id);
        prev = id;
    }
    big.edge(prev, 1);
    auto rejected = builder.build(big.d, engine.nodes(), engine.params());
    DAW_CHECK(!rejected.ok() && rejected.error().code == ErrorCode::invalidArgument);

    // No graph: telemetry latency goes back to 0.
    engine.publish(nullptr);
    out.render(engine, 0);
    DAW_CHECK(engine.telemetry().snapshot().graphLatency == 0);
    DAW_CHECK(out.violations == 0);
    return checks;
}

// MARK: MIX-021

CheckResult pdcMergeAlignment() {
    CheckResult checks;
    uint64_t violations = 0;

    // Null test (the pdc_alignment_null golden's shape): A dry vs −A through 1000 samples.
    {
        Engine engine;
        GraphBuilder builder(pdcRegistry(), kRate, kMaxBlock);
        Desc d;
        d.master(1).sine(10, 440.0, 0.5f).sine(20, 440.0, -0.5f).latency(21, 1000);
        d.edge(10, 1).chain({20, 21, 1});
        DAW_CHECK(publish(builder, engine, d.d));
        std::mt19937 rng(0x0021);
        std::uniform_int_distribution<uint32_t> size(0, kMaxBlock);
        Capture out;
        while (out.left.size() < 48000) out.render(engine, size(rng));
        bool silent = true, sounding = false;
        for (size_t f = 0; f < out.left.size(); ++f) silent = silent && out.left[f] == 0.0f && out.right[f] == 0.0f;
        DAW_CHECK(silent);
        DAW_CHECK(engine.telemetry().snapshot().graphLatency == 1000);
        violations += out.violations;

        // Control: without the latent path the dry sine is there.
        Desc dry;
        dry.master(1).sine(10, 440.0, 0.5f).edge(10, 1);
        DAW_CHECK(publish(builder, engine, dry.d));
        Capture more;
        more.render(engine, 256);
        for (float x : more.left) sounding = sounding || x != 0.0f;
        DAW_CHECK(sounding);
        violations += more.violations;
    }

    // Sidechain merge: the main input and the sidechain line up, whichever is shorter.
    for (bool latentSidechain : {true, false}) {
        Engine engine;
        GraphBuilder builder(pdcRegistry(), kRate, 128);
        Desc d;
        d.master(1).impulse(10, 5, 1.0f).impulse(20, 5, 2.0f).latency(30, latentSidechain ? 300 : 120);
        d.node(40, NodeKind::compressor).edge(40, 1);
        if (latentSidechain) {
            d.edge(10, 40).edge(20, 30).edge(30, 40, EdgeKind::sidechain);
        } else {
            d.edge(10, 30).edge(30, 40).edge(20, 40, EdgeKind::sidechain);
        }
        DAW_CHECK(publish(builder, engine, d.d));
        Capture out;
        out.renderBlocks(engine, 4, 128);
        const size_t at = latentSidechain ? 305 : 125;
        bool aligned = true;
        for (size_t f = 0; f < out.left.size(); ++f) aligned = aligned && out.left[f] == (f == at ? 3.0f : 0.0f);
        DAW_CHECK(aligned);
        violations += out.violations;
    }

    // Random mixers: tracks (impulse → [latent insert] → strip → master or bus, optional send),
    // buses (bus → [latent insert] → strip → master or an earlier bus). Every impulse reaches
    // the master on one frame, 10 + the graph latency, which matches the brute-force path max.
    std::mt19937 rng(0x5EED21);
    auto uniform = [&](int lo, int hi) { return std::uniform_int_distribution<int>(lo, hi)(rng); };
    for (int iteration = 0; iteration < 40; ++iteration) {
        Desc d;
        d.master(1);
        const int numBuses = uniform(0, 6);
        std::vector<NodeID> buses;
        for (int b = 0; b < numBuses; ++b) {
            const NodeID bus = 100 + b, insert = 150 + b, strip = 200 + b;
            d.node(bus, NodeKind::bus).strip(strip);
            if (uniform(0, 1)) d.latency(insert, uniform(1, 400)).chain({bus, insert, strip});
            else d.edge(bus, strip);
            d.edge(strip, b == 0 || uniform(0, 1) ? NodeID{1} : buses[uniform(0, b - 1)]);
            buses.push_back(bus);
        }
        const int numTracks = uniform(1, 30);
        for (int t = 0; t < numTracks; ++t) {
            const NodeID player = 1000 + t, insert = 1500 + t, strip = 2000 + t, send = 3000 + t;
            d.impulse(player, 10, 0.125f * float(t % 4 + 1)).strip(strip);
            if (uniform(0, 2) == 0) d.latency(insert, uniform(1, 600)).chain({player, insert, strip});
            else d.edge(player, strip);
            d.edge(strip, buses.empty() || uniform(0, 1) ? NodeID{1} : buses[uniform(0, numBuses - 1)]);
            if (!buses.empty() && uniform(0, 3) == 0)
                d.node(send, NodeKind::gain).chain({strip, send, buses[uniform(0, numBuses - 1)]});
        }
        std::shuffle(d.d.nodes.begin(), d.d.nodes.end(), rng);
        std::shuffle(d.d.edges.begin(), d.d.edges.end(), rng);

        Engine engine;
        GraphBuilder builder(pdcRegistry(), kRate, 512);
        auto graph = take(builder.build(d.d, engine.nodes(), engine.params()));
        DAW_CHECK(graph != nullptr);
        if (!graph) break;
        const uint64_t latency = pathLatency(d.d, 1);
        DAW_CHECK(graph->latency() == latency);
        engine.publish(std::move(graph));
        Capture out;
        while (out.left.size() < latency + 10 + 600) out.render(engine, 512);
        const auto expected = static_cast<float>(amplitude(d.d, 1));
        bool aligned = true;
        for (size_t f = 0; f < out.left.size(); ++f)
            aligned = aligned && out.left[f] == (f == latency + 10 ? expected : 0.0f);
        DAW_CHECK(aligned);
        violations += out.violations;
        if (!aligned) break;
    }
    DAW_CHECK(violations == 0);
    return checks;
}

// MARK: MIX-022

CheckResult pdcDelayLinesCarryOver() {
    CheckResult checks;
    uint64_t violations = 0;
    // A (edge 1) is delayed 1000 samples to meet B's latent path at the master.
    Desc base;
    base.master(1).sine(10, 300.0, 0.5f).sine(20, 700.0, 0.25f).latency(21, 1000);
    base.edge(10, 1).chain({20, 21, 1});
    // The same routing plus an unrelated track: a structural rebuild.
    Desc grown = base;
    grown.d.version = 2;
    grown.sine(30, 50.0, 0.1f).strip(31).chain({30, 31});
    // Control: A's edge under a new ID (the line starts out silent).
    Desc renamed = base;
    renamed.d.version = 3;
    renamed.d.edges[0].edgeID = 99;

    constexpr uint32_t kFrames = 256;
    constexpr int kBefore = 20, kAfter = 20;
    auto run = [&](const Desc* rebuild) {
        Engine engine;
        GraphBuilder builder(pdcRegistry(), kRate, kFrames);
        Capture out;
        if (publish(builder, engine, base.d)) {
            out.renderBlocks(engine, kBefore, kFrames);
            if (rebuild && !publish(builder, engine, rebuild->d)) out.left.clear();
            out.renderBlocks(engine, kAfter, kFrames);
        }
        violations += out.violations;
        return out;
    };
    const Capture reference = run(nullptr);
    const Capture rebuilt = run(&grown);
    const Capture control = run(&renamed);
    DAW_CHECK(reference.left.size() == size_t{kBefore + kAfter} * kFrames);
    DAW_CHECK(rebuilt.left == reference.left && rebuilt.right == reference.right);  // no discontinuity
    // The control differs right after the rebuild: A's first 1000 delayed frames are silence.
    const size_t at = size_t{kBefore} * kFrames;
    DAW_CHECK(control.left.size() == reference.left.size());
    if (control.left.size() == reference.left.size()) {
        bool differs = false;
        for (size_t f = at; f < at + 1000; ++f) differs = differs || control.left[f] != reference.left[f];
        DAW_CHECK(differs);
        DAW_CHECK(std::equal(control.left.begin(), control.left.begin() + at, reference.left.begin()));
    }

    // During playback for real: a render thread plays while GraphCompiler rebuilds on daw.compile
    // (alternating descriptions that sound the same); the recording matches the reference.
    {
        Engine engine;
        auto compiler = std::make_unique<GraphCompiler>(engine, pdcRegistry(), kRate, kFrames);
        DAW_CHECK(compiler->wait(compiler->submit(base.d), 5000ms));
        std::atomic<uint64_t> threadViolations{0};
        std::vector<float> recording;
        recording.reserve(size_t{kBefore + kAfter} * kFrames);
        std::thread audio([&] {
            std::vector<float> l(kFrames), r(kFrames);
            float* ptrs[2] = {l.data(), r.data()};
            RenderTarget target;
            target.output = AudioBufferView{ptrs, 2, kFrames};
            uint64_t counted = 0;
            for (int block = 0; block < kBefore + kAfter; ++block) {
                {
                    RtScope scope;  // this thread's own count (DW-019)
                    engine.render(target, kFrames);
                    counted += scope.violations();
                }
                recording.insert(recording.end(), l.begin(), l.end());
                std::this_thread::sleep_for(200us);
            }
            threadViolations = counted;
        });
        for (int i = 0; i < 12; ++i) {
            Desc d = i % 2 ? base : grown;
            d.d.version = 10 + i;
            compiler->wait(compiler->submit(d.d), 5000ms);
            std::this_thread::sleep_for(500us);
        }
        audio.join();
        DAW_CHECK(!compiler->status().lastError.has_value());
        DAW_CHECK(compiler->status().publishedVersion == 21);
        DAW_CHECK(recording == reference.left);
        DAW_CHECK(threadViolations == 0);
        compiler.reset();
    }
    DAW_CHECK(violations == 0);
    return checks;
}

// MARK: MIX-023

CheckResult pdcSourcePreRoll() {
    CheckResult checks;
    Engine engine;
    GraphBuilder builder(pdcRegistry(), kRate, 512);
    // Two timeline probes: P behind 1500 samples of latency, Q dry (its edge gets the delay).
    // Heard at transport position s, the master carries 2 · (s + 1).
    Desc d;
    d.master(1).probe(10).latency(11, 1500).probe(20).chain({10, 11, 1}).edge(20, 1);
    DAW_CHECK(publish(builder, engine, d.d));
    Transport& transport = engine.transport();
    Capture out;

    // Expected output for `frames` frames of heard positions from `start`, looping on [ls, le).
    auto expect = [&](size_t from, SamplePos start, size_t frames, bool loop = false, SamplePos ls = 0,
                      SamplePos le = 0) {
        SamplePos pos = start;
        for (size_t f = from; f < from + frames; ++f) {
            const float want = 2.0f * static_cast<float>(pos + 1);
            if (f >= out.left.size() || out.left[f] != want || out.right[f] != want) return false;
            ++pos;
            if (loop && pos == le && start < le) pos = ls;
        }
        return true;
    };

    // Play from 0: the first frame is already position 0 (pre-roll filled the delays).
    DAW_CHECK(transport.play());
    out.renderBlocks(engine, 12, 256);
    DAW_CHECK(expect(0, 0, 12 * 256));
    DAW_CHECK(engine.telemetry().snapshot().graphLatency == 1500);

    // Locate while playing: exact again from the first frame after it.
    DAW_CHECK(transport.locate(4000));  // 100000 samples
    size_t mark = out.left.size();
    out.renderBlocks(engine, 8, 256);
    DAW_CHECK(expect(mark, 100000, 8 * 256));

    // A loop shorter than the latency: [1000, 1040) ticks = [25000, 26000) samples, from 24750.
    DAW_CHECK(transport.setLoop(true, 1000, 1040));
    DAW_CHECK(transport.locate(990));
    mark = out.left.size();
    out.renderBlocks(engine, 30, 256);
    DAW_CHECK(expect(mark, 24750, 30 * 256, true, 25000, 26000));

    // Stop and play again (a new run): pre-rolled, continuing from where it stopped.
    DAW_CHECK(transport.stop());
    applyCommands(engine, out);
    const SamplePos stoppedAt = transport.playhead().sample;
    out.renderBlocks(engine, 8, 256);  // stopped: probes silent, delays (1500) drain to 0
    DAW_CHECK(out.left.back() == 0.0f);
    DAW_CHECK(transport.play());
    mark = out.left.size();
    out.renderBlocks(engine, 10, 256);
    DAW_CHECK(expect(mark, stoppedAt, 10 * 256, true, 25000, 26000));

    // Without latency nothing runs ahead: a probe straight to the master is position + 1.
    DAW_CHECK(transport.setLoop(false, 0, 0));
    DAW_CHECK(transport.locate(0));
    Desc dry;
    dry.master(1).probe(10).edge(10, 1);
    DAW_CHECK(publish(builder, engine, dry.d));
    mark = out.left.size();
    out.renderBlocks(engine, 2, 256);
    bool exact = true;
    for (size_t f = 0; f < 512; ++f) exact = exact && out.left[mark + f] == static_cast<float>(f + 1);
    DAW_CHECK(exact);
    DAW_CHECK(engine.telemetry().snapshot().graphLatency == 0);
    DAW_CHECK(out.violations == 0);
    return checks;
}

CheckResult pdcClickOnBeatOne() {
    CheckResult checks;
    using nodes::makeAsset;
    std::map<uint64_t, AudioAssetRef> assets;
    assets[1] = makeAsset(1, 1, 100, [](uint32_t, int64_t i) { return i == 0 ? 1.0f : 0.0f; });
    Engine engine;
    NodeRegistry registry = NodeRegistry::withBuiltins();
    DAW_CHECK(registerBuiltinNodes(
                  registry,
                  [&](uint64_t id) -> AudioAssetRef {
                      auto it = assets.find(id);
                      return it == assets.end() ? AudioAssetRef{} : it->second;
                  },
                  &engine.telemetry())
                  .ok());
    // The latent "master plugin": a FakeLatencyNode in the master insert position.
    (void)registry.set(NodeKind::delay, {[](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> {
                           return std::unique_ptr<Node>(new FakeLatencyNode(2048, info.latency));
                       }});
    GraphBuilder builder(std::move(registry), kRate, kMaxBlock);

    GraphDescription d = nodes::baseDescription();
    d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
    d.nodes.push_back(NodeDesc{20, NodeKind::delay, 1, 0, 0, {}});
    d.edges.push_back(EdgeDesc{1, 10, 20, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{2, 20, 1, EdgeKind::audio, 0});
    d.audioClips.push_back(nodes::clip(10, 1, 0, 4, 1));      // beat 1
    d.audioClips.push_back(nodes::clip(10, 2, kPPQ, 4, 1));   // beat 2 = sample 24000
    auto graph = take(builder.build(d, engine.nodes(), engine.params()));
    DAW_CHECK(graph && graph->latency() == 2048);
    if (!graph) return checks;
    const TempoMap tempo = graph->tempoMap();
    engine.publish(std::move(graph));

    auto exportFrom = [&](Tick from, std::vector<float>& left, uint64_t& rtViolations) {
        ExportSpec spec;
        spec.tempo = tempo;
        spec.blockSize = 512;
        spec.tail.enabled = false;
        spec.sink = [&](const AudioBufferView& block) {
            left.insert(left.end(), block.channels[0], block.channels[0] + block.numFrames);
        };
        OfflineDriver driver;
        const bool ok = driver.render(engine, from, 2 * kPPQ, spec, nullptr).ok();
        rtViolations = driver.lastRender().rtViolations;
        return ok;
    };
    std::vector<float> first, again, late;
    uint64_t v1 = 1, v2 = 1, v3 = 1;
    DAW_CHECK(exportFrom(0, first, v1));
    DAW_CHECK(first.size() == 48000);
    bool clicks = first.size() == 48000;
    for (size_t f = 0; clicks && f < first.size(); ++f)
        clicks = first[f] == (f == 0 || f == 24000 ? 1.0f : 0.0f);
    DAW_CHECK(clicks);
    // IO-011 still holds: the export's locate pre-rolls again, so a second one is identical.
    DAW_CHECK(exportFrom(0, again, v2));
    DAW_CHECK(again == first);
    // From beat 2: its click is the export's first sample.
    DAW_CHECK(exportFrom(kPPQ, late, v3));
    DAW_CHECK(late.size() == 24000 && late[0] == 1.0f);
    DAW_CHECK(v1 == 0 && v2 == 0 && v3 == 0);
    return checks;
}

// MARK: MIX-024

CheckResult pdcLatencyChangeRebuilds() {
    CheckResult checks;
    Engine engine;
    auto latencyNodes = std::make_shared<LatencyNodes>();
    // A (1 every 1000 frames) → lat 21 → master; B (2 every 1000 frames) dry → master.
    Desc d;
    d.master(1).impulse(10, 0, 1.0f, 1000).latency(21, 100).impulse(20, 0, 2.0f, 1000);
    d.chain({10, 21, 1}).edge(20, 1);
    d.d.version = 5;
    Capture out;
    {
        GraphCompiler compiler(engine, pdcRegistry(latencyNodes), kRate, 256);
        DAW_CHECK(compiler.wait(compiler.submit(d.d), 5000ms));
        out.renderBlocks(engine, 8, 256);
        DAW_CHECK(engine.telemetry().snapshot().graphLatency == 100);

        FakeLatencyNode* node = latencyNodes->get(21);
        DAW_CHECK(node != nullptr);
        if (!node) return checks;
        node->setLatency(300);
        DAW_CHECK(eventually([&] { return compiler.status().latencyRebuilds >= 1; }));
        const std::vector<LatencyEvent> events = compiler.takeEvents();
        DAW_CHECK(events.size() == 1);
        if (events.size() == 1) {
            DAW_CHECK(events[0].node == 21 && events[0].nodeLatency == 300);
            DAW_CHECK(events[0].graphLatency == 300 && events[0].version == 5);
        }
        DAW_CHECK(compiler.takeEvents().empty());
        DAW_CHECK(latencyNodes->creates(21) == 1);  // same instance, not re-prepared
        DAW_CHECK(compiler.status().publishedVersion == 5 && !compiler.status().lastError);

        // The rebuilt graph re-plans PDC: once the delays settle, A and B land together again.
        out.renderBlocks(engine, 8, 256);
        DAW_CHECK(engine.telemetry().snapshot().graphLatency == 300);
        NodeLatency entry{};
        DAW_CHECK(engine.telemetry().nodeLatencies(&entry, 1) == 1 && entry.node == 21 && entry.samples == 300);
        const size_t settled = out.left.size() - 4 * 256;
        bool aligned = true;
        for (size_t f = settled; f < out.left.size(); ++f)
            aligned = aligned && (out.left[f] == 0.0f || out.left[f] == 3.0f);
        DAW_CHECK(aligned);
        DAW_CHECK(std::count(out.left.begin() + long(settled), out.left.end(), 3.0f) >= 1);

        // Two reports in a row coalesce into rebuilds that answer both, one event per node.
        node->setLatency(200);
        node->setLatency(200);
        DAW_CHECK(eventually([&] {
            const auto s = compiler.status();
            return s.latencyRebuilds >= 2;
        }));
        std::vector<LatencyEvent> later;
        DAW_CHECK(eventually([&] {
            auto more = compiler.takeEvents();
            later.insert(later.end(), more.begin(), more.end());
            return !later.empty() && later.back().graphLatency == 200;
        }));
    }
    // The compiler is gone; the node (still in the engine's pool) reports into nothing.
    if (FakeLatencyNode* node = latencyNodes->get(21)) node->setLatency(50);
    // A builder without a compiler drops reports too.
    GraphBuilder lone(pdcRegistry(latencyNodes), kRate, 256);
    Engine other;
    DAW_CHECK(lone.build(d.d, other.nodes(), other.params()).ok());
    if (FakeLatencyNode* node = latencyNodes->get(21)) node->setLatency(60);
    DAW_CHECK(out.violations == 0);
    return checks;
}

} // namespace daw::testing
