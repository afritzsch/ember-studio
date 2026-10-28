// T-050 checks for FakeDeviceDriver (TEST-005). Run from
// Tests/DAWEngineTests/FakeDeviceDriverTests.swift; see FakeDeviceChecks.h for why they're C++.

#include "FakeDeviceChecks.h"
#include "RtTrapTestSupport.h"

#include <atomic>
#include <chrono>
#include <memory>
#include <thread>
#include <utility>
#include <vector>

#include "core/AudioBufferPool.h"
#include "core/Engine.h"
#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ProcessContext.h"
#include "core/RenderGraph.h"
#include "core/RtTrap.h"
#include "daw/EngineFacade.h"
#include "facade/DriverAdapter.h"
#include "facade/FacadeOptions.h"
#include "io/DeviceNotification.h"
#include "io/DeviceRenderer.h"
#include "io/FakeDeviceDriver.h"

using namespace std::chrono_literals;

namespace daw::testing {

namespace {

constexpr double kRate = 48000.0;

// Channel c of frame n is n + c / 2 (n counted from the node's first block): gaps, repeats and
// channel swaps all show. Exact in float for the few seconds these checks render.
class CounterSource final : public Node {
public:
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        if (ctx.numFrames > maxFrames.load(std::memory_order_relaxed))
            maxFrames.store(ctx.numFrames, std::memory_order_relaxed);
        for (uint32_t c = 0; c < io.audioOut.numChannels; ++c)
            for (uint32_t f = 0; f < ctx.numFrames; ++f)
                io.audioOut.channels[c][f] = static_cast<float>(next_ + f) + 0.5f * static_cast<float>(c);
        next_ += ctx.numFrames;
    }
    std::atomic<uint32_t> maxFrames{0};  // the largest block Engine::render asked for

private:
    uint64_t next_ = 0;
};

// Publishes a CounterSource → master (stereo) at kRate; returns the node (owned by the engine).
CounterSource* publishCounter(Engine& engine, uint32_t maxBlock = kMaxBlock) {
    auto source = std::make_unique<CounterSource>();
    CounterSource* raw = source.get();
    const PrepareInfo info{kRate, maxBlock, 2, 2};
    RenderGraphDesc desc;
    desc.sampleRate = kRate;
    desc.maxBlock = maxBlock;
    desc.buffers = std::move(AudioBufferPool::create(1, 2, maxBlock)).value();
    auto node = engine.nodes().put(1, std::move(source), info);
    if (!node) return nullptr;
    RenderStepDesc step;
    step.node = std::move(node).value();
    step.output = 0;
    desc.steps.push_back(std::move(step));
    desc.master = 0;
    auto graph = RenderGraph::create(std::move(desc));
    if (!graph) return nullptr;
    engine.publish(std::move(graph).value());
    return raw;
}

// Checks every cycle on the render thread (DAW_RT, inside the cycle's RtScope): the output is
// the counter, contiguous across cycles (and runs); the input is the output `delay` frames
// earlier (loopback), or silence when `delay` is 0.
struct CycleChecker {
    uint32_t delay = 0;
    uint64_t runStart = 0;  // driver frame at which the current run started (loopback positions)
    std::atomic<uint64_t> cycles{0};
    std::atomic<uint64_t> frames{0};
    std::atomic<uint64_t> outputErrors{0};
    std::atomic<uint64_t> inputErrors{0};
    std::atomic<uint64_t> inputSamples{0};
    std::atomic<uint64_t> nextFrame{0};
    std::atomic<uint32_t> inputChannels{0};

