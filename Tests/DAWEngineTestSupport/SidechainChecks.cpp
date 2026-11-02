// T-023 checks for sidechain edges and ports (MIX-008). Run from
// Tests/DAWEngineTests/SidechainTests.swift; see SidechainChecks.h for why they're C++.

#include "SidechainChecks.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <numbers>
#include <random>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "ExportTestSupport.h"
#include "GoldenEngineSupport.h"
#include "NodeTestHarness.h"
#include "TestAudio.h"
#include "TestNodes.h"
#include "core/Engine.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/ProcessContext.h"
#include "core/RenderGraph.h"
#include "core/RtTrap.h"
#include "daw/EngineFacade.h"
#include "daw/GraphDescription.h"
#include "graph/BufferPlan.h"
#include "graph/GraphBuilder.h"
#include "graph/GraphCompiler.h"
#include "graph/NodeRegistry.h"
#include "nodes/ChannelStrip.h"
#include "time/TempoMap.h"

using namespace daw;
using namespace std::chrono_literals;

namespace daw::testing {

namespace {

constexpr double kRate = 48000.0;
constexpr double kH = std::numbers::sqrt2 / 2;  // centre pan, −3 dB (MIX-005)

bool near(double a, double b, double tol = 1e-6) { return std::fabs(a - b) <= tol; }

bool all(const std::vector<float>& v, size_t from, size_t to, double value, double tol = 1e-6) {
    if (to > v.size()) return false;
    for (size_t i = from; i < to; ++i)
        if (!near(v[i], value, tol)) return false;
    return true;
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

// MARK: Nodes

// A constant on every channel, free-running (not a timeline kind).
class DcNode final : public Node {
public:
    explicit DcNode(float value) : value_(value) {}
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext&, NodeIO& io) DAW_RT override {
        for (uint32_t c = 0; c < io.audioOut.numChannels; ++c)
            for (uint32_t f = 0; f < io.audioOut.numFrames; ++f) io.audioOut.channels[c][f] = value_;
    }

private:
    float value_;
};

// The SidechainMixNode instances a registry created, by NodeID (the latest), and how often.
class Probes {
public:
    void add(NodeID id, SidechainMixNode* node) {
        std::lock_guard lock(mutex_);
        nodes_[id] = node;
        ++creates_[id];
    }
    SidechainMixNode* get(NodeID id) const {
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
    std::map<NodeID, SidechainMixNode*> nodes_;
    std::map<NodeID, int> creates_;
};

// compressor: SidechainMixNode, level = configJSON (default 1), recorded in `probes`.
void registerProbe(NodeRegistry& registry, std::shared_ptr<Probes> probes) {
    (void)registry.set(NodeKind::compressor, {[probes](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> {
                           const std::string& config = info.desc.configJSON;
                           const float level = config.empty() ? 1.0f : std::stof(config);
                           auto node = std::make_unique<SidechainMixNode>(level);
                           probes->add(info.desc.id, node.get());
                           return std::unique_ptr<Node>(std::move(node));
                       }});
}

// master, bus (built in); sampler: "dc <v>" → DcNode, "sine <hz> <amp>" → SineNode (free-running);
// delay: FakeLatencyNode(configJSON); compressor: the probe.
NodeRegistry scRegistry(std::shared_ptr<Probes> probes) {
    NodeRegistry registry = NodeRegistry::withBuiltins();
    (void)registry.set(NodeKind::sampler, {[](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> {
                           char kind[8] = {};
                           double a = 0, b = 0;
                           std::sscanf(info.desc.configJSON.c_str(), "%7s %lf %lf", kind, &a, &b);
                           if (std::string(kind) == "sine")
                               return std::unique_ptr<Node>(new SineNode(a, static_cast<float>(b)));
                           return std::unique_ptr<Node>(new DcNode(static_cast<float>(a)));
                       }});
    (void)registry.set(NodeKind::delay, {[](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> {
                           return std::unique_ptr<Node>(
                               new FakeLatencyNode(static_cast<uint32_t>(std::stoul(info.desc.configJSON))));
                       }});
    registerProbe(registry, std::move(probes));
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
    Desc& dc(NodeID id, float value) { return node(id, NodeKind::sampler, "dc " + std::to_string(value)); }
    Desc& sine(NodeID id, double hz, float amp) {
        return node(id, NodeKind::sampler, "sine " + std::to_string(hz) + " " + std::to_string(amp));
    }
    Desc& latency(NodeID id, uint32_t samples) { return node(id, NodeKind::delay, std::to_string(samples)); }
    Desc& probe(NodeID id, float level) { return node(id, NodeKind::compressor, std::to_string(level)); }
    Desc& bus(NodeID id) { return node(id, NodeKind::bus); }
    Desc& master(NodeID id) {
        d.master = id;
        return node(id, NodeKind::master);
    }
    Desc& edge(NodeID from, NodeID to, EdgeKind kind = EdgeKind::audio, uint8_t port = 0) {
        d.edges.push_back(EdgeDesc{nextEdge++, from, to, kind, port});
        return *this;
    }
    Desc& sidechain(NodeID from, NodeID to) { return edge(from, to, EdgeKind::sidechain); }
    Desc& chain(std::initializer_list<NodeID> ids) {
        const NodeID* prev = nullptr;
        for (const NodeID& id : ids) {
            if (prev) edge(*prev, id);
            prev = &id;
        }
        return *this;
    }
};

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

} // namespace

// MARK: The test node

CheckResult sidechainMixNode() {
    CheckResult checks;
    const bool trapInstalled = RtTrap::install();  // no Engine here to install it (ENG-030)
    DAW_CHECK(trapInstalled || !DAW_RT_TRAP);
    ParamSlotTable params(4);
    TempoMap tempo;
    uint64_t violations = 0;

    constexpr uint32_t n = 37;
    std::vector<float> inL(n), inR(n), scL(n), scR(n), outL(n), outR(n);
    for (uint32_t f = 0; f < n; ++f) {
        inL[f] = 0.25f * float(f);
        inR[f] = -0.5f * float(f);
        scL[f] = 1.0f + float(f);
        scR[f] = 2.0f - float(f);
    }
    float* in[2] = {inL.data(), inR.data()};
    float* sc[2] = {scL.data(), scR.data()};
    float* out[2] = {outL.data(), outR.data()};

    SidechainMixNode node(-0.5f);
    node.prepare(PrepareInfo{kRate, kMaxBlock, 2, 2});
    auto run = [&](AudioBufferView audioIn, AudioBufferView sidechain) {
        std::fill(outL.begin(), outL.end(), -99.0f);
        std::fill(outR.begin(), outR.end(), -99.0f);
        NodeIO io;
        io.audioIn = audioIn;
        io.sidechain = sidechain;
        io.audioOut = AudioBufferView{out, 2, n};
        TransportBlock block{false, false, 0, {}, &tempo};
        ProcessContext ctx{n, kRate, block, params};
        RtScope scope;
        node.process(ctx, io);
        violations += scope.violations();
    };

    // Stereo sidechain: in + level · sidechain on each channel.
    run(AudioBufferView{in, 2, n}, AudioBufferView{sc, 2, n});
    bool mixed = true;
    for (uint32_t f = 0; f < n; ++f)
        mixed = mixed && outL[f] == inL[f] - 0.5f * scL[f] && outR[f] == inR[f] - 0.5f * scR[f];
    DAW_CHECK(mixed);
    DAW_CHECK(node.blocks() == 1 && node.routedBlocks() == 1);

    // ENG-003: an empty sidechain (nothing routed) passes the main input exactly.
    run(AudioBufferView{in, 2, n}, AudioBufferView{});
    DAW_CHECK(outL == inL && outR == inR);
    DAW_CHECK(node.blocks() == 2 && node.routedBlocks() == 1);

    // A mono sidechain keys channel 0 only; an empty main input is silence.
    run(AudioBufferView{in, 2, n}, AudioBufferView{sc, 1, n});
    bool mono = true;
    for (uint32_t f = 0; f < n; ++f) mono = mono && outL[f] == inL[f] - 0.5f * scL[f] && outR[f] == inR[f];
    DAW_CHECK(mono);
    run(AudioBufferView{}, AudioBufferView{sc, 2, n});
    bool keyOnly = true;
    for (uint32_t f = 0; f < n; ++f) keyOnly = keyOnly && outL[f] == -0.5f * scL[f] && outR[f] == -0.5f * scR[f];
    DAW_CHECK(keyOnly);
    DAW_CHECK(node.blocks() == 4 && node.routedBlocks() == 3);

    // Registered under compressor through TestNodeSpec (what makeTestFacade does).
    NodeRegistry registry = NodeRegistry::withBuiltins();
    const TestNodeSpec spec{NodeKind::compressor, TestNodeType::sidechainMix, 0, 0.75f, 0, 0};
    DAW_CHECK(registerTestNode(registry, spec).ok());
    const NodeKindInfo* info = registry.find(NodeKind::compressor);
    DAW_CHECK(info != nullptr && info->audioOutput);
    if (info) {
        const NodeDesc desc{5, NodeKind::compressor, 1, 0, 0, {}};
        auto made = info->create(NodeCreateInfo{desc, {}, {}, kNoMeter, LatencyReporter()});
        DAW_CHECK(made.ok() && made.value() != nullptr);
        if (made && made.value()) {
            Node& mix = *made.value();
            mix.prepare(PrepareInfo{kRate, kMaxBlock, 2, 2});
            NodeIO io;
            io.audioIn = AudioBufferView{in, 2, n};
            io.sidechain = AudioBufferView{sc, 2, n};
            io.audioOut = AudioBufferView{out, 2, n};
            TransportBlock block{false, false, 0, {}, &tempo};
            ProcessContext ctx{n, kRate, block, params};
            {
                RtScope scope;
                mix.process(ctx, io);
                violations += scope.violations();
            }
            DAW_CHECK(outL[3] == inL[3] + 0.75f * scL[3] && outR[3] == inR[3] + 0.75f * scR[3]);
            DAW_CHECK(mix.latencySamples() == 0);
        }
    }
    DAW_CHECK(violations == 0);
    return checks;
}

// MARK: MIX-008 port delivery

CheckResult sidechainPortDelivery() {
    CheckResult checks;
    uint64_t violations = 0;

    struct Case {
        const char* name;
        Desc desc;
        double expected;              // every frame of the master, both channels
        std::vector<NodeID> keyed;    // probes whose sidechain must be routed
        std::vector<NodeID> unkeyed;  // probes whose sidechain must be empty
    };
    auto base = [] {
        Desc d;
        d.master(1).dc(10, 0.25f).probe(40, 2.0f).chain({10, 40, 1});
        return d;
    };
    std::vector<Case> cases;
    {
        // ENG-003: no sidechain edge, empty port: the main input alone.
        cases.push_back({"none", base(), 0.25, {}, {40}});
    }
    {
        // A source whose only edge is the sidechain: the port reads its output directly.
        Desc d = base();
        d.dc(20, 0.5f).sidechain(20, 40);
        cases.push_back({"direct", d, 0.25 + 2 * 0.5, {40}, {}});
    }
    {
        // The source fans out (sidechain + master): the port is fed.
        Desc d = base();
        d.dc(20, 0.5f).sidechain(20, 40).edge(20, 1);
        cases.push_back({"fan-out", d, 0.25 + 2 * 0.5 + 0.5, {40}, {}});
    }
    {
        // MIX-004: every sidechain edge into the port is summed, including one through a bus;
        // none of it reaches the main input.
        Desc d = base();
        d.dc(20, 0.5f).dc(21, 0.125f).dc(22, 0.0625f).bus(30);
        d.sidechain(20, 40).sidechain(21, 40).edge(22, 30).sidechain(30, 40);
        cases.push_back({"summed", d, 0.25 + 2 * (0.5 + 0.125 + 0.0625), {40}, {}});
    }
    {
        // The same producer on both ports.
        Desc d = base();
        d.sidechain(10, 40);
        cases.push_back({"both ports", d, 0.25 + 2 * 0.25, {40}, {}});
    }
    {
        // A node with only a sidechain: its main input is empty (silence).
        Desc d;
        d.master(1).dc(20, 0.5f).probe(40, 2.0f).sidechain(20, 40).edge(40, 1);
        cases.push_back({"sidechain only", d, 2 * 0.5, {40}, {}});
    }
    {
        // One source keys two nodes; a third node next to them stays unkeyed.
        Desc d = base();
        d.dc(11, 0.125f).probe(41, 2.0f).chain({11, 41, 1});
        d.dc(12, 0.03125f).probe(42, 2.0f).chain({12, 42, 1});
        d.dc(20, 0.5f).sidechain(20, 40).sidechain(20, 41);
        cases.push_back({"two keyed", d, (0.25 + 1.0) + (0.125 + 1.0) + 0.03125, {40, 41}, {42}});
    }

    for (const Case& c : cases) {
        auto probes = std::make_shared<Probes>();
        Engine engine;
        GraphBuilder builder(scRegistry(probes), kRate, 256);
        const bool built = publish(builder, engine, c.desc.d);
        DAW_CHECK(built);
        if (!built) {
            std::fprintf(stderr, "sidechainPortDelivery: case '%s' did not build\n", c.name);
            continue;
        }
        Capture out;
        out.renderBlocks(engine, 3, 256);
        out.render(engine, 77);
        const bool ok = all(out.left, 0, out.left.size(), c.expected, 0.0) &&
                        all(out.right, 0, out.right.size(), c.expected, 0.0);
        DAW_CHECK(ok);
        if (!ok)
            std::fprintf(stderr, "sidechainPortDelivery: case '%s' got %f, expected %f\n", c.name,
                         double(out.left.empty() ? -1 : out.left.back()), c.expected);
        for (NodeID id : c.keyed) {
            const SidechainMixNode* p = probes->get(id);
            DAW_CHECK(p != nullptr && p->blocks() == 4 && p->routedBlocks() == 4);
        }
        for (NodeID id : c.unkeyed) {
            const SidechainMixNode* p = probes->get(id);
            DAW_CHECK(p != nullptr && p->blocks() == 4 && p->routedBlocks() == 0);
        }
        violations += out.violations;
    }

    // MIX-004: sidechain edges feed port 0; any other toPort is rejected before anything changes.
    {
        auto probes = std::make_shared<Probes>();
        Engine engine;
        GraphBuilder builder(scRegistry(probes), kRate, 256);
        Desc d = base();
        d.dc(20, 0.5f).edge(20, 40, EdgeKind::sidechain, 1);
        auto r = builder.build(d.d, engine.nodes(), engine.params());
        DAW_CHECK(!r.ok() && r.error().code == ErrorCode::invalidArgument);
        DAW_CHECK(probes->creates(40) == 0);
    }
    DAW_CHECK(violations == 0);
    return checks;
}

// MARK: MIX-008 pre/post-fader tap

CheckResult sidechainPreAndPostFaderTap() {
    CheckResult checks;
    using nodes::Rig;
    auto probes = std::make_shared<Probes>();
    Rig rig([probes](NodeRegistry& registry) { registerProbe(registry, probes); });
    // Track A: a mono DC 1.0 clip → strip A → master.
    // Track B: a mono DC 0.5 clip → insert (probe, level 1) → strip B → master.
    // The insert is keyed by track A, pre-fader (A's player) or post-fader (A's strip), the edges
    // GraphDescriptionBuilder emits for SetSidechain (MODEL-020).
    rig.addAsset(nodes::makeAsset(1, 1, 1'000'000, [](uint32_t, int64_t) { return 1.0f; }));
    rig.addAsset(nodes::makeAsset(2, 1, 1'000'000, [](uint32_t, int64_t) { return 0.5f; }));
    ParamSlotTable& params = rig.engine().params();
    auto a = params.allocate(ChannelStrip::kNumParams, 0.0f);
    auto b = params.allocate(ChannelStrip::kNumParams, 0.0f);
    DAW_CHECK(a.ok() && b.ok());
    if (!a || !b) return checks;
    const ParamID stripA = a.value(), stripB = b.value();
    params.set(stripA + ChannelStrip::kGain, 1.0f);
    params.set(stripB + ChannelStrip::kGain, 1.0f);

    auto description = [&](bool postFader, uint64_t version) {
        GraphDescription d = nodes::baseDescription();
        d.version = version;
        d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
        d.nodes.push_back(NodeDesc{11, NodeKind::channelStrip, 1, stripA, ChannelStrip::kNumParams, {}});
        d.nodes.push_back(NodeDesc{20, NodeKind::audioClipPlayer, 1, 0, 0, {}});
        d.nodes.push_back(NodeDesc{21, NodeKind::compressor, 1, 0, 0, "1"});
        d.nodes.push_back(NodeDesc{22, NodeKind::channelStrip, 1, stripB, ChannelStrip::kNumParams, {}});
        d.edges.push_back(EdgeDesc{1, 10, 11, EdgeKind::audio, 0});
        d.edges.push_back(EdgeDesc{2, 11, 1, EdgeKind::audio, 0});
        d.edges.push_back(EdgeDesc{3, 20, 21, EdgeKind::audio, 0});
        d.edges.push_back(EdgeDesc{4, 21, 22, EdgeKind::audio, 0});
        d.edges.push_back(EdgeDesc{5, 22, 1, EdgeKind::audio, 0});
        // MIX-008: the tap is where the sidechain edge starts (edge IDs differ, as the model's
        // hash of (from, to, kind) would).
        d.edges.push_back(postFader ? EdgeDesc{7, 11, 21, EdgeKind::sidechain, 0}
                                    : EdgeDesc{6, 10, 21, EdgeKind::sidechain, 0});
        d.audioClips.push_back(nodes::clip(10, 1, 0, 30000, 1));
        d.audioClips.push_back(nodes::clip(20, 2, 0, 30000, 2));
        return d;
    };
    // Renders two 256-frame blocks; slot changes ramp over the first (ENG-022), so the second
    // block is settled.
    auto settled = [&](double left, double right) {
        rig.clearOutput();
        rig.renderFrames(512, [] { return 256u; });
        return all(rig.left(), 256, 512, left) && all(rig.right(), 256, 512, right);
    };
    auto setA = [&](uint32_t slot, float value) { params.set(stripA + slot, value); };

    for (bool post : {false, true}) {
        DAW_CHECK(rig.publish(description(post, post ? 2 : 1)));
        if (!post) DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
        // A's strip outputs gA·h·pan; B's outputs (0.5 + sidechain)·h. Pre-fader the sidechain is
        // A's player (1.0); post-fader it is A's strip output.
        auto expect = [&](double aL, double aR, double scL, double scR) {
            return settled(aL + (0.5 + scL) * kH, aR + (0.5 + scR) * kH);
        };
        // Unity, centre.
        DAW_CHECK(post ? expect(kH, kH, kH, kH) : expect(kH, kH, 1.0, 1.0));
        // Fader 0.5: post follows, pre doesn't.
        setA(ChannelStrip::kGain, 0.5f);
        DAW_CHECK(post ? expect(0.5 * kH, 0.5 * kH, 0.5 * kH, 0.5 * kH) : expect(0.5 * kH, 0.5 * kH, 1.0, 1.0));
        setA(ChannelStrip::kGain, 1.0f);
        // Mute: post keys from silence, pre still keys (the edge carries no mute of its own).
        setA(ChannelStrip::kMute, 1.0f);
        DAW_CHECK(post ? expect(0, 0, 0, 0) : expect(0, 0, 1.0, 1.0));
        setA(ChannelStrip::kMute, 0.0f);
        // Phase invert: post is inverted with the strip.
        setA(ChannelStrip::kPhase, 1.0f);
        DAW_CHECK(post ? expect(-kH, -kH, -kH, -kH) : expect(-kH, -kH, 1.0, 1.0));
        setA(ChannelStrip::kPhase, 0.0f);
        // Pan hard left: the sidechain is stereo, per channel (MIX-004), post-pan when post.
        setA(ChannelStrip::kPan, -1.0f);
        DAW_CHECK(post ? expect(1.0, 0.0, 1.0, 0.0) : expect(1.0, 0.0, 1.0, 1.0));
        setA(ChannelStrip::kPan, 0.0f);
        DAW_CHECK(post ? expect(kH, kH, kH, kH) : expect(kH, kH, 1.0, 1.0));
    }
    // Moving the tap was a rebuild that changed only an edge: the keyed insert kept its instance.
    DAW_CHECK(probes->creates(21) == 1);
    const SidechainMixNode* probe = probes->get(21);
    DAW_CHECK(probe != nullptr && probe->routedBlocks() == probe->blocks() && probe->blocks() > 0);
    DAW_CHECK(rig.violations() == 0);
    return checks;
}

// MARK: MIX-021 on sidechain merges

CheckResult sidechainPdcAlignment() {
    CheckResult checks;
    uint64_t violations = 0;
    struct Case {
        const char* name;
        Desc desc;
        uint32_t latency;
    };
    // Probe 40 nulls when main and sidechain carry the same signal at the same frame.
    std::vector<Case> cases;
    {
        Desc d;  // latent main, dry sidechain
        d.master(1).sine(10, 440.0, 0.5f).latency(20, 700).probe(40, -1.0f);
        d.chain({10, 20, 40, 1}).sidechain(10, 40);
        cases.push_back({"latent main", d, 700});
    }
    {
        Desc d;  // dry main, latent sidechain
        d.master(1).sine(10, 440.0, 0.5f).latency(20, 700).probe(40, -1.0f);
        d.chain({10, 40, 1}).edge(10, 20).sidechain(20, 40);
        cases.push_back({"latent sidechain", d, 700});
    }
    {
        Desc d;  // main through 500; the sidechain sums a 300 path and a dry one
        d.master(1).sine(10, 440.0, 0.5f).latency(20, 500).latency(21, 300).probe(40, -0.5f);
        d.chain({10, 20, 40, 1}).edge(10, 21).sidechain(21, 40).sidechain(10, 40);
        cases.push_back({"summed sidechain", d, 500});
    }

    std::mt19937 rng(0x5C023);
    std::uniform_int_distribution<uint32_t> sizes(1, 512);
    for (Case& c : cases) {
        for (float level : {0.0f, 1.0f}) {  // 0: the null as built; 1: the control (no null)
            Desc d = c.desc;
            if (level == 1.0f)
                for (NodeDesc& n : d.d.nodes)
                    if (n.kind == NodeKind::compressor) n.configJSON = "1";
            auto probes = std::make_shared<Probes>();
            Engine engine;
            GraphBuilder builder(scRegistry(probes), kRate, 512);
            auto graph = take(builder.build(d.d, engine.nodes(), engine.params()));
            DAW_CHECK(graph != nullptr);
            if (!graph) continue;
            DAW_CHECK(graph->latency() == c.latency);
            engine.publish(std::move(graph));
            Capture out;
            while (out.left.size() < 6000) out.render(engine, sizes(rng));
            violations += out.violations;
            if (level == 0.0f) {
                const bool silent = all(out.left, 0, out.left.size(), 0.0, 0.0) &&
                                    all(out.right, 0, out.right.size(), 0.0, 0.0);
                DAW_CHECK(silent);
                if (!silent) std::fprintf(stderr, "sidechainPdcAlignment: '%s' does not null\n", c.name);
            } else {
                // The control: before the latency only silence, afterwards the signal.
                bool sounding = false;
                for (size_t f = c.latency + 1; f < out.left.size(); ++f) sounding = sounding || out.left[f] != 0.0f;
                DAW_CHECK(sounding && all(out.left, 0, c.latency, 0.0, 0.0));
            }
        }
    }
    DAW_CHECK(violations == 0);
    return checks;
}

// MARK: MIX-003 liveness with sidechain ports

CheckResult sidechainBufferLiveness() {
    CheckResult checks;
    // Symbolic run of planBuffers: each buffer carries a tag for what it holds; a step's ports
    // must hold exactly what was fed into them (every edge once), or the sole producer's own
    // output (a direct read) when nothing has overwritten it.
    constexpr int64_t kGarbage = -1;
    auto outTag = [](uint32_t s) { return int64_t{s} * 4 + 1; };
    auto portTag = [](uint32_t s, bool sidechain) { return int64_t{s} * 4 + (sidechain ? 3 : 2); };

    std::mt19937 rng(0x5C0023);
    auto uniform = [&](int lo, int hi) { return std::uniform_int_distribution<int>(lo, hi)(rng); };
    int sidechainEdges = 0, directSidechains = 0, delayedSidechains = 0;
    for (int iteration = 0; iteration < 300; ++iteration) {
        const auto n = static_cast<uint32_t>(uniform(2, 60));
        const uint32_t master = n - 1;
        std::vector<bool> producesAudio(n, true);
        // A few sinks write no audio (e.g. a meter-only node); they never feed anything.
        for (uint32_t s = 0; s + 1 < n; ++s) producesAudio[s] = uniform(0, 19) != 0;
        std::vector<PlanEdge> edges;
        for (uint32_t to = 1; to < n; ++to) {
            for (bool sc : {false, true}) {
                const int count = sc ? (uniform(0, 2) == 0 ? uniform(1, 3) : 0) : uniform(0, 3);
                for (int k = 0; k < count; ++k) {
                    const auto from = static_cast<uint32_t>(uniform(0, int(to) - 1));
                    if (!producesAudio[from]) continue;
                    const auto delay = uniform(0, 4) == 0 ? static_cast<uint32_t>(uniform(1, 100)) : 0u;
                    edges.push_back({from, to, sc && to != master, delay});
                }
            }
        }
        std::shuffle(edges.begin(), edges.end(), rng);
        const BufferPlan plan = planBuffers(producesAudio, edges, master);

        std::vector<uint32_t> inCount(n, 0), scCount(n, 0);
        for (const PlanEdge& e : edges) {
            ++(e.sidechain ? scCount : inCount)[e.to];
            sidechainEdges += e.sidechain;
            delayedSidechains += e.sidechain && e.delay > 0;
        }
        std::vector<int64_t> tag(plan.numBuffers, kGarbage);
        std::map<int64_t, uint32_t> arrived;  // port tag → edges fed into it
        bool ok = plan.steps.size() == n;
        for (uint32_t s = 0; ok && s < n; ++s) {
            const StepBuffers& step = plan.steps[s];
            for (bool sc : {false, true}) {
                const uint32_t buffer = (sc ? step.sidechain : step.input).buffer;
                const uint32_t count = (sc ? scCount : inCount)[s];
                if (count == 0) {
                    ok = ok && buffer == kNoBuffer;
                    continue;
                }
                ok = ok && buffer < plan.numBuffers && buffer != step.output;
                if (!ok) break;
                if (tag[buffer] == portTag(s, sc)) {
                    ok = arrived[portTag(s, sc)] == count;
                } else {
                    // A direct read: the only edge into the port, undelayed, and the producer's
                    // output still intact.
                    const PlanEdge* only = nullptr;
                    for (const PlanEdge& e : edges)
                        if (e.to == s && e.sidechain == sc) only = &e;
                    ok = count == 1 && only && only->delay == 0 && tag[buffer] == outTag(only->from);
                    directSidechains += ok && sc;
                }
            }
            if (!ok) break;
            ok = (step.output != kNoBuffer) == bool(producesAudio[s]);  // ok was true here
            if (step.output != kNoBuffer) tag[step.output] = outTag(s);  // the node runs
            ok = ok && step.feeds.size() == step.feedEdges.size();
            for (size_t i = 0; ok && i < step.feeds.size(); ++i) {
                const RenderFeedDesc& feed = step.feeds[i];
                const PlanEdge& e = edges[step.feedEdges[i]];
                const int64_t port = portTag(e.to, e.sidechain);
                ok = e.from == s && feed.buffer < plan.numBuffers && feed.buffer != step.output &&
                     feed.delay == e.delay && (feed.add ? tag[feed.buffer] == port : true);
                if (!ok) break;
                tag[feed.buffer] = port;
                arrived[port] = feed.add ? arrived[port] + 1 : 1;
            }
        }
        ok = ok && tag[plan.steps[master].output] == outTag(master);
        DAW_CHECK(ok);
        if (!ok) {
            std::fprintf(stderr, "sidechainBufferLiveness: iteration %d failed\n", iteration);
            break;
        }
    }
    // The random graphs did exercise every sidechain path.
    DAW_CHECK(sidechainEdges > 500 && directSidechains > 10 && delayedSidechains > 50);

    // Rendered: a key source fans out at the top (so its sidechain port is fed early) and the
    // keyed node runs at the end of a 20-bus chain, each bus adding a source of its own: the fed
    // sidechain buffer must survive every step in between.
    {
        auto probes = std::make_shared<Probes>();
        Engine engine;
        GraphBuilder builder(scRegistry(probes), kRate, 128);
        Desc d;
        d.master(1).dc(10, 0.5f).probe(40, 4.0f).bus(100).edge(10, 100).sidechain(10, 40);
        double main = 0.5;
        for (int i = 1; i <= 20; ++i) {
            const NodeID bus = 100 + i, src = 200 + i;
            const float v = std::ldexp(1.0f, -i);
            d.bus(bus).dc(src, v).edge(bus - 1, bus).edge(src, bus);
            main += v;
        }
        d.edge(120, 40).edge(40, 1);
        auto graph = take(builder.build(d.d, engine.nodes(), engine.params()));
        DAW_CHECK(graph != nullptr);
        if (graph) {
            DAW_CHECK(graph->buffers().numBuffers() <= 4);
            engine.publish(std::move(graph));
            Capture out;
            out.renderBlocks(engine, 3, 128);
            DAW_CHECK(all(out.left, 0, out.left.size(), main + 4 * 0.5, 0.0));
            DAW_CHECK(all(out.right, 0, out.right.size(), main + 4 * 0.5, 0.0));
            DAW_CHECK(out.violations == 0);
        }
    }
    return checks;
}

// MARK: Rebuilds

CheckResult sidechainRebuild() {
    CheckResult checks;
    uint64_t violations = 0;

    // GraphCompiler on daw.compile: add, move and remove a sidechain edge between renders.
    {
        auto probes = std::make_shared<Probes>();
        Engine engine;
        auto compiler = std::make_unique<GraphCompiler>(engine, scRegistry(probes), kRate, 128);
        Desc v1;
        v1.master(1).dc(10, 0.25f).probe(40, 2.0f).dc(20, 0.5f).dc(21, 0.125f);
        v1.chain({10, 40, 1}).edge(20, 1).edge(21, 1);
        Desc v2 = v1;
        v2.d.version = 2;
        v2.d.edges.push_back(EdgeDesc{100, 20, 40, EdgeKind::sidechain, 0});
        Desc v3 = v1;
        v3.d.version = 3;
        v3.d.edges.push_back(EdgeDesc{101, 21, 40, EdgeKind::sidechain, 0});
        Desc v4 = v1;
        v4.d.version = 4;

        struct Step {
            const Desc* desc;
            double expected;
            bool keyed;
        };
        const double dry = 0.25 + 0.5 + 0.125;
        const Step steps[] = {{&v1, dry, false}, {&v2, dry + 2 * 0.5, true}, {&v3, dry + 2 * 0.125, true},
                              {&v4, dry, false}, {&v2, dry + 2 * 0.5, true}};
        for (const Step& step : steps) {
            DAW_CHECK(compiler->wait(compiler->submit(step.desc->d), 5000ms));
            DAW_CHECK(!compiler->status().lastError.has_value());
            Capture out;
            out.render(engine, 128);  // picks up the new graph
            const SidechainMixNode* probe = probes->get(40);
            const uint64_t routed = probe ? probe->routedBlocks() : 0;
            out.render(engine, 128);
            DAW_CHECK(all(out.left, 0, 256, step.expected, 0.0) && all(out.right, 0, 256, step.expected, 0.0));
            DAW_CHECK(probe != nullptr && probe->routedBlocks() == routed + (step.keyed ? 1 : 0));
            violations += out.violations;
        }
        DAW_CHECK(probes->creates(40) == 1);  // edges changed, the instance didn't
        compiler.reset();
    }

    // MIX-022 on a delayed sidechain edge: the main path is 1000 samples latent, so the sidechain
    // edge (ID 7) goes through a delay line, which an unrelated rebuild must carry over.
    Desc base;
    base.master(1).sine(10, 300.0, 0.5f).latency(11, 1000).sine(20, 700.0, 0.25f).probe(40, 1.0f);
    base.chain({10, 11, 40, 1});
    base.d.edges.push_back(EdgeDesc{7, 20, 40, EdgeKind::sidechain, 0});
    Desc grown = base;  // plus an unrelated track: a structural rebuild
    grown.d.version = 2;
    grown.dc(30, 0.0f).bus(31).chain({30, 31, 1});
    Desc renamed = base;  // the control: the sidechain edge under a new ID starts silent
    renamed.d.version = 3;
    renamed.d.edges.back().edgeID = 99;

    constexpr uint32_t kFrames = 256;
    constexpr int kBefore = 20, kAfter = 20;
    auto run = [&](const Desc* rebuild) {
        Engine engine;
        GraphBuilder builder(scRegistry(std::make_shared<Probes>()), kRate, kFrames);
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
    DAW_CHECK(rebuilt.left == reference.left && rebuilt.right == reference.right);
    const size_t at = size_t{kBefore} * kFrames;
    DAW_CHECK(control.left.size() == reference.left.size());
    if (control.left.size() == reference.left.size()) {
        bool differs = false;
        for (size_t f = at; f < at + 1000; ++f) differs = differs || control.left[f] != reference.left[f];
        DAW_CHECK(differs);
        DAW_CHECK(std::equal(control.left.begin(), control.left.begin() + at, reference.left.begin()));
        // After the line has filled again, the control is back in step.
        DAW_CHECK(std::equal(control.left.begin() + at + 1000, control.left.end(), reference.left.begin() + at + 1000));
    }
    DAW_CHECK(violations == 0);
    return checks;
}

// MARK: Through the facade

CheckResult sidechainThroughFacade() {
    CheckResult checks;
    TempDir dir;
    // Clip-less players are a 1 kHz sine at 0.5 (TEST-004); the compressor is the probe, level 0.5.
    TestNodeSpecs specs{
        TestNodeSpec{NodeKind::audioClipPlayer, TestNodeType::sine, 1000.0, 0.5f, 0, 0},
        TestNodeSpec{NodeKind::compressor, TestNodeType::sidechainMix, 0, 0.5f, 0, 0},
    };
    EngineFacade* made = makeTestFacade(kRate, specs);
    DAW_CHECK(made != nullptr);
    if (!made) return checks;
    EngineFacade& facade = *made;

    // Track B plays two seconds of mono 0.5 DC.
    const auto file = dir.path() / "dc.wav";
    DAW_CHECK(writeTestFile(file, "wav-f32", kRate, Channels{std::vector<float>(96000, 0.5f)}).ok());
    const JobID load = facade.loadAsset(7, file.string());
    JobStatus loaded;
    DAW_CHECK(eventually([&] {
        loaded = facade.pollJob(load);
        return loaded.state == JobState::succeeded || loaded.state == JobState::failed;
    }));
    DAW_CHECK(loaded.state == JobState::succeeded);

    // Strips: track A, track B, master; gain 1, centre. Track A starts muted.
    const ParamID a = facade.allocateParams(ChannelStrip::kNumParams);
    const ParamID b = facade.allocateParams(ChannelStrip::kNumParams);
    const ParamID m = facade.allocateParams(ChannelStrip::kNumParams);
    for (ParamID strip : {a, b, m}) {
        facade.setParam(strip + ChannelStrip::kGain, 1.0f);
        facade.setParam(strip + ChannelStrip::kPan, 0.0f);
        facade.setParam(strip + ChannelStrip::kMute, 0.0f);
        facade.setParam(strip + ChannelStrip::kPhase, 0.0f);
    }
    facade.setParam(a + ChannelStrip::kMute, 1.0f);

    // GraphDescriptionBuilder's layout (MODEL-020) for: track A (clip-less), track B with a
    // compressor insert whose SetSidechain source is track A, both out to the master:
    //   source:A(11) → strip A(10) → input:master(3)
    //   source:B(21) → comp(22) → strip B(20) → input:master(3)
    //   input:master(3) → master strip(1) → output:master(2)
    //   sidechain: A's tap → comp(22); pre-fader = source:A, post-fader = strip A
    auto graph = [&](bool postFader) {
        GraphDescriptionBuilder g;
        g.addNode(11, NodeKind::audioClipPlayer, 0, 0, 0, "");
        g.addNode(10, NodeKind::channelStrip, 0, a, ChannelStrip::kNumParams, "");
        g.addNode(21, NodeKind::audioClipPlayer, 0, 0, 0, "");
        g.addNode(22, NodeKind::compressor, 0, 0, 0, "");
        g.addNode(20, NodeKind::channelStrip, 0, b, ChannelStrip::kNumParams, "");
        g.addNode(3, NodeKind::bus, 0, 0, 0, "");
        g.addNode(1, NodeKind::channelStrip, 0, m, ChannelStrip::kNumParams, "");
        g.addNode(2, NodeKind::master, 0, 0, 0, "");
        g.addEdge(101, 11, 10, EdgeKind::audio, 0);
        g.addEdge(102, 21, 22, EdgeKind::audio, 0);
        g.addEdge(103, 22, 20, EdgeKind::audio, 0);
        g.addEdge(104, 3, 1, EdgeKind::audio, 0);
        g.addEdge(105, 1, 2, EdgeKind::audio, 0);
        g.addEdge(106, 10, 3, EdgeKind::audio, 0);
        g.addEdge(107, 20, 3, EdgeKind::audio, 0);
        if (postFader) g.addEdge(109, 10, 22, EdgeKind::sidechain, 0);
        else g.addEdge(108, 11, 22, EdgeKind::sidechain, 0);
        g.addClip(21, 1, 0, 4 * kPPQ, 7, 0, 1.0f, 0, 0);
        g.setTempo(0, 120.0);
        g.setTimeSignature(0, 4, 4);
        g.setMaster(2);
        return g.description();
    };
    // Exports [0, 1 s) and returns the left channel (right must match it), empty on failure.
    int exports = 0;
    auto exportLeft = [&]() -> std::vector<float> {
        ExportSpecPOD spec;
        spec.path = (dir.path() / ("out" + std::to_string(exports++) + ".wav")).string();
        spec.tailEnabled = false;
        const JobID job = facade.renderOffline(0, 2 * kPPQ, spec);
        JobStatus status;
        const bool finished = eventually([&] {
            status = facade.pollJob(job);
            return status.state == JobState::succeeded || status.state == JobState::failed;
        }, 20000ms);
        if (!finished || status.state != JobState::succeeded || status.render.rtViolations != 0) return {};
        auto back = readBack(spec.path, kRate);
        if (!back || back->size() != 2 || (*back)[0].size() != 48000 || (*back)[0] != (*back)[1]) return {};
        return (*back)[0];
    };
    auto published = [&](uint64_t version) {
        const GraphStatusPOD s = facade.waitForGraph(version, 5000);
        return s.publishedVersion == version && s.lastError.ok();
    };
    // Every strip halves a centred mono signal's power: h per strip, two strips per path.
    auto sine = [](size_t n) {
        return 0.5 * double(static_cast<float>(std::sin(2.0 * std::numbers::pi * 1000.0 * double(n) / kRate)));
    };
    auto matches = [](const std::vector<float>& out, auto expected) {
        if (out.size() != 48000) return false;
        for (size_t n = 2048; n < out.size(); ++n)  // past the strips' first-block ramps
            if (!near(out[n], expected(n), 1e-5)) return false;
        return true;
    };

    // Pre-fader: track A is muted, yet its player keys the insert: B = (0.5 + 0.5 · sine).
    DAW_CHECK(published(facade.applyGraph(graph(false))));
    DAW_CHECK(matches(exportLeft(), [&](size_t n) { return 0.5 * (0.5 + 0.5 * sine(n)); }));
    // Post-fader: the muted strip keys nothing; B is the DC alone.
    DAW_CHECK(published(facade.applyGraph(graph(true))));
    DAW_CHECK(matches(exportLeft(), [](size_t) { return 0.5 * 0.5; }));
    // Post-fader, A unmuted: A is in the mix, and its strip output (h · sine) keys B.
    facade.setParam(a + ChannelStrip::kMute, 0.0f);
    DAW_CHECK(matches(exportLeft(), [&](size_t n) { return 0.5 * sine(n) + 0.5 * (0.5 + 0.5 * kH * sine(n)); }));
    // Each export checked its own render thread's RT violations (0); Telemetry's count is
    // process-wide (DW-024), so it isn't asserted here.
    releaseFacade(made);
    return checks;
}

} // namespace daw::testing
