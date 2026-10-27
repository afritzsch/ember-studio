// T-014 checks for EngineFacade. Run from Tests/DAWEngineTests/FacadeTests.swift; see
// FacadeChecks.h for why they're C++.

#include "FacadeChecks.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "ExportTestSupport.h"
#include "TestAudio.h"
#include "core/Engine.h"
#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ProcessContext.h"
#include "core/RenderTarget.h"
#include "core/RtTrap.h"
#include "daw/EngineFacade.h"
#include "facade/DriverAdapter.h"
#include "facade/FacadeErrors.h"
#include "facade/FacadeOptions.h"
#include "io/DriverConfig.h"
#include "graph/NodeRegistry.h"

using namespace daw;
using namespace std::chrono_literals;

namespace daw::testing {

namespace {

constexpr double kRate = 48000.0;
constexpr uint32_t kBlock = 256;
constexpr uint32_t kWaitMs = 5000;

template <class F>
bool eventually(F done, std::chrono::milliseconds timeout = 5000ms) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (!done()) {
        if (std::chrono::steady_clock::now() > deadline) return false;
        std::this_thread::sleep_for(1ms);
    }
    return true;
}

// MARK: Fake device

// Renders only when the test calls render(), on the test thread, in its own RtScope (DW-019).
class FakeDriver final : public DriverAdapter {
public:
    explicit FakeDriver(double rate = kRate) : rate_(rate), samples_(2 * kBlock) {
        ptrs_[0] = samples_.data();
        ptrs_[1] = samples_.data() + kBlock;
    }

    Result<void> start(Engine& engine, const DriverConfig& config) override {
        std::lock_guard lock(mutex_);
        log_.push_back("start");
        if (failStarts_) return makeError(ErrorCode::io, "fake device unavailable");
        engine_ = &engine;
        config_ = config;
        running_ = true;
        return {};
    }
    void stop() override {
        std::lock_guard lock(mutex_);
        if (running_) log_.push_back("stop");
        running_ = false;
    }
    bool running() const override { return running_; }
    double sampleRate() const override { return rate_; }
    uint32_t bufferFrames() const override { return config().bufferFrames; }
    std::vector<DeviceInfoPOD> devices() const override {
        return {DeviceInfoPOD{42, "Fake Output", 0, 2, rate_, true}};
    }

    // `blocks` blocks of kBlock frames while running. Returns the RT violations they counted.
    uint64_t render(uint32_t blocks) {
        std::lock_guard lock(mutex_);
        if (!running_) return 0;
        RenderTarget target{AudioBufferView{ptrs_, 2, kBlock}, AudioBufferView{}};
        uint64_t violations = 0;
        for (uint32_t b = 0; b < blocks; ++b) {
            RtScope scope;
            engine_->render(target, kBlock);
            violations += scope.violations();
        }
        return violations;
    }
    // Every sample of the last block equals `value`.
    bool lastBlockIs(float value) const {
        for (float s : samples_)
            if (s != value) return false;
        return true;
    }
    std::vector<std::string> log() const {
        std::lock_guard lock(mutex_);
        return log_;
    }
    void failStarts(bool fail) { failStarts_ = fail; }
    DriverConfig config() const {
        std::lock_guard lock(mutex_);
        return config_;
    }

private:
    mutable std::mutex mutex_;
    double rate_;
    Engine* engine_ = nullptr;
    DriverConfig config_;
    std::atomic<bool> running_{false};
    std::atomic<bool> failStarts_{false};
    std::vector<std::string> log_;
    std::vector<float> samples_;
    float* ptrs_[2];
};

// MARK: Test node

// Outputs its first param slot's value on every frame (read once per block, ENG-021).
class ParamSource final : public Node {
public:
    explicit ParamSource(ParamID param) : param_(param) {}
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        const float value = ctx.params.get(param_);
        for (uint32_t c = 0; c < io.audioOut.numChannels; ++c)
            for (uint32_t f = 0; f < io.audioOut.numFrames; ++f) io.audioOut.channels[c][f] = value;
    }

private:
    ParamID param_;
};

struct Harness {
    std::shared_ptr<std::atomic<int>> creates = std::make_shared<std::atomic<int>>(0);
    FakeDriver* driver = nullptr;  // owned by the facade
    EngineFacade* facade = nullptr;