    static void tap(void* context, const FakeCycle& cycle) DAW_RT {
        auto& self = *static_cast<CycleChecker*>(context);
        if (cycle.startFrame != self.nextFrame.load(std::memory_order_relaxed))
            self.outputErrors.fetch_add(1, std::memory_order_relaxed);
        uint64_t outErrors = 0, inErrors = 0;
        for (uint32_t c = 0; c < cycle.outputChannels; ++c)
            for (uint32_t f = 0; f < cycle.numFrames; ++f)
                if (cycle.output[c][f] != static_cast<float>(cycle.startFrame + f) + 0.5f * static_cast<float>(c))
                    ++outErrors;
        for (uint32_t c = 0; c < cycle.inputChannels; ++c)
            for (uint32_t f = 0; f < cycle.numFrames; ++f) {
                const uint64_t frame = cycle.startFrame + f;
                const uint64_t inRun = frame - self.runStart;
                float expected = 0.0f;
                if (self.delay != 0 && c < cycle.outputChannels && inRun >= self.delay)
                    expected = static_cast<float>(frame - self.delay) + 0.5f * static_cast<float>(c);
                if (cycle.input[c][f] != expected) ++inErrors;
            }
        self.outputErrors.fetch_add(outErrors, std::memory_order_relaxed);
        self.inputErrors.fetch_add(inErrors, std::memory_order_relaxed);
        self.inputSamples.fetch_add(uint64_t{cycle.inputChannels} * cycle.numFrames, std::memory_order_relaxed);
        self.inputChannels.store(cycle.inputChannels, std::memory_order_relaxed);
        self.nextFrame.store(cycle.startFrame + cycle.numFrames, std::memory_order_relaxed);
        self.frames.fetch_add(cycle.numFrames, std::memory_order_relaxed);
        self.cycles.fetch_add(1, std::memory_order_relaxed);
    }
};

FakeDeviceSpec fastSpec(CycleChecker* checker = nullptr) {
    FakeDeviceSpec spec;
    spec.pacing = FakePacing::asFastAsPossible;
    spec.cycleLimit = 0;
    if (checker) {
        spec.tap = &CycleChecker::tap;
        spec.tapContext = checker;
    }
    return spec;
}

DriverConfig config48k(uint32_t buffer = 256) {
    DriverConfig config;
    config.sampleRate = kRate;
    config.bufferFrames = buffer;
    return config;
}

std::vector<DeviceNotification> drain(FakeDeviceDriver& driver) {
    std::vector<DeviceNotification> out(FakeDeviceDriver::kNotificationCapacity);
    out.resize(driver.pollNotifications(out.data(), out.size()));
    return out;
}

bool is(const DeviceNotification& n, DeviceNotificationType type, AudioDeviceRef device, uint64_t frame) {
    return n.type == type && n.device == device && n.frame == frame;
}

} // namespace

