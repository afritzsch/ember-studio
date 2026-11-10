// T-054 checks for input monitoring (REC-020..022). Run from Tests/DAWEngineTests/MonitoringTests.swift;
// see MonitoringChecks.h.

#include "MonitoringChecks.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <functional>
#include <memory>
#include <thread>
#include <utility>
#include <vector>

#include "GoldenEngineSupport.h"
#include "NodeTestHarness.h"
#include "TestNodes.h"
#include "core/AudioBufferView.h"
#include "core/InputMonitoring.h"
#include "core/RenderTarget.h"
#include "core/RtTrap.h"
#include "daw/EngineFacade.h"
#include "facade/DriverAdapter.h"
#include "facade/FacadeOptions.h"
#include "io/FakeDeviceDriver.h"
#include "nodes/GainNode.h"
#include "nodes/Metronome.h"

using namespace std::chrono_literals;

namespace daw::testing {

namespace {

using nodes::baseDescription;
using nodes::clip;
using nodes::makeAsset;
using nodes::Rig;

constexpr float kClip = 0.25f;
constexpr float kPair0 = 0.9f;                  // input channels 0, 1: must never be heard
constexpr float kLeftIn = 0.5f, kRightIn = -0.5f;  // input pair 1 (channels 2, 3)
constexpr NodeID kPlayer = 100;
constexpr float kEps = 1e-6f;

// A track (clip player 100, one clip of kClip on both channels over the first ~2 s) into the
// master, monitored on input pair 1 with mode slot `slot`.
GraphDescription trackDescription(ParamID slot, bool armed, uint32_t pair = 1) {
    GraphDescription d = baseDescription();
    d.nodes.push_back(NodeDesc{kPlayer, NodeKind::audioClipPlayer, 1, 0, 0, {}});
    d.edges.push_back(EdgeDesc{1, kPlayer, 1, EdgeKind::audio, 0});
    d.audioClips.push_back(clip(kPlayer, 1, 0, 4000, 1));
    d.monitors.push_back(MonitorDesc{kPlayer, slot, pair, armed});
    return d;
}

// Renders an Engine block by block with a 4-channel device input of constants (or none: an
// offline render), collecting the master output.
struct MonitorRig {
    Rig rig;
    std::vector<std::vector<float>> in = std::vector<std::vector<float>>(4, std::vector<float>(kMaxBlock));
    float* inPtrs[4]{};
    std::vector<float> left, right;
    uint64_t violations = 0;

