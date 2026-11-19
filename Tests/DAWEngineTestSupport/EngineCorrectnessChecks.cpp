// T-111 checks: engine correctness fixes from the 2026-11-18 review. Run from
// Tests/DAWEngineTests/EngineCorrectnessTests.swift; see EngineCorrectnessChecks.h.

#include "EngineCorrectnessChecks.h"

#include <mach/mach_time.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <limits>
#include <memory>
#include <optional>
#include <thread>
#include <utility>
#include <vector>

#include "NodeTestHarness.h"
#include "TestAudio.h"
#include "TestNodes.h"
#include "core/Engine.h"
#include "core/NodeIO.h"
#include "core/ProcessContext.h"
#include "core/RenderGraph.h"
#include "core/RtTrap.h"
#include "daw/EngineFacade.h"
#include "dsp/ParamInfo.h"
#include "facade/DriverAdapter.h"
#include "facade/FacadeOptions.h"
#include "graph/GraphBuilder.h"
#include "graph/GraphCompiler.h"
#include "io/AudioFileLoader.h"
#include "io/FakeDeviceDriver.h"
#include "nodes/BuiltinNodes.h"
#include "nodes/Eq.h"
#include "nodes/Metronome.h"
#include "time/TempoMap.h"
#include "time/Transport.h"

using namespace std::chrono_literals;

namespace daw::testing {

namespace {

template <typename F>
bool eventually(F done, std::chrono::milliseconds timeout = 5000ms) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (!done()) {
        if (std::chrono::steady_clock::now() > deadline) return false;
        std::this_thread::sleep_for(1ms);
    }
    return true;
}

// Allocates `info.size()` slots at their defaults; returns the first.
ParamID defaults(ParamSlotTable& params, std::span<const ParamInfo> info) {
    auto first = params.allocate(static_cast<uint32_t>(info.size()), 0.0f);
    if (!first) return 0;
    for (const ParamInfo& p : info) params.set(first.value() + p.index, p.def);
    return first.value();
}

void fill(const AudioBufferView& out, uint32_t numFrames, float value) DAW_RT {
    for (uint32_t c = 0; c < out.numChannels; ++c)
        for (uint32_t f = 0; f < numFrames; ++f) out.channels[c][f] = value;
}

} // namespace

// MARK: DW-318

namespace {

MidiEvent midi(uint32_t frame, uint8_t status, uint8_t d1, uint8_t d2) { return MidiEvent{frame, 3, {status, d1, d2}}; }

// One block through `line` in an RtScope; counts what comes out.
struct LineDriver {
    MidiDelayLine& line;
    uint64_t violations = 0;
    uint64_t ons = 0, offs = 0;
    void block(const std::vector<MidiEvent>& in, uint32_t delay, uint32_t numFrames) {
        MidiEventSpan got;
        {
            RtScope scope;
            got = line.process(MidiEventSpan(in.data(), in.size()), delay, numFrames);
            violations += scope.violations();
        }
        for (const MidiEvent& e : got) {
            const uint8_t status = e.data[0] & 0xF0;
            if (status == 0x90 && e.data[2] > 0) ++ons;
            else if (status == 0x80 || status == 0x90) ++offs;
        }
    }
};

} // namespace

CheckResult midiDelayLineCountsHeldKeys() {
    CheckResult checks;
    (void)RtTrap::install();  // no Engine here to install it (ENG-030)

    // A source that never sends its offs: 100 note-ons on one key, one per block, each through
    // the line (delay 100, so they drain). Before DW-318 every on grew the reserve, so after 15 the
    // 16-slot line dropped every note-on, on any key, for good.
    {
        MidiDelayLine line(16, 64);
        LineDriver run{line};
        for (int b = 0; b < 100; ++b) run.block({midi(0, 0x90, 60, 100)}, 100, 256);
        DAW_CHECK(line.reserved() == 1 && line.dropped() == 0 && run.ons == 100);
        // Later notes on other keys, paired, all go through.
        for (uint8_t k = 0; k < 40; ++k) {
            run.block({midi(0, 0x90, k, 90), midi(10, 0x80, k, 0)}, 100, 256);
        }
        run.block({}, 100, 256);
        DAW_CHECK(line.dropped() == 0 && run.ons == 140 && run.offs == 40);
        DAW_CHECK(line.reserved() == 1);  // key 60 is still held
        // Its off releases it (one off ends the key); a second off is not reserved any more.
        run.block({midi(0, 0x80, 60, 0)}, 100, 256);
        DAW_CHECK(line.reserved() == 0);
        // The same key on another channel is another key.
        run.block({midi(0, 0x90, 60, 100), midi(0, 0x91, 60, 100)}, 100, 256);
        DAW_CHECK(line.reserved() == 2);
        DAW_CHECK(run.violations == 0);
    }

    // Under pressure (a long delay, nothing drains): a repeated on for a held key needs room for
    // itself only, and the reserve still keeps every held key's release.
    {
        MidiDelayLine line(16, 64);
        LineDriver run{line};
        std::vector<MidiEvent> ons;
        for (int i = 0; i < 12; ++i) ons.push_back(midi(0, 0x90, 60, 100));  // one key, 12 times
        run.block(ons, 100000, 10);
        // 15 slots for ons + 1 reserved off: 12 ons fit, the reserve is one key.
        DAW_CHECK(line.queued() == 12 && line.reserved() == 1 && line.dropped() == 0);
        std::vector<MidiEvent> keys;
        for (uint8_t k = 0; k < 4; ++k) keys.push_back(midi(0, 0x90, k, 100));
        run.block(keys, 100000, 10);  // free 4, reserve 1: key 0 fits (with its off), the rest don't
        DAW_CHECK(line.queued() == 13 && line.reserved() == 2 && line.dropped() == 3);
        run.block({midi(0, 0x80, 60, 0), midi(0, 0x80, 0, 0)}, 100000, 10);  // both reserved offs go in
        DAW_CHECK(line.queued() == 15 && line.reserved() == 0 && line.dropped() == 3);
        DAW_CHECK(run.violations == 0);
    }
    return checks;
}