CheckResult fakeDeviceRunsCycles() {
    CheckResult checks;
    Engine engine;
    CounterSource* source = publishCounter(engine);
    DAW_CHECK(source != nullptr);
    if (!source) return checks;
    CycleChecker checker;
    FakeDeviceSpec spec = fastSpec(&checker);
    spec.devices[0].outputLatency = {12, 24, 6, 0};  // device, safety offset, stream
    spec.devices[0].inputLatency = {7, 0, 0, 0};
    spec.cycleFrames = {256, 512, 100, 1000};  // DeviceRenderer splits 512 and 1000 into ≤ 256
    FakeDeviceDriver driver(engine, spec);

    DAW_CHECK(!driver.running() && driver.latency().output == 0);
    DAW_CHECK(driver.start(config48k()).ok());
    DAW_CHECK(driver.running());
    DAW_CHECK(!driver.start(config48k()).ok());  // already running
    DAW_CHECK(driver.current().sampleRate == kRate && driver.current().bufferFrames == 256);
    DAW_CHECK(driver.current().outputDevice == 1 && driver.current().inputDevice == 0);

    // IO-005: configured components + the buffer, published like CoreAudioDriver does.
    DAW_CHECK(driver.latency().output == 12 + 24 + 6 + 256);
    DAW_CHECK(driver.latency().input == 0);  // input not enabled
    DAW_CHECK(engine.telemetry().snapshot().deviceOutputLatency == 298);
    DAW_CHECK(engine.transport().outputLatency() == 298);

    // Limit 0: parked, Engine::render never called.
    DAW_CHECK(driver.waitUntilIdle());
    DAW_CHECK(driver.cycles() == 0 && engine.blocksRendered() == 0);

    driver.setCycleLimit(8);  // two rounds of the pattern: 2 × 1868 frames
    DAW_CHECK(driver.waitUntilIdle());
    DAW_CHECK(driver.cycles() == 8 && driver.frames() == 2 * 1868);
    DAW_CHECK(checker.cycles.load() == 8 && checker.frames.load() == 2 * 1868);
    DAW_CHECK(engine.blocksRendered() == 2 * (1 + 2 + 1 + 4));
    DAW_CHECK(source->maxFrames.load() == 256);
    DAW_CHECK(driver.renderer().largestCycle() == 1000);
    DAW_CHECK(checker.outputErrors.load() == 0);
    DAW_CHECK(checker.inputSamples.load() == 0);

    // Stays parked: nothing more renders until the limit is raised.
    std::this_thread::sleep_for(5ms);
    DAW_CHECK(driver.cycles() == 8);

    driver.stop();
    DAW_CHECK(!driver.running() && driver.latency().output == 0 && driver.current().bufferFrames == 0);
    driver.stop();  // idempotent
    DAW_CHECK(driver.waitUntilIdle());

    // A restart goes on from where the device stopped (counters and the cycle pattern).
    driver.setCycleLimit(12);
    DAW_CHECK(driver.start(config48k()).ok());
    DAW_CHECK(driver.waitUntilIdle());
    DAW_CHECK(driver.cycles() == 12 && driver.frames() == 3 * 1868);
    DAW_CHECK(checker.outputErrors.load() == 0 && checker.frames.load() == 3 * 1868);

    // Unlimited: runs freely until stopped.
    driver.setCycleLimit(FakeDeviceDriver::kUnlimited);
    const auto deadline = std::chrono::steady_clock::now() + 5s;
    while (driver.cycles() < 1000 && std::chrono::steady_clock::now() < deadline) std::this_thread::sleep_for(1ms);
    driver.stop();
    DAW_CHECK(driver.cycles() >= 1000);
    const uint64_t stoppedAt = driver.cycles();
    std::this_thread::sleep_for(2ms);
    DAW_CHECK(driver.cycles() == stoppedAt);  // stop() returned after the last Engine::render
    DAW_CHECK(checker.outputErrors.load() == 0);

    DAW_CHECK(driver.rtViolations() == 0);
    DAW_CHECK(engine.telemetry().snapshot().rtViolations == 0);
    return checks;
}

CheckResult fakeDevicePacesRealtime() {
    CheckResult checks;
    Engine engine;
    DAW_CHECK(publishCounter(engine) != nullptr);
    FakeDeviceSpec spec;
    spec.pacing = FakePacing::realtime;
    spec.cycleLimit = 0;
    FakeDeviceDriver paced(engine, spec);
    DAW_CHECK(paced.start(config48k()).ok());
    DAW_CHECK(paced.waitUntilIdle());

    // 20 cycles of 256 at 48k: the first right away, then one per 5.33 ms. sleep_until never
    // wakes early, so the lower bound is exact; the upper one only catches "never paced back".
    constexpr uint64_t kCycles = 20;
    const auto begin = std::chrono::steady_clock::now();
    paced.setCycleLimit(kCycles);
    DAW_CHECK(paced.waitUntilIdle());
    const auto elapsed = std::chrono::steady_clock::now() - begin;
    DAW_CHECK(paced.cycles() == kCycles);
    DAW_CHECK(elapsed >= std::chrono::duration<double>((kCycles - 1) * 256 / kRate));
    DAW_CHECK(elapsed < 2s);
    paced.stop();
    DAW_CHECK(paced.rtViolations() == 0);

    // As fast as possible: 10.7 s of audio in far less.
    FakeDeviceDriver fast(engine, fastSpec());
    DAW_CHECK(fast.start(config48k()).ok());
    const auto fastBegin = std::chrono::steady_clock::now();
    fast.setCycleLimit(2000);
    DAW_CHECK(fast.waitUntilIdle(10000ms));
    DAW_CHECK(fast.cycles() == 2000);
    DAW_CHECK(std::chrono::steady_clock::now() - fastBegin < 3s);
    fast.stop();
    DAW_CHECK(fast.rtViolations() == 0);
    DAW_CHECK(engine.telemetry().snapshot().rtViolations == 0);
    return checks;
}