    // Realtime mode with a FakeDriver, or offline mode; NodeKind::gain is a ParamSource.
    explicit Harness(EngineMode mode = EngineMode::realtime, double driverRate = kRate) {
        FacadeOptions options;
        if (mode == EngineMode::realtime) {
            auto fake = std::make_unique<FakeDriver>(driverRate);
            driver = fake.get();
            options.driver = std::move(fake);
        }
        auto creates = this->creates;
        options.registerNodes = [creates](NodeRegistry& registry) {
            return registry.set(NodeKind::gain, {[creates](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> {
                creates->fetch_add(1);
                return std::unique_ptr<Node>(new ParamSource(info.desc.firstParam));
            }});
        };
        DriverConfigPOD config;
        config.sampleRate = mode == EngineMode::offline ? kRate : 0;
        facade = EngineFacadeAccess::create(mode, config, std::move(options));
    }
    ~Harness() {
        if (facade) releaseFacade(facade);
    }
    Harness(const Harness&) = delete;
    Harness& operator=(const Harness&) = delete;
};

// master(1) ← gain(2) reading `param`; edge IDs from 10.
GraphDescription paramGraph(ParamID param, uint32_t configVersion = 1) {
    GraphDescriptionBuilder b;
    b.addNode(1, NodeKind::master, 1, 0, 0, "");
    b.addNode(2, NodeKind::gain, configVersion, param, 1, "");
    b.addEdge(10, 2, 1, EdgeKind::audio, 0);
    b.setTempo(0, 120.0);
    b.setTimeSignature(0, 4, 4);
    b.setMaster(1);
    return b.description();
}

GraphDescription masterOnly() {
    GraphDescriptionBuilder b;
    b.addNode(1, NodeKind::master, 1, 0, 0, "");
    b.setTempo(0, 120.0);
    b.setTimeSignature(0, 4, 4);
    b.setMaster(1);
    return b.description();
}

bool published(EngineFacade& facade, uint64_t version) {
    const GraphStatusPOD s = facade.waitForGraph(version, kWaitMs);
    return s.completedVersion >= version && s.publishedVersion == version && s.lastError.ok();
}

} // namespace

// MARK: Checks

CheckResult facadeParamSweepPublishesNothing() {
    CheckResult checks;
    Harness h;
    DAW_CHECK(h.facade && h.driver && h.driver->running());
    if (!h.facade || !h.driver) return checks;
    EngineFacade& facade = *h.facade;

    const ParamID fader = facade.allocateParams(1);
    DAW_CHECK(fader != kInvalidParamID);
    const uint64_t version = facade.applyGraph(paramGraph(fader));
    DAW_CHECK(version == 1);
    DAW_CHECK(published(facade, version));
    const int createsBefore = h.creates->load();
    const GraphStatusPOD before = facade.graphStatus();

    uint64_t violations = h.driver->render(1);
    bool allReached = true;
    for (int i = 0; i < 1000; ++i) {
        const float value = float(i) / 1000.0f;
        facade.setParam(fader, value);  // ENG-023: slot write only
        violations += h.driver->render(1);
        allReached = allReached && h.driver->lastBlockIs(value) && facade.getParam(fader) == value;
    }
    DAW_CHECK(allReached);
    DAW_CHECK(violations == 0);

    // 0 publishes: no build was submitted or completed, no node was created, the same graph renders.
    const GraphStatusPOD after = facade.graphStatus();
    DAW_CHECK(after.submittedVersion == before.submittedVersion);
    DAW_CHECK(after.completedVersion == before.completedVersion);
    DAW_CHECK(after.publishedVersion == version);
    DAW_CHECK(h.creates->load() == createsBefore);
    const TelemetryPOD t = facade.telemetry();
    DAW_CHECK(t.graphVersion == version);
    DAW_CHECK(t.rtViolations == 0);

    // Out-of-range IDs are ignored rather than trapping.
    facade.setParam(kInvalidParamID, 1.0f);
    DAW_CHECK(facade.getParam(kInvalidParamID) == 0.0f);
    return checks;
}