// MARK: DW-311

namespace {

// A factory that blocks until opened, then makes a plain node: a build that keeps daw.compile
// busy while the test queues a latency report and a failing submission behind it.
struct BuildGate {
    std::atomic<bool> entered{false};
    std::atomic<bool> open{false};
};

class SilentNode final : public Node {
public:
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override { fill(io.audioOut, ctx.numFrames, 0.0f); }
};

} // namespace

CheckResult compilerKeepsLatencyReportsOfFailedBuild() {
    CheckResult checks;
    Engine engine;
    auto gate = std::make_shared<BuildGate>();
    auto latent = std::make_shared<std::atomic<ReportingLatencyNode*>>(nullptr);
    NodeRegistry registry = NodeRegistry::withBuiltins();
    (void)registry.set(NodeKind::delay, {[latent](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> {
                           auto node = std::make_unique<ReportingLatencyNode>(100, info.latency);
                           latent->store(node.get());
                           return std::unique_ptr<Node>(std::move(node));
                       }});
    (void)registry.set(NodeKind::compressor, {[gate](const NodeCreateInfo&) -> Result<std::unique_ptr<Node>> {
                           gate->entered.store(true);
                           const auto deadline = std::chrono::steady_clock::now() + 10s;
                           while (!gate->open.load() && std::chrono::steady_clock::now() < deadline)
                               std::this_thread::sleep_for(1ms);
                           return std::unique_ptr<Node>(new SilentNode);
                       }});
    (void)registry.set(NodeKind::reverb, {[](const NodeCreateInfo&) -> Result<std::unique_ptr<Node>> {
                           return makeError(ErrorCode::internal, "test: this node never builds");
                       }});

    // v5: master 1 ← latent 21 (100 frames). v6 adds a slow node 40 (builds, after the gate).
    // v7 adds node 30, which fails.
    GraphDescription good = nodes::baseDescription();
    good.version = 5;
    good.nodes.push_back(NodeDesc{21, NodeKind::delay, 1, 0, 0, {}});
    good.edges.push_back(EdgeDesc{1, 21, 1, EdgeKind::audio, 0});
    GraphDescription slow = good;
    slow.version = 6;
    slow.nodes.push_back(NodeDesc{40, NodeKind::compressor, 1, 0, 0, {}});
    slow.edges.push_back(EdgeDesc{3, 40, 1, EdgeKind::audio, 0});
    GraphDescription bad = slow;
    bad.version = 7;
    bad.nodes.push_back(NodeDesc{30, NodeKind::reverb, 1, 0, 0, {}});
    bad.edges.push_back(EdgeDesc{2, 30, 1, EdgeKind::audio, 0});

    uint64_t violations = 0;
    auto renderBlock = [&] {
        std::vector<float> l(256), r(256);
        float* ptrs[2] = {l.data(), r.data()};
        RenderTarget target{AudioBufferView{ptrs, 2, 256}, AudioBufferView{}};
        RtScope scope;
        engine.render(target, 256);
        violations += scope.violations();
    };
    {
        GraphCompiler compiler(engine, std::move(registry), nodes::kRate, 256);
        DAW_CHECK(compiler.wait(compiler.submit(good), 5000ms));
        renderBlock();
        DAW_CHECK(engine.telemetry().snapshot().graphLatency == 100);
        ReportingLatencyNode* node = latent->load();
        DAW_CHECK(node != nullptr);
        if (!node) return checks;

        // daw.compile is busy with v6. Meanwhile the latency changes (a report waits) and v7 is
        // submitted (it waits too). v6 doesn't answer the report (it drained the queue before it
        // arrived); v7 drains it and fails.
        const uint64_t slowTicket = compiler.submit(slow);
        DAW_CHECK(eventually([&] { return gate->entered.load(); }));
        node->setLatency(300);
        const uint64_t badTicket = compiler.submit(bad);
        gate->open.store(true);
        DAW_CHECK(compiler.wait(badTicket, 5000ms));
        DAW_CHECK(compiler.status().completed == badTicket && badTicket > slowTicket);
        // DW-311: the report outlives the failed build: the last good description (v6) is rebuilt
        // with the new latency, and its event says so.
        std::vector<LatencyEvent> events;
        DAW_CHECK(eventually([&] {
            auto more = compiler.takeEvents();
            events.insert(events.end(), more.begin(), more.end());
            return !events.empty();
        }));
        DAW_CHECK(events.size() == 1);
        if (events.size() == 1) {
            DAW_CHECK(events[0].node == 21 && events[0].nodeLatency == 300);
            DAW_CHECK(events[0].graphLatency == 300 && events[0].version == 6);
        }
        const GraphCompiler::Status status = compiler.status();
        DAW_CHECK(status.latencyRebuilds == 1 && status.publishedVersion == 6);
        // The rejection is still reported (the facade turns it into graphRejected).
        DAW_CHECK(status.lastError.has_value() && status.lastError->code == ErrorCode::internal);
        renderBlock();
        DAW_CHECK(engine.telemetry().snapshot().graphLatency == 300);
        // Nothing more: no rebuild loop.
        std::this_thread::sleep_for(50ms);
        DAW_CHECK(compiler.status().latencyRebuilds == 1 && compiler.takeEvents().empty());
    }
    DAW_CHECK(violations == 0);
    return checks;
}

// MARK: DW-312

namespace {

constexpr MeterID kProbeMeter = 4000;

// Outputs 2.0 (a NaN when `nan`) on every channel while its block lies before transport sample
// `before` (the MIX-023 pre-roll of a play from 0 shows its other nodes the frames before 0),
// silence otherwise; counts the blocks it made noise in. With `telemetry` it also writes meter
// kProbeMeter (peak 2) in those blocks only: a meter whose only writes are in the pre-roll.
class BeforeNode final : public Node {
public:
    BeforeNode(bool nan, std::shared_ptr<std::atomic<SamplePos>> before, std::shared_ptr<std::atomic<uint64_t>> blocks,
               Telemetry* telemetry = nullptr)
        : nan_(nan), before_(std::move(before)), blocks_(std::move(blocks)), telemetry_(telemetry) {}
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        const TransportBlock& b = ctx.transport;
        const bool loud = b.numSegments > 0 && b.seg[0].startSample < before_->load(std::memory_order_relaxed);
        fill(io.audioOut, ctx.numFrames,
             loud ? (nan_ ? std::numeric_limits<float>::quiet_NaN() : 2.0f) : 0.0f);
        if (!loud || ctx.numFrames == 0) return;
        blocks_->fetch_add(1, std::memory_order_relaxed);
        if (telemetry_ != nullptr) telemetry_->writeMeter(kProbeMeter, 2.0f, 2.0f);
    }

private:
    bool nan_;
    std::shared_ptr<std::atomic<SamplePos>> before_;
    std::shared_ptr<std::atomic<uint64_t>> blocks_;
    Telemetry* telemetry_;
};

} // namespace