CheckResult fakeDeviceLoopback() {
    CheckResult checks;
    {
        // Explicit delay, uneven cycles, more input channels than output: input 0/1 are output
        // 0/1 300 frames earlier, input 2 is silent.
        Engine engine;
        DAW_CHECK(publishCounter(engine) != nullptr);
        CycleChecker checker;
        checker.delay = 300;
        FakeDeviceSpec spec = fastSpec(&checker);
        spec.devices[0].input.channels = 3;
        spec.cycleFrames = {256, 100, 37, 300};
        spec.loopbackDelay = 300;
        FakeDeviceDriver driver(engine, spec);
        DriverConfig config = config48k();
        config.inputEnabled = true;
        config.inputChannels = 3;
        DAW_CHECK(driver.start(config).ok());
        DAW_CHECK(driver.current().inputDevice == 1 && driver.current().inputChannels == 3);
        driver.setCycleLimit(40);
        DAW_CHECK(driver.waitUntilIdle());
        DAW_CHECK(checker.cycles.load() == 40 && checker.inputChannels.load() == 3);
        DAW_CHECK(checker.inputSamples.load() == 3 * driver.frames());
        DAW_CHECK(checker.inputErrors.load() == 0 && checker.outputErrors.load() == 0);
        DAW_CHECK(driver.latency().input == 256 && driver.latency().output == 256);

        // A new run starts the loopback afresh (silence for the first `delay` frames).
        driver.stop();
        checker.runStart = driver.frames();
        driver.setCycleLimit(80);
        DAW_CHECK(driver.start(config).ok());
        DAW_CHECK(driver.waitUntilIdle());
        DAW_CHECK(checker.cycles.load() == 80 && checker.inputErrors.load() == 0);
        driver.stop();
        DAW_CHECK(driver.rtViolations() == 0);
        DAW_CHECK(engine.telemetry().snapshot().rtViolations == 0);
    }
    {
        // Default delay: input latency + output latency, as a cable would measure it.
        Engine engine;
        DAW_CHECK(publishCounter(engine) != nullptr);
        CycleChecker checker;
        FakeDeviceSpec spec = fastSpec(&checker);
        spec.devices[0].outputLatency = {40, 16, 0, 0};
        spec.devices[0].inputLatency = {30, 8, 2, 0};
        checker.delay = (40 + 16 + 128) + (30 + 8 + 2 + 128);
        FakeDeviceDriver driver(engine, spec);
        DriverConfig config = config48k(128);
        config.inputEnabled = true;
        DAW_CHECK(driver.start(config).ok());
        DAW_CHECK(driver.latency().input + driver.latency().output == checker.delay);
        driver.setCycleLimit(30);
        DAW_CHECK(driver.waitUntilIdle());
        DAW_CHECK(checker.inputSamples.load() == 2 * 30 * 128);
        DAW_CHECK(checker.inputErrors.load() == 0 && checker.outputErrors.load() == 0);
        driver.stop();
        DAW_CHECK(driver.rtViolations() == 0);
    }
    {
        // Loopback off: silent input. Input not enabled: no input channels at all.
        Engine engine;
        DAW_CHECK(publishCounter(engine) != nullptr);
        CycleChecker checker;  // delay 0: expects silence
        FakeDeviceSpec spec = fastSpec(&checker);
        spec.loopback = false;
        FakeDeviceDriver driver(engine, spec);
        DriverConfig config = config48k();
        config.inputEnabled = true;
        DAW_CHECK(driver.start(config).ok());
        driver.setCycleLimit(10);
        DAW_CHECK(driver.waitUntilIdle());
        DAW_CHECK(checker.inputSamples.load() == 2 * 10 * 256 && checker.inputErrors.load() == 0);
        driver.stop();
        config.inputEnabled = false;
        DAW_CHECK(driver.start(config).ok());
        driver.setCycleLimit(20);
        DAW_CHECK(driver.waitUntilIdle());
        DAW_CHECK(checker.inputChannels.load() == 0 && driver.current().inputChannels == 0);
        DAW_CHECK(driver.latency().input == 0);
        driver.stop();
        DAW_CHECK(driver.rtViolations() == 0);
    }
    {
        // A frame can't come back before it has been rendered.
        Engine engine;
        FakeDeviceSpec spec = fastSpec();
        spec.loopbackDelay = 255;
        FakeDeviceDriver driver(engine, spec);
        DriverConfig config = config48k();
        config.inputEnabled = true;
        auto started = driver.start(config);
        DAW_CHECK(!started.ok() && started.error().code == ErrorCode::invalidArgument);
        DAW_CHECK(!driver.running());
        config.inputEnabled = false;  // no input, no loopback to check
        DAW_CHECK(driver.start(config).ok());
        driver.stop();
    }
    return checks;
}

