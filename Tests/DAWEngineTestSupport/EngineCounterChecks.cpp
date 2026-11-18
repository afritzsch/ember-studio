// T-099 checks for the telemetry counters clippedSamples, midiEventsDropped and bufferFrames
// (08 "Contract delta (T-099)"). Run from Tests/DAWEngineTests/EngineCounterTests.swift.

#include "EngineCounterChecks.h"

#include <cstring>
#include <memory>
#include <utility>

#include "NodeTestHarness.h"
#include "TestNodes.h"
#include "daw/EngineFacade.h"
#include "facade/DriverAdapter.h"
#include "facade/FacadeOptions.h"
#include "graph/MasterNode.h"
#include "io/FakeDeviceDriver.h"

namespace daw::testing {

using nodes::Rig;
using nodes::baseDescription;

namespace {

NodeDesc node(NodeID id, NodeKind kind, uint32_t configVersion = 1, ParamID firstParam = 0, uint32_t numParams = 0) {
    return NodeDesc{id, kind, configVersion, firstParam, numParams, {}};
}

// A MIDI source (registered as midiClipPlayer) that writes `perBlock` CC 7 events, spread over
// the block in frame order, in each of its first `blocks` blocks, and counts what it wrote.
class MidiFlood final : public Node {
public:
    MidiFlood(uint32_t perBlock, uint32_t blocks) : perBlock_(perBlock), blocks_(blocks) {}
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        if (block_++ >= blocks_ || ctx.numFrames == 0) return;
        for (uint32_t i = 0; i < perBlock_; ++i) {
            MidiEvent e{};
            e.frameOffset = static_cast<uint32_t>(uint64_t{i} * ctx.numFrames / perBlock_);
            e.size = 3;
            e.data[0] = 0xB0;
            e.data[1] = 7;
            e.data[2] = static_cast<uint8_t>(i & 0x7F);
            if (io.midiOut.push(e)) ++written_;
        }
    }
    uint64_t written() const { return written_; }

private:
    uint32_t perBlock_, blocks_;
    uint32_t block_ = 0;
    uint64_t written_ = 0;
};

// An instrument stand-in (registered as sampler): counts the MIDI events it receives, passes its
// audio input through (silence here).
class MidiCounter final : public Node {
public:
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext&, NodeIO& io) DAW_RT override {
        received_ += io.midiIn.size();
        const AudioBufferView& out = io.audioOut;
        for (uint32_t c = 0; c < out.numChannels; ++c)
            std::memset(out.channels[c], 0, std::size_t{out.numFrames} * sizeof(float));
    }
    uint64_t received() const { return received_; }

private:
    uint64_t received_ = 0;
};

constexpr uint32_t kFloodPerBlock = 600;
constexpr uint32_t kFloodBlocks = 20;
constexpr uint32_t kLatency = 20000;  // 40 blocks of 500 in flight: far beyond a line's 4096

void registerFloodNodes(NodeRegistry& registry) {
    NodeKindInfo flood{[](const NodeCreateInfo&) -> Result<std::unique_ptr<Node>> {
        return std::unique_ptr<Node>(new MidiFlood(kFloodPerBlock, kFloodBlocks));
    }};
    flood.audioOutput = false;
    (void)registry.set(NodeKind::midiClipPlayer, std::move(flood));
    (void)registry.set(NodeKind::sampler, {[](const NodeCreateInfo&) -> Result<std::unique_ptr<Node>> {
        return std::unique_ptr<Node>(new MidiCounter);
    }});
    (void)registry.set(NodeKind::eq, {[](const NodeCreateInfo&) -> Result<std::unique_ptr<Node>> {
        return std::unique_ptr<Node>(new FakeLatencyNode(kLatency));
    }});
}