CheckResult preRollFeedsNoTelemetry() {
    CheckResult checks;
    auto before = std::make_shared<std::atomic<SamplePos>>(0);
    auto loudBlocks = std::make_shared<std::atomic<uint64_t>>(0);
    auto nanBlocks = std::make_shared<std::atomic<uint64_t>>(0);
    auto telemetry = std::make_shared<Telemetry*>(nullptr);  // the rig's, once it exists
    nodes::Rig rig([&](NodeRegistry& registry) {
        (void)registry.set(NodeKind::gain, {[](const NodeCreateInfo&) -> Result<std::unique_ptr<Node>> {
                               return std::unique_ptr<Node>(new FakeLatencyNode(512));
                           }});
        (void)registry.set(NodeKind::compressor, {[=](const NodeCreateInfo&) -> Result<std::unique_ptr<Node>> {
                               return std::unique_ptr<Node>(new BeforeNode(false, before, loudBlocks, *telemetry));
                           }});
        (void)registry.set(NodeKind::delay, {[=](const NodeCreateInfo&) -> Result<std::unique_ptr<Node>> {
                               return std::unique_ptr<Node>(new BeforeNode(true, before, nanBlocks));
                           }});
    });
    *telemetry = &rig.engine().telemetry();
    ParamSlotTable& params = rig.engine().params();
    auto limiter = params.allocate(1, 1.0f);  // MIX-009: the master's safety limiter on
    DAW_CHECK(limiter.ok());
    if (!limiter) return checks;
    const ParamID eq = defaults(params, Eq::kParamInfo);
    // latent 20 (512) → loud 30 (writes the probe meter) → master 1: the graph latency is 512,
    //   and the loud node, after the latency, makes 2.0 straight into the master.
    // NaN 50 → EQ 60 (its NaN guard counts) → master.
    // (A channel strip's own 300 ms MeterWindow still takes in pre-roll audio: Discovered work.)
    GraphDescription d = nodes::baseDescription();
    d.nodes[0] = NodeDesc{1, NodeKind::master, 1, limiter.value(), 1, {}};
    d.nodes.push_back(NodeDesc{20, NodeKind::gain, 1, 0, 0, {}});
    d.nodes.push_back(NodeDesc{30, NodeKind::compressor, 1, 0, 0, {}});
    d.nodes.push_back(NodeDesc{50, NodeKind::delay, 1, 0, 0, {}});
    d.nodes.push_back(NodeDesc{60, NodeKind::eq, 1, eq, Eq::kNumParams, {}});
    d.edges.push_back(EdgeDesc{100, 20, 30, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{101, 30, 1, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{103, 50, 60, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{104, 60, 1, EdgeKind::audio, 0});
    DAW_CHECK(rig.publish(d));
    auto block512 = [] { return 512u; };
    auto peakOfMeters = [&] { return rig.engine().telemetry().meter(kProbeMeter).peak; };

    rig.renderFrames(2048, block512);  // stopped: nothing before 0 plays
    Transport& transport = rig.transport();
    DAW_CHECK(transport.locate(0) && transport.play());
    rig.renderFrames(4096, block512);  // the first block pre-rolls 512 frames from -512
    // The pre-roll did make the noise...
    DAW_CHECK(loudBlocks->load() >= 1 && nanBlocks->load() >= 1);
    // ...but DW-312: none of it reached telemetry; the audible blocks (from 0) are silent.
    DAW_CHECK(!rig.engine().telemetry().discardingAudio());
    TelemetrySnapshot s = rig.engine().telemetry().snapshot();
    DAW_CHECK(s.clippedSamples == 0 && s.nanBlocks == 0);
    DAW_CHECK(peakOfMeters() == 0.0f);
    bool silent = true;
    for (float x : rig.left()) silent = silent && x == 0.0f;
    DAW_CHECK(silent);

    // Control: the same audio in blocks that are heard is counted.
    before->store(std::numeric_limits<SamplePos>::max());
    rig.renderFrames(1024, block512);
    s = rig.engine().telemetry().snapshot();
    DAW_CHECK(s.clippedSamples > 0 && s.nanBlocks > 0);
    DAW_CHECK(peakOfMeters() >= 1.0f);
    DAW_CHECK(rig.violations() == 0);
    return checks;
}

// MARK: DW-313

CheckResult silentBlockWithoutGraph() {
    CheckResult checks;
    nodes::Rig rig([](NodeRegistry& registry) {
        (void)registerTestNode(registry, TestNodeSpec{NodeKind::audioClipPlayer, TestNodeType::sine, 440.0, 0.5f});
    });
    Transport& transport = rig.transport();
    auto block256 = [] { return 256u; };

    // No graph published: 300 commands over 300 blocks are all taken (the queue holds 256, so
    // before DW-313 everything after the 256th was refused).
    bool accepted = true;
    for (int i = 0; i < 300; ++i) {
        accepted = accepted && transport.setLoop(i % 2 == 0, 0, 960 + i);
        rig.render(256);
    }
    DAW_CHECK(accepted);
    DAW_CHECK(transport.commandsApplied() == 300);
    // Play applies; a locate waits for a map; the position stays; no map in the block.
    DAW_CHECK(transport.play() && transport.locate(1920));
    rig.render(256);
    DAW_CHECK(transport.playing() && transport.samplePos() == 0);
    DAW_CHECK(transport.block().tempo == nullptr && transport.block().numSegments == 0);

    // M: master ← player 10 (a test sine). The first block with it applies the locate.
    GraphDescription d = nodes::baseDescription();
    d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
    d.edges.push_back(EdgeDesc{100, 10, 1, EdgeKind::audio, 0});
    DAW_CHECK(rig.publish(d));
    rig.render(256);
    const SamplePos at = 1920 * nodes::kSamplesPerTick;
    DAW_CHECK(transport.playhead().tick == 1920 && transport.playhead().playing);
    DAW_CHECK(transport.samplePos() == at + 256 && transport.block().tempo != nullptr);
    DAW_CHECK(transport.block().numSegments == 1 && transport.block().seg[0].startSample == at);

    // Unpublished, and the old graph reclaimed: the next block has no map (it would dangle) and
    // doesn't move; the playhead stays where it was.
    rig.engine().publish(nullptr);
    DAW_CHECK(rig.reclaimPasses(2));
    rig.renderFrames(1024, block256);
    DAW_CHECK(transport.block().tempo == nullptr && transport.samplePos() == at + 256);
    DAW_CHECK(transport.playhead().sample == at);
    DAW_CHECK(transport.stop());
    rig.render(256);
    DAW_CHECK(!transport.playing());
    DAW_CHECK(rig.violations() == 0);
    return checks;
}

CheckResult silentOversizeBlock() {
    CheckResult checks;
    Engine engine;
    NodeRegistry registry = NodeRegistry::withBuiltins();
    (void)registerBuiltinNodes(registry, [](uint64_t) { return AudioAssetRef{}; }, &engine.telemetry());
    (void)registerTestNode(registry, TestNodeSpec{NodeKind::audioClipPlayer, TestNodeType::sine, 440.0, 0.5f});
    GraphBuilder builder(std::move(registry), nodes::kRate, 256);  // maxBlock 256
    GraphDescription d = nodes::baseDescription();
    d.nodes.push_back(NodeDesc{10, NodeKind::audioClipPlayer, 1, 0, 0, {}});
    d.edges.push_back(EdgeDesc{100, 10, 1, EdgeKind::audio, 0});
    auto graph = builder.build(d, engine.nodes(), engine.params());
    DAW_CHECK(graph.ok());
    if (!graph) return checks;
    engine.publish(std::move(graph).value());

    uint64_t violations = 0;
    auto render = [&](uint32_t n) {
        std::vector<float> l(n), r(n);
        float* ptrs[2] = {l.data(), r.data()};
        RenderTarget target{AudioBufferView{ptrs, 2, n}, AudioBufferView{}};
        {
            RtScope scope;
            engine.render(target, n);
            violations += scope.violations();
        }
        return l;
    };
    Transport& transport = engine.transport();
    DAW_CHECK(transport.locate(0) && transport.play());
    const std::vector<float> first = render(256);  // the timeline sine from its start (TIME-008)
    for (int i = 0; i < 3; ++i) (void)render(256);
    DAW_CHECK(transport.samplePos() == 1024);

    // Oversize blocks: silence, but every command applies (300 of them, none refused).
    bool accepted = true;
    for (int i = 0; i < 300; ++i) {
        accepted = accepted && transport.setLoop(false, 0, 960);
        (void)render(512);
    }
    DAW_CHECK(accepted && engine.telemetry().snapshot().oversizeBlocks == 300);
    // A locate in one: the playhead shows it, the position doesn't play on, no map in block().
    DAW_CHECK(transport.locate(960));
    const std::vector<float> oversize = render(512);
    DAW_CHECK(std::all_of(oversize.begin(), oversize.end(), [](float x) { return x == 0.0f; }));
    DAW_CHECK(transport.playhead().tick == 960 && transport.playhead().playing);
    DAW_CHECK(transport.samplePos() == 960 * nodes::kSamplesPerTick);
    DAW_CHECK(transport.block().tempo == nullptr && transport.block().numSegments == 0);
    // The next block that renders resets the timeline nodes for that locate: the sine restarts.
    const std::vector<float> after = render(256);
    DAW_CHECK(after == first);
    DAW_CHECK(transport.samplePos() == 960 * nodes::kSamplesPerTick + 256);
    DAW_CHECK(violations == 0);
    return checks;
}

// MARK: Facade (DW-319..321)

namespace {

struct FakeFacade {
    EngineFacade* facade = nullptr;
    FakeDeviceDriverAdapter* adapter = nullptr;
    std::vector<EngineEventPOD> events;

    FakeFacade(FakeDeviceSpec spec, std::function<Result<void>(NodeRegistry&)> registerNodes = {}) {
        auto owned = std::make_unique<FakeDeviceDriverAdapter>(std::move(spec));
        adapter = owned.get();
        FacadeOptions options;
        options.driver = std::move(owned);
        options.registerNodes = std::move(registerNodes);
        DriverConfigPOD config;
        config.driver = DeviceDriverKind::fake;
        config.sampleRate = 0;
        config.bufferFrames = 256;
        facade = EngineFacadeAccess::create(EngineMode::realtime, config, std::move(options));
    }
    ~FakeFacade() {
        if (facade) releaseFacade(facade);
    }
    uint64_t violations() const {
        FakeDeviceDriver* driver = adapter->driver();
        return (driver ? driver->rtViolations() : 0) + facade->telemetry().rtViolations;
    }
    std::vector<EngineEventPOD> takeAll(EngineEventType type) {
        EngineEventPOD batch[16];
        for (size_t n; (n = facade->pollEvents(batch, 16)) > 0;)
            for (size_t i = 0; i < n; ++i) events.push_back(batch[i]);
        std::vector<EngineEventPOD> out;
        std::erase_if(events, [&](const EngineEventPOD& e) {
            if (e.type != type) return false;
            out.push_back(e);
            return true;
        });
        return out;
    }
};

// Onsets: the first frame of each run of non-silence after at least `gap` silent frames.
std::vector<int64_t> onsets(const float* x, int64_t n, int64_t gap = 2000) {
    std::vector<int64_t> out;
    int64_t quiet = gap;
    for (int64_t i = 0; i < n; ++i) {
        if (std::abs(x[i]) > 1e-4f) {
            if (quiet >= gap) out.push_back(i);
            quiet = 0;
        } else {
            ++quiet;
        }
    }
    return out;
}

std::optional<LoadedAudio> load(const std::string& file) {
    AudioLoadRequest request;
    request.file = file;
    request.sessionRate = nodes::kRate;
    auto loaded = AudioFileLoader::load(request);
    if (!loaded) return std::nullopt;
    return std::move(loaded).value();
}

} // namespace

CheckResult deviceBufferChangeEndsTakes() {
    CheckResult checks;
    FakeDeviceSpec spec;
    FakeDevice device;
    device.id = 1;
    device.name = "Loopback";
    device.outputLatency = LatencyComponents{37, 11, 5, 0};  // + buffer
    device.inputLatency = LatencyComponents{23, 7, 0, 0};    // + buffer
    spec.devices = {device};
    spec.pacing = FakePacing::asFastAsPossible;
    spec.cycleLimit = 0;  // parked until the test lets it run
    auto latencyAt = [](int64_t buffer) { return (37 + 11 + 5 + buffer) + (23 + 7 + buffer); };

    TempDir dir;
    FakeFacade f(spec);
    DAW_CHECK(f.facade != nullptr);
    if (!f.facade) return checks;
    EngineFacade& facade = *f.facade;
    // master ← metronome: a click on every beat (24000 frames).
    const ParamID p = facade.allocateParams(Metronome::kNumParams);
    facade.setParam(p + Metronome::kOn, 1.0f);
    facade.setParam(p + Metronome::kLevel, 0.5f);
    facade.setParam(p + Metronome::kAccent, 1.0f);
    GraphDescriptionBuilder b;
    b.addNode(1, NodeKind::master, 1, 0, 0, "");
    b.addNode(10, NodeKind::metronome, 1, p, Metronome::kNumParams, "");
    b.addEdge(1, 10, 1, EdgeKind::audio, 0);
    b.setTempo(0, 120.0);
    b.setTimeSignature(0, 4, 4);
    b.setMaster(1);
    const uint64_t version = facade.applyGraph(b.description());
    DAW_CHECK(facade.waitForGraph(version, 5000).publishedVersion == version);
    facade.setRecordingDirectory(dir.path().string());
    facade.armInput(5, 0, true);
    DAW_CHECK(facade.telemetry().deviceInputLatency == 23 + 7 + 256);

    // 100 cycles of 256 at buffer 256: beats 0 and 24000.
    facade.setRecording(true);
    facade.play();
    FakeDeviceDriver* driver = f.adapter->driver();
    DAW_CHECK(driver != nullptr);
    if (!driver) return checks;
    driver->setCycleLimit(driver->cycles() + 100);
    DAW_CHECK(driver->waitUntilIdle(10000ms));
    DAW_CHECK(f.takeAll(EngineEventType::recordingFinalized).empty());

    // DW-319: the buffer grows to 1024 at the same rate. The take ends here, at its latency.
    DriverConfigPOD config;
    config.driver = DeviceDriverKind::fake;
    config.sampleRate = 0;
    config.bufferFrames = 1024;
    DAW_CHECK(facade.setDevice(config).ok());
    auto first = f.takeAll(EngineEventType::recordingFinalized);
    DAW_CHECK(first.size() == 1);
    DAW_CHECK(facade.transport().recording && facade.transport().playing);  // recording goes on
    DAW_CHECK(facade.telemetry().deviceInputLatency == 23 + 7 + 1024);

    // 60 cycles of 1024 from transport 25600: beats 48000 and 72000.
    driver->setCycleLimit(driver->cycles() + 60);
    DAW_CHECK(driver->waitUntilIdle(10000ms));
    facade.stop();
    auto second = f.takeAll(EngineEventType::recordingFinalized);
    DAW_CHECK(second.size() == 1);
    if (first.size() != 1 || second.size() != 1) return checks;

    // Each take's clicks land on their beats once the file is placed at startSample (REC-003),
    // each with the latency it was recorded at; nothing from after the change is in the first.
    struct Expect {
        const RecordingPOD& take;
        int64_t start;
        int64_t frames;
        std::vector<int64_t> beats;
    };
    const Expect expect[] = {
        {first[0].recording, -latencyAt(256), 100 * 256, {0, 24000}},
        {second[0].recording, 25600 - latencyAt(1024), 60 * 1024, {48000, 72000}},
    };
    for (const Expect& e : expect) {
        DAW_CHECK(e.take.track == 5 && e.take.startSample == e.start && e.take.frames == e.frames);
        auto audio = load(e.take.file);
        DAW_CHECK(audio.has_value());
        if (!audio) continue;
        const std::vector<int64_t> at = onsets(audio->asset->data[0], audio->asset->frames);
        DAW_CHECK(at.size() == e.beats.size());
        for (size_t i = 0; i < at.size() && i < e.beats.size(); ++i)
            DAW_CHECK(std::abs(e.take.startSample + at[i] - e.beats[i]) <= 1);
    }
    DAW_CHECK(f.violations() == 0);
    return checks;
}

namespace {

// DW-320/321: an export that waits inside its first playing block until the test lets it go, so
// the test acts while it is certainly running. Silence otherwise; DC 0.25 while playing, so a
// file has something in it. The spin is bounded (10 s) so a broken test can't hang.
struct ExportGate {
    std::atomic<bool> hold{false};
    std::atomic<uint64_t> held{0};  // playing blocks that waited
    uint64_t limitTicks = 0;
    ExportGate() {
        mach_timebase_info_data_t base{};
        mach_timebase_info(&base);
        limitTicks = 10'000'000'000ull * base.denom / base.numer;
    }
};

class GateNode final : public Node {
public:
    explicit GateNode(std::shared_ptr<ExportGate> gate) : gate_(std::move(gate)) {}
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        const bool playing = ctx.transport.playing && ctx.transport.numSegments > 0;
        fill(io.audioOut, ctx.numFrames, playing ? 0.25f : 0.0f);
        if (!playing || !gate_->hold.load(std::memory_order_acquire)) return;
        gate_->held.fetch_add(1, std::memory_order_release);
        const uint64_t start = Telemetry::clockTicks();
        while (gate_->hold.load(std::memory_order_acquire) && Telemetry::clockTicks() - start < gate_->limitTicks) {
        }
    }

private:
    std::shared_ptr<ExportGate> gate_;
};

struct GatedFacade : FakeFacade {
    std::shared_ptr<ExportGate> gate;
    explicit GatedFacade(std::shared_ptr<ExportGate> g)
        : FakeFacade(defaultFakeDeviceSpec(),
                     [g](NodeRegistry& registry) {
                         return registry.set(NodeKind::gain, {[g](const NodeCreateInfo&) -> Result<std::unique_ptr<Node>> {
                                                 return std::unique_ptr<Node>(new GateNode(g));
                                             }});
                     }),
          gate(std::move(g)) {}

    // master ← gate.
    bool publish() {
        GraphDescriptionBuilder b;
        b.addNode(1, NodeKind::master, 1, 0, 0, "");
        b.addNode(20, NodeKind::gain, 1, 0, 0, "");
        b.addEdge(1, 20, 1, EdgeKind::audio, 0);
        b.setTempo(0, 120.0);
        b.setTimeSignature(0, 4, 4);
        b.setMaster(1);
        const uint64_t version = facade->applyGraph(b.description());
        return facade->waitForGraph(version, 5000).publishedVersion == version;
    }
    // A held export of [0, to) into `file` that has reached its first playing block.
    JobID startHeld(const std::filesystem::path& file, Tick to) {
        gate->hold.store(true);
        const uint64_t held = gate->held.load();
        ExportSpecPOD spec;
        spec.path = file.string();
        spec.tailEnabled = false;
        const JobID job = facade->renderOffline(0, to, spec);
        if (job == 0 || !eventually([&] { return gate->held.load() > held; })) return 0;
        return job;
    }
    JobStatus waitFinished(JobID job, std::chrono::milliseconds timeout = 20000ms) {
        JobStatus status;
        (void)eventually([&] {
            status = facade->pollJob(job);
            return status.state == JobState::succeeded || status.state == JobState::failed ||
                   status.state == JobState::cancelled;
        }, timeout);
        return status;
    }
};

} // namespace

CheckResult transportCallsDuringExport() {
    CheckResult checks;
    TempDir dir;
    GatedFacade f(std::make_shared<ExportGate>());
    DAW_CHECK(f.facade != nullptr);
    if (!f.facade) return checks;
    EngineFacade& facade = *f.facade;
    DAW_CHECK(f.publish());
    facade.locate(480);

    // play, setRecording, locate and setLoop while the export renders its first block.
    const auto file = dir.path() / "a.wav";
    const JobID job = f.startHeld(file, 4 * kPPQ);  // 2 s
    DAW_CHECK(job != 0);
    facade.armInput(5, 0, true);  // something to record, were recording allowed
    facade.play();               // ignored
    facade.setRecording(true);   // ignored
    facade.locate(1920);         // after the export
    facade.setLoop(true, 960, 2880);
    DAW_CHECK(facade.pollJob(job).state == JobState::running);
    f.gate->hold.store(false);
    const JobStatus done = f.waitFinished(job);
    // The export didn't notice (before DW-320 it failed: "the transport didn't follow").
    DAW_CHECK(done.state == JobState::succeeded && done.error.ok());
    DAW_CHECK(done.render.framesWritten == 4 * kPPQ * nodes::kSamplesPerTick && done.render.rtViolations == 0);
    DAW_CHECK(std::filesystem::exists(file));
    // Afterwards: stopped, not recording, at the locate, with the loop.
    DAW_CHECK(eventually([&] { return facade.transport().tick == 1920; }));
    const TransportPOD t = facade.transport();
    DAW_CHECK(!t.playing && !t.recording);
    DAW_CHECK(t.loopEnabled && t.loopStart == 960 && t.loopEnd == 2880);
    DAW_CHECK(f.takeAll(EngineEventType::recordingFinalized).empty());
    facade.armInput(5, 0, false);

    // stop: the running export and the one queued behind it are cancelled, their files gone.
    const auto running = dir.path() / "b.wav";
    const auto queued = dir.path() / "c.wav";
    const JobID first = f.startHeld(running, 4 * kPPQ);
    DAW_CHECK(first != 0);
    ExportSpecPOD spec;
    spec.path = queued.string();
    spec.tailEnabled = false;
    const JobID second = facade.renderOffline(0, 4 * kPPQ, spec);
    DAW_CHECK(second != 0 && facade.pollJob(second).state == JobState::queued);
    facade.stop();
    DAW_CHECK(facade.pollJob(second).state == JobState::cancelled);  // at once
    f.gate->hold.store(false);
    DAW_CHECK(f.waitFinished(first).state == JobState::cancelled);
    DAW_CHECK(!std::filesystem::exists(running) && !std::filesystem::exists(queued));
    DAW_CHECK(f.takeAll(EngineEventType::jobFinished).size() >= 3);
    // The transport is as it was (stopped, at 1920), and plays again once the export is gone.
    DAW_CHECK(eventually([&] { return facade.transport().tick == 1920 && !facade.transport().playing; }));
    facade.setLoop(false, 960, 2880);
    facade.play();
    DAW_CHECK(eventually([&] { return facade.transport().playing && facade.transport().tick > 1920; }));
    facade.stop();
    DAW_CHECK(f.violations() == 0);
    return checks;
}

CheckResult facadeDestroyCancelsExport() {
    CheckResult checks;
    TempDir dir;
    const auto file = dir.path() / "long.wav";
    std::chrono::steady_clock::duration took{};
    {
        auto gate = std::make_shared<ExportGate>();
        auto* f = new GatedFacade(gate);
        const bool published = f->facade != nullptr && f->publish();
        DAW_CHECK(published);
        // An hour: far longer than the test may take.
        const JobID job = published ? f->startHeld(file, Tick{kPPQ} * 2 * 3600) : 0;
        DAW_CHECK(job != 0);
        DAW_CHECK(std::filesystem::exists(file));  // the export has its file open
        gate->hold.store(false);
        const auto start = std::chrono::steady_clock::now();
        delete f;  // releases the facade: ~Impl joins daw.export
        took = std::chrono::steady_clock::now() - start;
    }
    // DW-321: cancelled, not rendered to the end; the partial file is deleted.
    DAW_CHECK(took < 1s);  // rendering the hour takes several seconds even here
    DAW_CHECK(!std::filesystem::exists(file));
    return checks;
}

} // namespace daw::testing