CheckResult fakeDeviceScriptedEvents() {
    CheckResult checks;
    Engine engine;
    DAW_CHECK(publishCounter(engine) != nullptr);
    FakeDeviceSpec spec = fastSpec();
    spec.cycleLimit = FakeDeviceDriver::kUnlimited;  // the loss stops it
    FakeDevice b;
    b.id = 2;
    b.name = "Fake Output B";
    b.input.channels = 0;  // output only
    spec.devices.push_back(b);
    spec.script = {
        {2560, FakeDeviceEventType::sampleRateChanged, 1, 44100.0},
        {5120, FakeDeviceEventType::processorOverload, 0, 0},
        {7680, FakeDeviceEventType::deviceLost, 0, 0},
    };
    FakeDeviceDriver driver(engine, spec);
    DAW_CHECK(driver.defaultOutput() == 1);

    DriverConfig config;
    config.sampleRate = 0;  // the nominal rate
    DAW_CHECK(driver.start(config).ok());
    DAW_CHECK(driver.current().sampleRate == 48000.0);
    DAW_CHECK(driver.waitUntilIdle());

    // The loss came before the cycle at 7680: nothing rendered after it, but still "running".
    DAW_CHECK(driver.frames() == 7680 && driver.cycles() == 30);
    DAW_CHECK(driver.running());
    std::this_thread::sleep_for(2ms);
    DAW_CHECK(driver.frames() == 7680);

    auto n = drain(driver);
    DAW_CHECK(n.size() == 5);
    if (n.size() == 5) {
        DAW_CHECK(is(n[0], DeviceNotificationType::nominalRateChanged, 1, 2560) && n[0].sampleRate == 44100.0);
        DAW_CHECK(is(n[1], DeviceNotificationType::processorOverload, 1, 5120));
        DAW_CHECK(is(n[2], DeviceNotificationType::aliveChanged, 1, 7680) && !n[2].alive);
        DAW_CHECK(is(n[3], DeviceNotificationType::devicesChanged, 1, 7680));
        DAW_CHECK(is(n[4], DeviceNotificationType::defaultOutputChanged, 2, 7680));
    }
    DAW_CHECK(engine.telemetry().snapshot().xruns == 1);  // IO-023: the overload counted
    DAW_CHECK(driver.defaultOutput() == 2);
    auto devices = driver.devices();
    DAW_CHECK(devices.size() == 2 && !devices[0].alive && devices[0].nominalRate == 44100.0 && devices[1].alive);
    DAW_CHECK(driver.droppedNotifications() == 0);

    // The lost device can't start; the new default can (output only, so no input).
    driver.stop();
    config.outputDevice = 1;
    auto lost = driver.start(config);
    DAW_CHECK(!lost.ok() && lost.error().code == ErrorCode::notFound);
    config.outputDevice = 0;
    config.inputEnabled = true;
    // The limit is still kUnlimited, so cap the run before start(): set afterwards, a free-running
    // thread can overshoot it before the store lands (it did under load).
    driver.setCycleLimit(driver.cycles() + 10);
    DAW_CHECK(driver.start(config).ok());
    DAW_CHECK(driver.current().outputDevice == 2 && driver.current().inputChannels == 0);
    DAW_CHECK(driver.waitUntilIdle());
    DAW_CHECK(driver.frames() == 7680 + 2560);

    // Injected while running: applied before the next cycle, synchronously.
    DAW_CHECK(driver.inject({0, FakeDeviceEventType::deviceRestored, 1, 0}).ok());
    DAW_CHECK(driver.inject({0, FakeDeviceEventType::sampleRateChanged, 0, 96000.0}).ok());  // B
    n = drain(driver);
    DAW_CHECK(n.size() == 3);
    if (n.size() == 3) {
        DAW_CHECK(is(n[0], DeviceNotificationType::aliveChanged, 1, 10240) && n[0].alive);
        DAW_CHECK(is(n[1], DeviceNotificationType::devicesChanged, 1, 10240));
        DAW_CHECK(is(n[2], DeviceNotificationType::nominalRateChanged, 2, 10240) && n[2].sampleRate == 96000.0);
    }
    DAW_CHECK(driver.defaultOutput() == 2);  // a restored device doesn't take the default back
    DAW_CHECK(driver.devices()[1].nominalRate == 96000.0);
    // Repeating a state is no change, so no notification.
    DAW_CHECK(driver.inject({0, FakeDeviceEventType::deviceRestored, 1, 0}).ok());
    DAW_CHECK(drain(driver).empty());

    auto unknown = driver.inject({0, FakeDeviceEventType::deviceLost, 9, 0});
    DAW_CHECK(!unknown.ok() && unknown.error().code == ErrorCode::invalidArgument);
    auto badRate = driver.inject({0, FakeDeviceEventType::sampleRateChanged, 1, 22050.0});
    DAW_CHECK(!badRate.ok() && badRate.error().code == ErrorCode::invalidArgument);

    // The restored device starts at its new nominal rate.
    driver.stop();
    config.outputDevice = 1;
    driver.setCycleLimit(driver.cycles() + 4);  // before start(), as above
    DAW_CHECK(driver.start(config).ok());
    DAW_CHECK(driver.current().sampleRate == 44100.0 && driver.current().inputChannels == 2);
    DAW_CHECK(driver.waitUntilIdle());
    DAW_CHECK(driver.cycles() == 30 + 10 + 4);
    driver.stop();
    DAW_CHECK(driver.rtViolations() == 0);
    DAW_CHECK(engine.telemetry().snapshot().rtViolations == 0);

    // Stopped: injected events apply on the calling thread; a full queue counts what it drops.
    for (int i = 0; i < 300; ++i) DAW_CHECK(driver.inject({0, FakeDeviceEventType::processorOverload, 0, 0}).ok());
    DAW_CHECK(engine.telemetry().snapshot().xruns == 301);
    DAW_CHECK(driver.droppedNotifications() == 300 - FakeDeviceDriver::kNotificationCapacity);
    DAW_CHECK(drain(driver).size() == FakeDeviceDriver::kNotificationCapacity);

    // Bad specs fail start().
    auto rejects = [&](FakeDeviceSpec bad) {
        FakeDeviceDriver d(engine, std::move(bad));
        auto r = d.start(config48k());
        return !r.ok() && r.error().code == ErrorCode::invalidArgument && !d.running();
    };
    FakeDeviceSpec bad = fastSpec();
    bad.devices.push_back(bad.devices[0]);
    DAW_CHECK(rejects(bad));  // duplicate ID
    bad = fastSpec();
    bad.devices.clear();
    DAW_CHECK(rejects(bad));
    bad = fastSpec();
    bad.cycleFrames = {256, 0};
    DAW_CHECK(rejects(bad));
    bad = fastSpec();
    bad.script = {{100, FakeDeviceEventType::processorOverload, 0, 0}, {50, FakeDeviceEventType::deviceLost, 0, 0}};
    DAW_CHECK(rejects(bad));  // out of order
    bad = fastSpec();
    bad.script = {{0, FakeDeviceEventType::deviceLost, 7, 0}};
    DAW_CHECK(rejects(bad));  // unknown device
    bad = fastSpec();
    bad.defaultOutput = 5;
    DAW_CHECK(rejects(bad));
    return checks;
}