    explicit MonitorRig(const std::function<void(NodeRegistry&)>& extra = {}) : rig(extra) {
        const float values[4] = {kPair0, kPair0, kLeftIn, kRightIn};
        for (uint32_t c = 0; c < 4; ++c) {
            std::fill(in[c].begin(), in[c].end(), values[c]);
            inPtrs[c] = in[c].data();
        }
        rig.addAsset(makeAsset(1, 2, 200'000, [](uint32_t, int64_t) { return kClip; }));
    }

    // Appends `frames` frames in blocks of 256; returns the index of the first one.
    size_t render(uint32_t frames, bool withInput = true) {
        const size_t first = left.size();
        for (uint32_t done = 0; done < frames;) {
            const uint32_t n = std::min<uint32_t>(256, frames - done);
            std::vector<float> l(n, -99.0f), r(n, -99.0f);
            float* out[2] = {l.data(), r.data()};
            RenderTarget target;
            target.output = AudioBufferView{out, 2, n};
            if (withInput) target.input = AudioBufferView{inPtrs, 4, n};
            {
                RtScope scope;
                rig.engine().render(target, n);
                violations += scope.violations();
            }
            left.insert(left.end(), l.begin(), l.end());
            right.insert(right.end(), r.begin(), r.end());
            done += n;
        }
        return first;
    }

    bool all(size_t from, size_t to, float l, float r) const {
        for (size_t i = from; i < to && i < left.size(); ++i)
            if (std::abs(left[i] - l) > kEps || std::abs(right[i] - r) > kEps) return false;
        return to <= left.size();
    }
};

} // namespace

// MARK: REC-020 truth table

CheckResult monitoringTruthTable() {
    CheckResult checks;
    using M = MonitoringMode;
    // {playing, recording}: stopped, playing, playing + recording, record-enabled but stopped.
    const bool states[4][2] = {{false, false}, {true, false}, {true, true}, {false, true}};
    for (const bool armed : {false, true}) {
        for (const auto& s : states) {
            DAW_CHECK(!monitoringActive(M::off, armed, s[0], s[1]));
            DAW_CHECK(monitoringActive(M::on, armed, s[0], s[1]));
        }
        DAW_CHECK(monitoringActive(M::automatic, armed, false, false) == armed);  // stopped
        DAW_CHECK(!monitoringActive(M::automatic, armed, true, false));           // playback
        DAW_CHECK(monitoringActive(M::automatic, armed, true, true) == armed);    // recording
        DAW_CHECK(monitoringActive(M::automatic, armed, false, true) == armed);   // stopped
    }
    DAW_CHECK(monitoringModeFromSlot(0.0f) == M::off);
    DAW_CHECK(monitoringModeFromSlot(1.0f) == M::on);
    DAW_CHECK(monitoringModeFromSlot(2.0f) == M::automatic);
    DAW_CHECK(monitoringModeFromSlot(3.0f) == M::off);
    DAW_CHECK(monitoringModeFromSlot(-1.0f) == M::off);
    DAW_CHECK(monitoringModeFromSlot(std::nanf("")) == M::off);
    return checks;
}

// MARK: REC-020/021 through the Engine

CheckResult engineMonitorsInputInPlaceOfClip() {
    CheckResult checks;
    MonitorRig m;
    Engine& engine = m.rig.engine();
    auto slot = engine.params().allocate(1, 0.0f);  // off
    DAW_CHECK(slot.ok());
    if (!slot) return checks;
    const ParamID mode = slot.value();
    DAW_CHECK(m.rig.publish(trackDescription(mode, false)));

    // off: the clip player as it is (silent while stopped, the clip while playing).
    size_t at = m.render(512);
    DAW_CHECK(m.all(at, at + 512, 0.0f, 0.0f));
    (void)m.rig.transport().play();
    at = m.render(512);
    DAW_CHECK(m.all(at, at + 512, kClip, kClip));

    // on while playing over the clip: a kMonitorFadeFrames crossfade, then exactly input pair 1,
    // never the clip (REC-021: no leak) nor pair 0.
    engine.params().set(mode, 1.0f);
    at = m.render(1024);
    bool monotonic = true;
    for (size_t i = at + 1; i < at + kMonitorFadeFrames; ++i)
        monotonic = monotonic && m.left[i] >= m.left[i - 1] && m.right[i] <= m.right[i - 1];
    DAW_CHECK(monotonic);
    DAW_CHECK(m.left[at] > kClip && m.left[at] < kLeftIn);
    DAW_CHECK(m.all(at + kMonitorFadeFrames - 1, at + 1024, kLeftIn, kRightIn));
    // Stopped, still on.
    (void)m.rig.transport().stop();
    at = m.render(512);
    DAW_CHECK(m.all(at, at + 512, kLeftIn, kRightIn));

    // auto, unarmed: never monitors (stopped: the silent player after the fade).
    engine.params().set(mode, 2.0f);
    at = m.render(512);
    DAW_CHECK(m.all(at + kMonitorFadeFrames, at + 512, 0.0f, 0.0f));

    // Arming is structural: a new description. auto + armed + stopped → input at once (a new
    // graph starts at its state without a fade).
    DAW_CHECK(m.rig.publish(trackDescription(mode, true)));
    at = m.render(512);
    DAW_CHECK(m.all(at, at + 512, kLeftIn, kRightIn));
    // Playing without recording → the clip, after the fade.
    (void)m.rig.transport().play();
    at = m.render(512);
    DAW_CHECK(m.all(at + kMonitorFadeFrames, at + 512, kClip, kClip));
    // Recording → input again.
    (void)m.rig.transport().setRecording(true);
    at = m.render(512);
    DAW_CHECK(m.all(at + kMonitorFadeFrames, at + 512, kLeftIn, kRightIn));

    // An offline render (no device input) plays the clip whatever the mode (an export never
    // monitors).
    engine.params().set(mode, 1.0f);
    at = m.render(512, false);
    DAW_CHECK(m.all(at, at + 512, kClip, kClip));
    // Back to device input: on snaps to the input (the offline block reset the state).
    at = m.render(256);
    DAW_CHECK(m.all(at, at + 256, kLeftIn, kRightIn));

    // Input pair 0 when the description says so.
    DAW_CHECK(m.rig.publish(trackDescription(mode, true, 0)));
    at = m.render(256);
    DAW_CHECK(m.all(at, at + 256, kPair0, kPair0));
    DAW_CHECK(m.violations == 0);
    return checks;
}

// MARK: REC-021 and MIX-023 pre-roll

CheckResult monitoringPreRollLeaksNoClip() {
    CheckResult checks;
    TestNodeSpec latency;
    latency.kind = NodeKind::delay;
    latency.type = TestNodeType::fakeLatency;
    latency.samples = 300;
    MonitorRig m([&](NodeRegistry& registry) { (void)registerTestNode(registry, latency); });
    Engine& engine = m.rig.engine();
    auto slot = engine.params().allocate(1, 1.0f);  // on
    DAW_CHECK(slot.ok());
    if (!slot) return checks;
    GraphDescription d = trackDescription(slot.value(), false);
    d.nodes.push_back(NodeDesc{200, NodeKind::delay, 1, 0, 0, {}});
    d.edges = {EdgeDesc{1, kPlayer, 200, EdgeKind::audio, 0}, EdgeDesc{2, 200, 1, EdgeKind::audio, 0}};
    DAW_CHECK(m.rig.publish(d));

    size_t at = m.render(1024);  // stopped: the input, 300 samples late
    DAW_CHECK(m.all(at + 300, at + 1024, kLeftIn, kRightIn));
    (void)m.rig.transport().play();  // pre-rolls 300 frames
    at = m.render(4096);
    // Not one sample of the clip: everything is the input or silence (the pre-roll's 300 frames,
    // which had no input to give).
    bool onlyInputOrSilence = true;
    for (size_t i = at; i < at + 4096; ++i) {
        const bool silent = std::abs(m.left[i]) <= kEps && std::abs(m.right[i]) <= kEps;
        const bool input = std::abs(m.left[i] - kLeftIn) <= kEps && std::abs(m.right[i] - kRightIn) <= kEps;
        onlyInputOrSilence = onlyInputOrSilence && (silent || input);
    }
    DAW_CHECK(onlyInputOrSilence);
    DAW_CHECK(m.all(at + 300, at + 4096, kLeftIn, kRightIn));
    // Off: after the fade, exactly the clip arrives (300 samples late, aligned by PDC).
    engine.params().set(slot.value(), 0.0f);
    at = m.render(2048);
    DAW_CHECK(m.all(at + 300 + kMonitorFadeFrames, at + 2048, kClip, kClip));
    DAW_CHECK(m.violations == 0);
    return checks;
}

// MARK: REC-022 validation and slots

CheckResult monitorsAreValidatedAndModeIsASlot() {
    CheckResult checks;
    MonitorRig m;
    Engine& engine = m.rig.engine();
    auto slot = engine.params().allocate(1, 0.0f);
    DAW_CHECK(slot.ok());
    if (!slot) return checks;
    const ParamID mode = slot.value();
    const auto rejected = [&](GraphDescription d) {
        auto built = m.rig.build(d);
        return !built.ok() && built.error().code == ErrorCode::invalidArgument;
    };
    {
        GraphDescription d = trackDescription(mode, false);
        d.monitors[0].player = 999;  // unknown
        DAW_CHECK(rejected(d));
        d.monitors[0].player = 1;  // the master, not a clip player
        DAW_CHECK(rejected(d));
    }
    {
        GraphDescription d = trackDescription(mode, false);
        d.monitors[0].modeSlot = mode + 1;  // not allocated
        DAW_CHECK(rejected(d));
        d.monitors[0].modeSlot = 0xFFFF'FFFEu;  // outside the table
        DAW_CHECK(rejected(d));
    }
    {
        GraphDescription d = trackDescription(mode, false, 16);  // pairs are 0…15
        DAW_CHECK(rejected(d));
        d = trackDescription(mode, false, 15);
        DAW_CHECK(m.rig.build(d).ok());
        d.monitors.push_back(d.monitors[0]);  // a player monitored twice
        DAW_CHECK(rejected(d));
    }
    {
        // A description without monitors (graphs built by hand, older callers) plays clips.
        GraphDescription d = trackDescription(mode, false);
        d.monitors.clear();
        auto built = m.rig.build(d);
        DAW_CHECK(built.ok() && built.value()->numMonitors() == 0);
    }

    // The mode is a slot: one published graph, three different outcomes, no publish in between.
    auto built = m.rig.build(trackDescription(mode, false));
    DAW_CHECK(built.ok());
    if (!built) return checks;
    const RenderGraph* graph = built.value().get();
    DAW_CHECK(graph->numMonitors() == 1);
    engine.publish(std::move(built).value());
    (void)m.rig.transport().play();
    size_t at = m.render(512);
    DAW_CHECK(m.all(at, at + 512, kClip, kClip) && !graph->monitorActive(0));
    engine.params().set(mode, 1.0f);
    at = m.render(512);
    DAW_CHECK(m.all(at + kMonitorFadeFrames, at + 512, kLeftIn, kRightIn) && graph->monitorActive(0));
    engine.params().set(mode, 2.0f);  // auto, unarmed, playing
    at = m.render(512);
    DAW_CHECK(m.all(at + kMonitorFadeFrames, at + 512, kClip, kClip) && !graph->monitorActive(0));
    DAW_CHECK(m.violations == 0);
    return checks;
}

// MARK: End to end through the facade and the fake device's loopback

namespace {

constexpr uint32_t kLoopback = 4096;
constexpr size_t kCaptureFrames = size_t{1} << 21;

// The fake device's tap: output channel 0 by device frame (preallocated, RT-safe).
struct Capture {
    std::vector<float> out = std::vector<float>(kCaptureFrames, 0.0f);
};

void captureTap(void* context, const FakeCycle& cycle) DAW_RT {
    auto* capture = static_cast<Capture*>(context);
    if (cycle.outputChannels == 0) return;
    for (uint32_t i = 0; i < cycle.numFrames; ++i) {
        const uint64_t at = cycle.startFrame + i;
        if (at < kCaptureFrames) capture->out[at] = cycle.output[0][i];
    }
}

float peak(const std::vector<float>& x, uint64_t from, uint64_t to) {
    float p = 0;
    for (uint64_t i = from; i < to && i < x.size(); ++i) p = std::max(p, std::abs(x[i]));
    return p;
}

} // namespace

CheckResult facadeMonitorsThroughLoopback() {
    CheckResult checks;
    Capture capture;
    FakeDeviceSpec spec;
    FakeDevice device;
    device.id = 1;
    device.name = "Loopback";
    device.outputLatency = LatencyComponents{37, 11, 5, 0};  // + buffer 256 = 309
    device.inputLatency = LatencyComponents{23, 7, 0, 0};    // + buffer 256 = 286
    spec.devices = {device};
    spec.pacing = FakePacing::asFastAsPossible;
    spec.cycleLimit = 0;
    spec.loopbackDelay = kLoopback;
    spec.tap = captureTap;
    spec.tapContext = &capture;

    auto owned = std::make_unique<FakeDeviceDriverAdapter>(std::move(spec));
    FakeDeviceDriverAdapter* adapter = owned.get();
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

    // master ← metronome (a click per beat); master ← gain 0.25 ← monitored player 20 (no clips).
    const ParamID click = facade.allocateParams(Metronome::kNumParams);
    facade.setParam(click + Metronome::kOn, 1.0f);
    facade.setParam(click + Metronome::kLevel, 0.5f);
    facade.setParam(click + Metronome::kAccent, 1.0f);
    const ParamID gain = facade.allocateParams(GainNode::kNumParams);
    facade.setParam(gain + GainNode::kLevel, 0.25f);
    facade.setParam(gain + GainNode::kMute, 0.0f);
    const ParamID mode = facade.allocateParams(1);
    facade.setParam(mode, 0.0f);  // off
    const auto describe = [&](bool armed) {
        GraphDescriptionBuilder b;
        b.addNode(1, NodeKind::master, 1, 0, 0, "");
        b.addNode(10, NodeKind::metronome, 1, click, Metronome::kNumParams, "");
        b.addNode(20, NodeKind::audioClipPlayer, 1, 0, 0, "");
        b.addNode(21, NodeKind::gain, 1, gain, GainNode::kNumParams, "");
        b.addEdge(1, 10, 1, EdgeKind::audio, 0);
        b.addEdge(2, 20, 21, EdgeKind::audio, 0);
        b.addEdge(3, 21, 1, EdgeKind::audio, 0);
        b.addMonitor(20, mode, 0, armed);
        b.setTempo(0, 120.0);
        b.setTimeSignature(0, 4, 4);
        b.setMaster(1);
        return b.description();
    };
    uint64_t version = facade.applyGraph(describe(false));
    DAW_CHECK(facade.waitForGraph(version, 5000).publishedVersion == version);

    // Nothing armed: no input until setMonitorInput (DW-067 extension), which restarts the device.
    TelemetryPOD t = facade.telemetry();
    DAW_CHECK(t.deviceRunning && !t.monitorInput && t.deviceInputLatency == 0);
    facade.setMonitorInput(true);
    t = facade.telemetry();
    DAW_CHECK(t.monitorInput && t.deviceInputLatency == 286 && t.armedTracks == 0);
    // REC-021: input + output latency + graph latency (no PDC here).
    DAW_CHECK(t.monitoringLatency == 286 + 309 + t.graphLatency);
    DAW_CHECK(t.graphLatency == 0);

    FakeDeviceDriver* driver = adapter->driver();
    DAW_CHECK(driver != nullptr);
    if (!driver) return checks;
    // Plays 120 cycles from tick 0; returns the device frame the run started at. The click goes
    // out at that frame and comes back as input kLoopback frames later.
    const auto run = [&](bool recording) -> uint64_t {
        facade.stop();
        facade.locate(0);
        facade.setRecording(recording);
        facade.play();
        const uint64_t start = driver->frames();
        driver->setCycleLimit(driver->cycles() + 120);
        DAW_CHECK(driver->waitUntilIdle(10000ms));
        DAW_CHECK(facade.transport().playing);
        return start;
    };
    // The click's echo through the monitored track, relative to the click itself.
    const auto echo = [&](uint64_t start) {
        const float clickPeak = peak(capture.out, start, start + 960);
        const float echoPeak = peak(capture.out, start + kLoopback, start + kLoopback + 960);
        return std::pair{clickPeak, echoPeak};
    };
    // REC-022: a mode change is a slot write, no new graph.
    const auto setMode = [&](float value) {
        const uint64_t published = facade.graphStatus().publishedVersion;
        facade.setParam(mode, value);
        DAW_CHECK(facade.graphStatus().publishedVersion == published && facade.graphStatus().submittedVersion == published);
    };

    auto [c0, e0] = echo(run(false));  // off
    DAW_CHECK(c0 > 0.1f);
    DAW_CHECK(e0 < kEps);
    setMode(1.0f);  // on
    auto [c1, e1] = echo(run(false));
    DAW_CHECK(c1 > 0.1f);
    DAW_CHECK(e1 > 0.2f * c1 && e1 < 0.3f * c1);  // the gain node's 0.25
    setMode(2.0f);  // auto, unarmed
    auto [c2, e2] = echo(run(true));
    DAW_CHECK(c2 > 0.1f && e2 < kEps);

    // Arming is structural: a new description (REC-022).
    version = facade.applyGraph(describe(true));
    DAW_CHECK(facade.waitForGraph(version, 5000).publishedVersion == version);
    auto [c3, e3] = echo(run(false));  // auto, armed, playing: off
    DAW_CHECK(c3 > 0.1f && e3 < kEps);
    auto [c4, e4] = echo(run(true));  // auto, armed, recording: on
    DAW_CHECK(c4 > 0.1f && e4 > 0.2f * c4 && e4 < 0.3f * c4);
    facade.stop();
    facade.setRecording(false);

    facade.setMonitorInput(false);
    t = facade.telemetry();
    DAW_CHECK(!t.monitorInput && t.deviceInputLatency == 0 && t.deviceRunning);
    DAW_CHECK(driver->rtViolations() + t.rtViolations == 0);
    return checks;
}

} // namespace daw::testing