CheckResult facadeDeferredParamFree() {
    CheckResult checks;
    {
        // Nothing applied yet: no graph can read the range, so it's free at once.
        Harness h(EngineMode::offline);
        const ParamID p = h.facade->allocateParams(4);
        h.facade->freeParams(p, 4);
        DAW_CHECK(h.facade->telemetry().paramsPendingFree == 0);
        DAW_CHECK(h.facade->allocateParams(4) == p);
    }

    Harness h;
    EngineFacade& facade = *h.facade;
    const ParamID a = facade.allocateParams(4);
    DAW_CHECK(published(facade, facade.applyGraph(paramGraph(a))));
    DAW_CHECK(h.driver->render(2) == 0);

    // The model drops the node: it frees the range, then applies a graph without it.
    facade.freeParams(a, 4);
    DAW_CHECK(facade.telemetry().paramsPendingFree == 4);
    DAW_CHECK(facade.telemetry().paramsAllocated == 4);
    // Still referenced by the rendering graph, so a new allocation must not get it.
    const ParamID b = facade.allocateParams(4);
    DAW_CHECK(b != a);
    facade.freeParams(a, 4);  // a second free of a pending range is ignored
    DAW_CHECK(facade.telemetry().paramsPendingFree == 4);

    const uint64_t v2 = facade.applyGraph(masterOnly());
    DAW_CHECK(published(facade, v2));
    // Published, but the device is running and no block has completed since the swap: a block
    // that began before it may still be reading the old graph.
    DAW_CHECK(facade.telemetry().paramsPendingFree == 4);
    DAW_CHECK(h.driver->render(1) == 0);
    DAW_CHECK(facade.telemetry().paramsPendingFree == 0);
    DAW_CHECK(facade.telemetry().paramsAllocated == 4);  // only b
    DAW_CHECK(facade.allocateParams(4) == a);             // the lowest free run again

    // A free racing an older, still-compiling description that uses the range: that version
    // doesn't count as the replacement, only one applied after the free does.
    const ParamID c = facade.allocateParams(2);
    const uint64_t v3 = facade.applyGraph(paramGraph(c));
    facade.freeParams(c, 2);
    DAW_CHECK(published(facade, v3));
    DAW_CHECK(h.driver->render(3) == 0);
    DAW_CHECK(facade.telemetry().paramsPendingFree == 2);
    h.driver->stop();  // nothing renders now, so the replacement frees at once
    DAW_CHECK(published(facade, facade.applyGraph(masterOnly())));
    DAW_CHECK(facade.telemetry().paramsPendingFree == 0);

    // Invalid ranges are ignored.
    facade.freeParams(60000, 10);
    facade.freeParams(0xFFFF'FFF0u, 100);
    DAW_CHECK(facade.telemetry().paramsPendingFree == 0);
    return checks;
}

CheckResult facadeExportPausesDevice() {
    CheckResult checks;
    TempDir dir;
    Harness h;
    EngineFacade& facade = *h.facade;

    const ParamID level = facade.allocateParams(1);
    facade.setParam(level, 0.25f);
    DAW_CHECK(published(facade, facade.applyGraph(paramGraph(level))));
    DAW_CHECK(h.driver->render(4) == 0);
    facade.setRecording(true);
    DAW_CHECK(h.driver->render(1) == 0);
    DAW_CHECK(facade.transport().recording);

    // Drain earlier events so the export's are easy to find.
    std::vector<EngineEventPOD> events(64);
    (void)facade.pollEvents(events.data(), events.size());

    ExportSpecPOD spec;
    spec.path = (dir.path() / "export.wav").string();
    spec.tailEnabled = false;
    spec.blockSize = 480;
    const Tick bar = 4 * kPPQ;  // 2 s at 120 bpm
    const JobID job = facade.renderOffline(0, bar, spec);
    DAW_CHECK(job != 0);
    JobStatus status;
    DAW_CHECK(eventually([&] {
        status = facade.pollJob(job);
        return status.state == JobState::succeeded || status.state == JobState::failed;
    }, 20000ms));
    DAW_CHECK(status.state == JobState::succeeded);
    if (status.state != JobState::succeeded) checks.fail(status.error.message.c_str(), __FILE__, __LINE__);
    DAW_CHECK(status.kind == JobKind::renderOffline);
    DAW_CHECK(status.progress == 1.0);
    DAW_CHECK(status.render.framesWritten == 96000);
    DAW_CHECK(status.render.rangeFrames == 96000);
    DAW_CHECK(status.render.blocks == 200);
    DAW_CHECK(status.render.sampleRate == kRate);
    DAW_CHECK(status.render.rtViolations == 0);  // IO-013

    // DW-057: the device was paused for the render and restarted after it.
    const std::vector<std::string> log = h.driver->log();
    DAW_CHECK((log == std::vector<std::string>{"start", "stop", "start"}));
    DAW_CHECK(h.driver->running());
    // DW-064: recording was disarmed.
    DAW_CHECK(h.driver->render(1) == 0);
    DAW_CHECK(!facade.transport().recording);

    // The file holds the graph's output: the param value on every sample.
    auto back = readBack(spec.path, kRate);
    DAW_CHECK(back.ok());
    if (back) {
        DAW_CHECK(back->size() == 2 && (*back)[0].size() == 96000);
        bool level025 = true;
        for (const auto& channel : *back)
            for (float s : channel) level025 = level025 && s == 0.25f;
        DAW_CHECK(level025);
    }

    const size_t n = facade.pollEvents(events.data(), events.size());
    bool finished = false;
    for (size_t i = 0; i < n; ++i)
        finished = finished || (events[i].type == EngineEventType::jobFinished && events[i].job == job &&
                                events[i].error.ok());
    DAW_CHECK(finished);

    // DW-056: a block above the graph's maxBlock fails up front, with the device untouched.
    spec.blockSize = kMaxBlock + 1;
    const JobID tooBig = facade.renderOffline(0, bar, spec);
    DAW_CHECK(facade.pollJob(tooBig).state == JobState::failed);
    DAW_CHECK(facade.pollJob(tooBig).error.code == FacadeErrorCode::invalidArgument);
    DAW_CHECK(h.driver->log().size() == 3);

    // Unknown jobs.
    DAW_CHECK(facade.pollJob(9999).state == JobState::unknown);
    return checks;
}

CheckResult facadeErrorMapping() {
    CheckResult checks;
    {
        const FacadeError e = toFacadeError(makeCycleError({3, 7, 9}));
        DAW_CHECK(e.code == FacadeErrorCode::cycle);
        DAW_CHECK((e.cycle == std::vector<NodeID>{3, 7, 9}));
        DAW_CHECK(e.message == "cycle: 3, 7, 9");
    }
    // Only the code makes a cycle, not a message that looks like one.
    DAW_CHECK(toFacadeError(makeError(ErrorCode::invalidArgument, "cycle: 1 2")).code ==
              FacadeErrorCode::invalidArgument);
    DAW_CHECK(toFacadeError(makeError(ErrorCode::invalidArgument, "bad")).code == FacadeErrorCode::invalidArgument);
    DAW_CHECK(toFacadeError(makeError(ErrorCode::outOfMemory)).code == FacadeErrorCode::outOfMemory);
    DAW_CHECK(toFacadeError(makeError(ErrorCode::notFound)).code == FacadeErrorCode::notFound);
    DAW_CHECK(toFacadeError(makeError(ErrorCode::unsupported)).code == FacadeErrorCode::unsupported);
    DAW_CHECK(toFacadeError(makeError(ErrorCode::io)).code == FacadeErrorCode::io);
    DAW_CHECK(toFacadeError(makeError(ErrorCode::internal)).code == FacadeErrorCode::internal);
    DAW_CHECK(toFacadeError(makeError(ErrorCode::io)).cycle.empty());

    // Through the facade: bus 2 ⇄ bus 3 → master 1.
    Harness h(EngineMode::offline);
    EngineFacade& facade = *h.facade;
    const uint64_t good = facade.applyGraph(masterOnly());
    DAW_CHECK(published(facade, good));
    GraphDescriptionBuilder b;
    b.addNode(1, NodeKind::master, 1, 0, 0, "");
    b.addNode(2, NodeKind::bus, 1, 0, 0, "");
    b.addNode(3, NodeKind::bus, 1, 0, 0, "");
    b.addEdge(10, 2, 3, EdgeKind::audio, 0);
    b.addEdge(11, 3, 2, EdgeKind::audio, 0);
    b.addEdge(12, 3, 1, EdgeKind::audio, 0);
    b.setTempo(0, 120.0);
    b.setTimeSignature(0, 4, 4);
    b.setMaster(1);
    const uint64_t bad = facade.applyGraph(b.description());
    const GraphStatusPOD s = facade.waitForGraph(bad, kWaitMs);
    DAW_CHECK(s.completedVersion == bad);
    DAW_CHECK(s.publishedVersion == good);  // the current graph stays (MIX-001)
    DAW_CHECK(s.lastError.code == FacadeErrorCode::cycle);
    DAW_CHECK((s.lastError.cycle == std::vector<NodeID>{2, 3}));

    std::vector<EngineEventPOD> events(16);
    const size_t n = facade.pollEvents(events.data(), events.size());
    bool rejected = false;
    for (size_t i = 0; i < n; ++i)
        rejected = rejected || (events[i].type == EngineEventType::graphRejected && events[i].subject == bad &&
                                events[i].error.code == FacadeErrorCode::cycle);
    DAW_CHECK(rejected);
    return checks;
}

CheckResult facadeRealtimeDriverSeam() {
    CheckResult checks;
    {
        Harness h(EngineMode::realtime, 44100.0);
        EngineFacade& facade = *h.facade;
        DAW_CHECK(h.driver->running());
        TelemetryPOD t = facade.telemetry();
        DAW_CHECK(t.deviceRunning);
        DAW_CHECK(t.sampleRate == 44100.0);  // graphs are built at the device's rate
        const auto devices = facade.devices();
        DAW_CHECK(devices.size() == 1 && devices[0].deviceID == 42);

        // Transport commands are applied by the device's blocks, not by the facade.
        DAW_CHECK(published(facade, facade.applyGraph(masterOnly())));
        facade.locate(kPPQ);
        facade.play();
        DAW_CHECK(!facade.transport().playing);
        DAW_CHECK(h.driver->render(1) == 0);
        DAW_CHECK(facade.transport().playing);
        DAW_CHECK(facade.transport().sample >= 22050);  // TIME-009: from the located position on
        facade.stop();
        DAW_CHECK(h.driver->render(1) == 0);
        DAW_CHECK(!facade.transport().playing);

        DriverConfigPOD config;
        config.outputDevice = 42;
        config.bufferFrames = 128;
        config.sampleRate = 0;  // the device's rate
        DAW_CHECK(facade.setDevice(config).ok());
        DAW_CHECK(h.driver->config().bufferFrames == 128 && h.driver->config().outputDevice == 42);
        DAW_CHECK((h.driver->log() == std::vector<std::string>{"start", "stop", "start"}));
        DAW_CHECK(!h.driver->config().inputEnabled);

        // DW-067: arming the first track turns input on by restarting the device; more tracks
        // don't; disarming the last turns it off again.
        facade.armInput(7, 0, true);
        DAW_CHECK(h.driver->config().inputEnabled && h.driver->log().size() == 5);
        facade.armInput(8, 1, true);
        facade.armInput(7, 0, false);
        DAW_CHECK(h.driver->config().inputEnabled && h.driver->log().size() == 5);
        facade.armInput(8, 1, false);
        DAW_CHECK(!h.driver->config().inputEnabled && h.driver->log().size() == 7);
        DAW_CHECK(h.driver->running());
        config.sampleRate = 96000;
        DAW_CHECK(facade.setDevice(config).code == FacadeErrorCode::unsupported);

        h.driver->failStarts(true);
        config.sampleRate = 0;
        DAW_CHECK(facade.setDevice(config).code == FacadeErrorCode::io);
        DAW_CHECK(!facade.telemetry().deviceRunning);
    }
    {
        // A device that fails to start: the engine exists, reports it, and doesn't render.
        FacadeOptions options;
        auto fake = std::make_unique<FakeDriver>();
        fake->failStarts(true);
        options.driver = std::move(fake);
        EngineFacade* facade = EngineFacadeAccess::create(EngineMode::realtime, DriverConfigPOD{}, std::move(options));
        DAW_CHECK(facade != nullptr);
        if (facade) {
            DAW_CHECK(!facade->telemetry().deviceRunning);
            EngineEventPOD event;
            DAW_CHECK(facade->pollEvents(&event, 1) == 1);
            DAW_CHECK(event.type == EngineEventType::deviceChanged && event.error.code == FacadeErrorCode::io);
            releaseFacade(facade);
        }
    }
    {
        // No driver attached.
        EngineFacade* facade = EngineFacadeAccess::create(EngineMode::realtime, DriverConfigPOD{}, FacadeOptions{});
        DAW_CHECK(facade != nullptr);
        if (facade) {
            DAW_CHECK(facade->devices().empty());
            DAW_CHECK(facade->setDevice(DriverConfigPOD{}).code == FacadeErrorCode::unsupported);
            DAW_CHECK(facade->telemetry().sampleRate == 48000.0);
            releaseFacade(facade);
        }
    }
    // Offline mode rejects an unusable session rate.
    DriverConfigPOD bad;
    bad.sampleRate = 10;
    DAW_CHECK(EngineFacade::create(EngineMode::offline, bad) == nullptr);
    return checks;
}

} // namespace daw::testing