CheckResult fakeDeviceDrivesFacade() {
    CheckResult checks;
    FakeDeviceSpec spec = fastSpec();
    spec.devices[0].outputLatency = {10, 5, 3, 0};
    auto adapter = std::make_unique<FakeDeviceDriverAdapter>(spec);
    FakeDeviceDriverAdapter* fake = adapter.get();
    DAW_CHECK(fake->driver() == nullptr && fake->devices().size() == 1);
    FacadeOptions options;
    options.driver = std::move(adapter);
    DriverConfigPOD config;
    config.sampleRate = 0;
    config.bufferFrames = 128;
    EngineFacade* facade = EngineFacadeAccess::create(EngineMode::realtime, config, std::move(options));
    DAW_CHECK(facade != nullptr);
    if (!facade) return checks;
    FakeDeviceDriver* driver = fake->driver();
    DAW_CHECK(driver != nullptr && driver->running());
    if (driver) {
        TelemetryPOD t = facade->telemetry();
        DAW_CHECK(t.deviceRunning && t.sampleRate == 48000.0);
        DAW_CHECK(t.deviceOutputLatency == 10 + 5 + 3 + 128);
        auto devices = facade->devices();
        DAW_CHECK(devices.size() == 1 && devices[0].deviceID == 1 && devices[0].isDefaultOutput);

        GraphDescriptionBuilder b;
        b.addNode(1, NodeKind::master, 1, 0, 0, "");
        b.setTempo(0, 120.0);
        b.setTimeSignature(0, 4, 4);
        b.setMaster(1);
        const uint64_t version = facade->applyGraph(b.description());
        const GraphStatusPOD status = facade->waitForGraph(version, 5000);
        DAW_CHECK(status.publishedVersion == version && status.lastError.ok());

        // The device's own thread applies the transport command and renders the graph.
        facade->play();
        driver->setCycleLimit(driver->cycles() + 50);
        DAW_CHECK(driver->waitUntilIdle());
        DAW_CHECK(facade->transport().playing);
        t = facade->telemetry();
        DAW_CHECK(t.blocksRendered >= 50 && t.graphVersion == version);
        DAW_CHECK(t.rtViolations == 0);

        // setDevice restarts the fake with the new buffer; the counters go on.
        const uint64_t before = driver->cycles();
        config.bufferFrames = 64;
        DAW_CHECK(facade->setDevice(config).ok());
        DAW_CHECK(fake->driver() == driver && driver->running() && driver->current().bufferFrames == 64);
        driver->setCycleLimit(before + 10);
        DAW_CHECK(driver->waitUntilIdle());
        DAW_CHECK(driver->frames() == before * 128 + 10 * 64);

        // A lost device is gone from the facade's list (reacting to it is IO-021, T-051).
        DAW_CHECK(driver->inject({0, FakeDeviceEventType::deviceLost, 0, 0}).ok());
        DAW_CHECK(facade->devices().empty());
        DAW_CHECK(driver->rtViolations() == 0);
        DAW_CHECK(facade->telemetry().rtViolations == 0);
    }
    releaseFacade(facade);  // stops the fake's thread before the engine goes
    return checks;
}