// master 1 ← counter 5 ←audio— latency 3 ←audio— clip player 2 (no clips)
//                     ←midi—  flood 4 (the MIDI edge gets a 20000-frame PDC line)
GraphDescription floodGraph(uint64_t version) {
    GraphDescription d = baseDescription();
    d.version = version;
    d.nodes.push_back(node(2, NodeKind::audioClipPlayer));
    d.nodes.push_back(node(3, NodeKind::eq));
    d.nodes.push_back(node(4, NodeKind::midiClipPlayer));
    d.nodes.push_back(node(5, NodeKind::sampler));
    d.edges.push_back(EdgeDesc{10, 2, 3, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{11, 3, 5, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{12, 4, 5, EdgeKind::midi, 0});
    d.edges.push_back(EdgeDesc{13, 5, 1, EdgeKind::audio, 0});
    return d;
}

} // namespace

// MARK: DW-083

CheckResult masterClipsCountIntoTelemetry() {
    CheckResult checks;
    Rig rig;
    rig.addAsset(nodes::makeAsset(7, 1, 48000, [](uint32_t, int64_t) { return 2.0f; }));
    auto limiter = rig.engine().params().allocate(1, 0.0f);
    DAW_CHECK(limiter.ok());
    if (!limiter) return checks;
    const auto describe = [&](uint32_t masterVersion) {
        GraphDescription d = baseDescription();
        d.nodes[0] = node(1, NodeKind::master, masterVersion, limiter.value(), 1);
        d.nodes.push_back(node(2, NodeKind::audioClipPlayer));
        d.edges.push_back(EdgeDesc{10, 2, 1, EdgeKind::audio, 0});
        d.audioClips.push_back(nodes::clip(2, 20, 0, 960 * 8, 7));  // 4 s of 2.0
        return d;
    };
    const Telemetry& telemetry = rig.engine().telemetry();
    DAW_CHECK(rig.publish(describe(1)));
    DAW_CHECK(rig.transport().locate(0) && rig.transport().play());

    // Limiter off: the overs pass and nothing counts.
    for (int b = 0; b < 10; ++b) rig.render(480);
    DAW_CHECK(telemetry.snapshot().clippedSamples == 0);

    rig.engine().params().set(limiter.value(), 1.0f);
    for (int b = 0; b < 10; ++b) rig.render(480);
    auto* first = static_cast<MasterNode*>(rig.engine().nodes().get(1).get());
    const uint64_t firstCount = first->clippedSamples();
    DAW_CHECK(firstCount >= 4800);  // every frame of 10 blocks, at least one channel
    DAW_CHECK(telemetry.snapshot().clippedSamples == firstCount);

    // A new master instance: its count starts at 0, telemetry's goes on.
    DAW_CHECK(rig.publish(describe(2)));
    for (int b = 0; b < 10; ++b) rig.render(480);
    auto* second = static_cast<MasterNode*>(rig.engine().nodes().get(1).get());
    DAW_CHECK(second != first);
    DAW_CHECK(second->clippedSamples() == firstCount);  // same signal, same overs
    DAW_CHECK(telemetry.snapshot().clippedSamples == 2 * firstCount);
    DAW_CHECK(rig.violations() == 0);
    return checks;
}

// MARK: DW-170

CheckResult midiDelayLineDropsCountIntoTelemetry() {
    CheckResult checks;
    for (const bool rebuild : {false, true}) {
        Rig rig(registerFloodNodes);
        const Telemetry& telemetry = rig.engine().telemetry();
        DAW_CHECK(rig.publish(floodGraph(1)));
        for (int b = 0; b < 200; ++b) {
            // The same edge ID: the new graph carries the line, its queue and its count over.
            if (rebuild && b == 10) DAW_CHECK(rig.publish(floodGraph(2)));
            rig.render(500);
        }
        auto* flood = static_cast<MidiFlood*>(rig.engine().nodes().get(4).get());
        auto* counter = static_cast<MidiCounter*>(rig.engine().nodes().get(5).get());
        DAW_CHECK(flood != nullptr && counter != nullptr);
        if (!flood || !counter) return checks;
        const uint64_t dropped = telemetry.snapshot().midiEventsDropped;
        DAW_CHECK(flood->written() == uint64_t{kFloodPerBlock} * kFloodBlocks);
        DAW_CHECK(dropped > 0);  // the line overflowed
        DAW_CHECK(counter->received() > 0);
        // Everything written arrived or was counted as dropped, exactly once.
        DAW_CHECK(counter->received() + dropped == flood->written());
        DAW_CHECK(rig.violations() == 0);
    }
    // No overflow, no count: a short flood fits the line.
    {
        Rig rig([](NodeRegistry& registry) {
            registerFloodNodes(registry);
            NodeKindInfo small{[](const NodeCreateInfo&) -> Result<std::unique_ptr<Node>> {
                return std::unique_ptr<Node>(new MidiFlood(100, 5));
            }};
            small.audioOutput = false;
            (void)registry.set(NodeKind::midiClipPlayer, std::move(small));
        });
        DAW_CHECK(rig.publish(floodGraph(1)));
        for (int b = 0; b < 100; ++b) rig.render(500);
        auto* counter = static_cast<MidiCounter*>(rig.engine().nodes().get(5).get());
        DAW_CHECK(counter != nullptr && counter->received() == 500);
        DAW_CHECK(rig.engine().telemetry().snapshot().midiEventsDropped == 0);
        DAW_CHECK(rig.violations() == 0);
    }
    return checks;
}

// MARK: DW-192

CheckResult facadeReportsDeviceBufferFrames() {
    CheckResult checks;
    {
        auto owned = std::make_unique<FakeDeviceDriverAdapter>(defaultFakeDeviceSpec());
        FacadeOptions options;
        options.driver = std::move(owned);
        DriverConfigPOD config;
        config.driver = DeviceDriverKind::fake;
        config.sampleRate = 0;
        config.bufferFrames = 256;
        EngineFacade* created = EngineFacadeAccess::create(EngineMode::realtime, config, std::move(options));
        DAW_CHECK(created != nullptr);
        if (!created) return checks;
        std::unique_ptr<EngineFacade, void (*)(EngineFacade*)> owner(created, releaseFacade);
        EngineFacade& facade = *created;

        TelemetryPOD t = facade.telemetry();
        DAW_CHECK(t.deviceRunning && t.bufferFrames == 256);
        config.bufferFrames = 128;
        DAW_CHECK(facade.setDevice(config).ok());
        t = facade.telemetry();
        DAW_CHECK(t.deviceRunning && t.bufferFrames == 128);

        // Both fake devices gone: nothing runs, so no buffer size.
        DeviceEventPOD lost;
        lost.kind = DeviceEventKind::deviceLost;
        lost.deviceID = 1;
        DAW_CHECK(facade.simulateDeviceEvent(lost).ok());
        lost.deviceID = 2;
        DAW_CHECK(facade.simulateDeviceEvent(lost).ok());
        t = facade.telemetry();
        DAW_CHECK(!t.deviceRunning && t.bufferFrames == 0);
    }
    {
        DriverConfigPOD config;
        config.sampleRate = 48000.0;
        EngineFacade* created = EngineFacade::create(EngineMode::offline, config);
        DAW_CHECK(created != nullptr);
        if (!created) return checks;
        std::unique_ptr<EngineFacade, void (*)(EngineFacade*)> owner(created, releaseFacade);
        const TelemetryPOD t = created->telemetry();
        DAW_CHECK(!t.deviceRunning && t.bufferFrames == 0);
        DAW_CHECK(t.clippedSamples == 0 && t.midiEventsDropped == 0);
    }
    return checks;
}

} // namespace daw::testing