namespace {
// Deliberately not DAW_RT (it allocates), so it is cast to the tap type below.
void allocatingTap(void* context, const FakeCycle&) noexcept {
    static_cast<std::atomic<uint64_t>*>(context)->fetch_add(runProbe(RtProbe::malloc) ? 1 : 0);
}
} // namespace

CheckResult fakeDeviceCountsCycleViolations() {
    CheckResult checks;
    DAW_CHECK(RtTrap::install());
    Engine engine;
    DAW_CHECK(publishCounter(engine) != nullptr);
    std::atomic<uint64_t> probes{0};
    FakeDeviceSpec spec = fastSpec();
    spec.tap = reinterpret_cast<FakeCycleTap>(&allocatingTap);
    spec.tapContext = &probes;
    FakeDeviceDriver driver(engine, spec);
    DAW_CHECK(driver.start(config48k()).ok());
    driver.setCycleLimit(5);
    DAW_CHECK(driver.waitUntilIdle());
    driver.stop();
    DAW_CHECK(probes.load() == 5);
    DAW_CHECK(driver.rtViolations() >= 5);                        // malloc + free, every cycle
    DAW_CHECK(engine.telemetry().snapshot().rtViolations == 0);  // outside Engine::render
    return checks;
}

} // namespace daw::testing
