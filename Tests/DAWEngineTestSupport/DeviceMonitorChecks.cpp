// T-051 checks (IO-020..023). Run from Tests/DAWEngineTests/DeviceMonitorTests.swift; see
// DeviceMonitorChecks.h for why they're C++.

#include "DeviceMonitorChecks.h"

#include <atomic>
#include <chrono>
#include <memory>
#include <optional>
#include <thread>
#include <utility>
#include <vector>

#include "core/AudioBufferPool.h"
#include "core/Engine.h"
#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ProcessContext.h"
#include "core/RenderGraph.h"
#include "core/RenderTarget.h"
#include "core/RtTrap.h"
#include "core/Telemetry.h"
#include "io/CoreAudioDevice.h"
#include "io/CoreAudioDeviceListener.h"
#include "io/DeviceMonitor.h"
#include "io/DeviceNotification.h"
#include "io/DeviceRenderer.h"
#include "io/FakeDeviceDriver.h"

using namespace std::chrono_literals;

namespace daw::testing {

namespace {

constexpr double kRate = 48000.0;

// Writes silence; while `spinNanos` is set, busy-waits that long in every block (IO-023's
// deliberately slow node). Spinning, not sleeping: sleeping is a syscall the audio thread can't make.
class SlowSource final : public Node {
public:
    explicit SlowSource(const Telemetry& telemetry) : telemetry_(telemetry) {}
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        for (uint32_t c = 0; c < io.audioOut.numChannels; ++c)
            for (uint32_t f = 0; f < ctx.numFrames; ++f) io.audioOut.channels[c][f] = 0.0f;
        const uint64_t spin = spinNanos.load(std::memory_order_relaxed);
        if (spin == 0) return;
        const uint64_t start = Telemetry::clockTicks();
        while (telemetry_.ticksToNanos(Telemetry::clockTicks() - start) < spin) {
        }
    }
    std::atomic<uint64_t> spinNanos{0};

private:
    const Telemetry& telemetry_;
};

// Publishes a SlowSource → master (stereo); returns the node (owned by the engine).
SlowSource* publishSource(Engine& engine, double rate = kRate) {
    auto source = std::make_unique<SlowSource>(engine.telemetry());
    SlowSource* raw = source.get();
    const PrepareInfo info{rate, kMaxBlock, 2, 2};
    RenderGraphDesc desc;
    desc.sampleRate = rate;
    desc.maxBlock = kMaxBlock;
    desc.buffers = std::move(AudioBufferPool::create(1, 2, kMaxBlock)).value();
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

FakeDevice device(AudioDeviceRef id, std::vector<SampleRateRange> rates = {{44100, 44100}, {48000, 48000}},
                  double nominal = kRate) {
    FakeDevice d;
    d.id = id;
    d.name = id == 1 ? "Fake A" : "Fake B";
    d.output = DeviceCaps{nominal, rates, 32, 2048, 2};
    d.input = DeviceCaps{nominal, rates, 32, 2048, 2};
    return d;
}

// pthread_self only reads the thread register, but isn't annotated nonblocking.
pthread_t currentThread() DAW_RT {
    return reinterpret_cast<pthread_t (*)() DAW_RT>(&pthread_self)();
}

// Remembers the render thread, from inside a cycle (IO-022).
struct ThreadTap {
    std::atomic<pthread_t> renderThread{nullptr};
    static void tap(void* context, const FakeCycle&) DAW_RT {
        static_cast<ThreadTap*>(context)->renderThread.store(currentThread(), std::memory_order_relaxed);
    }
};

enum class Step : uint8_t { stopTransport, finalizeRecordings, stopDriver, changeSessionRate, startDriver, deviceChanged };

// A DeviceMonitorHost over an Engine and a FakeDeviceDriver that records every step and the
// thread it ran on. Each start lets the driver render `cyclesPerStart` cycles.
class RecordingHost final : public DeviceMonitorHost {
public:
    RecordingHost(Engine& engine, FakeDeviceDriver& driver, FakeDeviceSpec spec)
        : engine_(engine), driver_(driver), spec_(std::move(spec)) {}

    bool wanted = true;
    DriverConfig requested;
    double session = kRate;
    std::optional<AudioDeviceRef> defaultOverride;  // for notifications made up by the check
    uint64_t cyclesPerStart = 8;

    std::vector<Step> steps;
    std::vector<pthread_t> threads;
    std::vector<DriverConfig> starts;
    std::vector<double> rateChanges;
    std::vector<DeviceChange> changes;

    bool deviceWanted() const override { return wanted; }
    DriverConfig requestedConfig() const override { return requested; }
    RunningConfig runningConfig() const override { return driver_.running() ? driver_.current() : RunningConfig{}; }
    double sessionRate() const override { return session; }
    bool recording() const override { return engine_.transport().playhead().recording; }

    bool deviceAlive(AudioDeviceRef id) const override {
        for (const FakeDeviceState& d : driver_.devices())
            if (d.id == id) return d.alive;
        return false;
    }
    AudioDeviceRef defaultOutputDevice() const override {
        return defaultOverride ? *defaultOverride : driver_.defaultOutput();
    }
    Result<DeviceCaps> outputCaps(AudioDeviceRef id) const override {
        for (const FakeDevice& d : spec_.devices)
            if (d.id == id) {
                DeviceCaps caps = d.output;
                for (const FakeDeviceState& s : driver_.devices())
                    if (s.id == id) caps.nominalRate = s.nominalRate;
                return caps;
            }
        return makeError(ErrorCode::notFound, "no such fake device");
    }

    void stopTransport() override {
        record(Step::stopTransport);
        (void)engine_.transport().stop();
    }
    void finalizeRecordings() override {
        record(Step::finalizeRecordings);
        (void)engine_.transport().setRecording(false);
    }
    void stopDriver() override {
        record(Step::stopDriver);
        driver_.stop();
    }
    Result<void> changeSessionRate(double rate) override {
        record(Step::changeSessionRate);
        rateChanges.push_back(rate);
        session = rate;
        return {};
    }
    Result<void> startDriver(const DriverConfig& config) override {
        record(Step::startDriver);
        starts.push_back(config);
        requested = config;
        driver_.setCycleLimit(driver_.cycles() + cyclesPerStart);  // before start (FakeDeviceDriver.h)
        // "The default" is what the driver resolves 0 to; a made-up default has to be passed.
        DriverConfig resolved = config;
        if (resolved.outputDevice == 0 && defaultOverride) resolved.outputDevice = *defaultOverride;
        return driver_.start(resolved);
    }
    void deviceChanged(const DeviceChange& change) override {
        record(Step::deviceChanged);
        changes.push_back(change);
    }

    void clear() {
        steps.clear();
        threads.clear();
        starts.clear();
        rateChanges.clear();
        changes.clear();
    }

private:
    void record(Step step) {
        steps.push_back(step);
        threads.push_back(pthread_self());
    }

    Engine& engine_;
    FakeDeviceDriver& driver_;
    const FakeDeviceSpec spec_;
};

// Feeds every queued notification to the monitor; returns how many there were.
std::size_t pump(FakeDeviceDriver& driver, DeviceMonitor& monitor) {
    DeviceNotification n[FakeDeviceDriver::kNotificationCapacity];
    const std::size_t count = driver.pollNotifications(n, std::size(n));
    for (std::size_t i = 0; i < count; ++i) (void)monitor.handle(n[i]);
    return count;
}

DeviceNotification notification(DeviceNotificationType type, AudioDeviceRef device, double rate = 0) {
    DeviceNotification n;
    n.type = type;
    n.device = device;
    n.sampleRate = rate;
    return n;
}

FakeDeviceSpec fastSpec(std::vector<FakeDevice> devices) {
    FakeDeviceSpec spec;
    spec.devices = std::move(devices);
    spec.pacing = FakePacing::asFastAsPossible;
    return spec;
}

DriverConfig config(AudioDeviceRef output, double rate = kRate) {
    DriverConfig c;
    c.outputDevice = output;
    c.sampleRate = rate;
    c.bufferFrames = 256;
    return c;
}

// Starts `host`'s driver with its request and plays until the cycle limit or a scripted loss.
bool startPlaying(Engine& engine, FakeDeviceDriver& driver, RecordingHost& host, uint64_t cycles, bool recording) {
    (void)engine.transport().play();
    if (recording) (void)engine.transport().setRecording(true);
    driver.setCycleLimit(cycles);
    return driver.start(host.requested).ok() && driver.waitUntilIdle();
}

} // namespace

CheckResult deviceMonitorLossFallsBack() {
    CheckResult checks;
    Engine engine;
    DAW_CHECK(publishSource(engine) != nullptr);
    ThreadTap tap;
    FakeDeviceSpec spec = fastSpec({device(1), device(2)});
    spec.script = {{2560, FakeDeviceEventType::deviceLost, 1, 0}};
    spec.tap = &ThreadTap::tap;
    spec.tapContext = &tap;
    FakeDeviceDriver driver(engine, spec);
    RecordingHost host(engine, driver, spec);
    host.requested = config(1);  // chosen explicitly
    DeviceMonitor monitor(host);

    DAW_CHECK(startPlaying(engine, driver, host, 20, true));
    DAW_CHECK(driver.frames() == 2560);  // lost before the 11th cycle
    DAW_CHECK(engine.transport().playhead().playing && engine.transport().playhead().recording);

    // aliveChanged, devicesChanged, defaultOutputChanged(2): one sequence.
    DAW_CHECK(pump(driver, monitor) == 3);
    const std::vector<Step> expected{Step::stopTransport, Step::finalizeRecordings, Step::stopDriver,
                                     Step::startDriver, Step::deviceChanged};
    DAW_CHECK(host.steps == expected);
    DAW_CHECK(monitor.swaps() == 1);
    DAW_CHECK(host.starts.size() == 1);
    if (host.starts.size() == 1) {
        // (4) the request falls back to "the default"; the session rate stays.
        DAW_CHECK(host.starts[0].outputDevice == 0 && host.starts[0].sampleRate == kRate);
    }
    DAW_CHECK(host.changes.size() == 1);
    if (host.changes.size() == 1) {
        const DeviceChange& c = host.changes[0];
        DAW_CHECK(c.reason == DeviceChangeReason::deviceLost && !c.error);
        DAW_CHECK(c.previousDevice == 1 && c.device == 2);
        DAW_CHECK(c.previousSessionRate == kRate && c.sessionRate == kRate);
    }
    DAW_CHECK(host.requested.outputDevice == 0);

    // The fallback renders; the transport commands applied on its first block.
    DAW_CHECK(driver.waitUntilIdle());
    DAW_CHECK(driver.running() && driver.current().outputDevice == 2 && driver.current().sampleRate == kRate);
    DAW_CHECK(driver.frames() == 2560 + 8 * 256);
    DAW_CHECK(!engine.transport().playhead().playing && !engine.transport().playhead().recording);

    // IO-022: every step ran on this thread, not on the render thread.
    const pthread_t renderThread = tap.renderThread.load();
    DAW_CHECK(renderThread != nullptr && !pthread_equal(renderThread, pthread_self()));
    for (pthread_t t : host.threads) DAW_CHECK(pthread_equal(t, pthread_self()));

    driver.stop();
    DAW_CHECK(driver.rtViolations() == 0);
    DAW_CHECK(engine.telemetry().snapshot().rtViolations == 0);
    return checks;
}

CheckResult deviceMonitorRateChangeKeepsSessionRate() {
    CheckResult checks;
    Engine engine;
    DAW_CHECK(publishSource(engine) != nullptr);
    FakeDeviceSpec spec = fastSpec({device(1), device(2)});
    spec.script = {{2560, FakeDeviceEventType::sampleRateChanged, 1, 44100.0}};
    FakeDeviceDriver driver(engine, spec);
    RecordingHost host(engine, driver, spec);
    host.requested = config(0, 0);  // the default, at its nominal rate
    DeviceMonitor monitor(host);

    DAW_CHECK(startPlaying(engine, driver, host, 20, false));
    DAW_CHECK(driver.current().sampleRate == kRate && driver.frames() == 20 * 256);

    DAW_CHECK(pump(driver, monitor) == 1);
    const std::vector<Step> expected{Step::stopTransport, Step::stopDriver, Step::startDriver, Step::deviceChanged};
    DAW_CHECK(host.steps == expected);  // not recording: no finalize; no session rate change
    DAW_CHECK(host.rateChanges.empty());
    DAW_CHECK(host.starts.size() == 1 && host.starts[0].outputDevice == 0 && host.starts[0].sampleRate == kRate);
    DAW_CHECK(host.changes.size() == 1);
    if (host.changes.size() == 1) {
        const DeviceChange& c = host.changes[0];
        DAW_CHECK(c.reason == DeviceChangeReason::sampleRateChanged && !c.error);
        DAW_CHECK(c.previousDevice == 1 && c.device == 1 && c.sessionRate == kRate);
    }
    DAW_CHECK(driver.waitUntilIdle());
    DAW_CHECK(driver.current().outputDevice == 1 && driver.current().sampleRate == kRate);

    // The rate the driver runs at is no change.
    DAW_CHECK(!monitor.handle(notification(DeviceNotificationType::nominalRateChanged, 1, kRate)));
    driver.stop();
    DAW_CHECK(driver.rtViolations() == 0);
    DAW_CHECK(engine.telemetry().snapshot().rtViolations == 0);
    return checks;
}

CheckResult deviceMonitorFallbackChangesSessionRate() {
    CheckResult checks;
    Engine engine;
    DAW_CHECK(publishSource(engine) != nullptr);
    // B runs at 44.1 kHz only.
    FakeDeviceSpec spec = fastSpec({device(1), device(2, {{44100, 44100}}, 44100.0)});
    spec.script = {{1024, FakeDeviceEventType::deviceLost, 1, 0}};
    FakeDeviceDriver driver(engine, spec);
    RecordingHost host(engine, driver, spec);
    host.requested = config(0);
    DeviceMonitor monitor(host);

    DAW_CHECK(startPlaying(engine, driver, host, 20, false));
    DAW_CHECK(pump(driver, monitor) == 3);
    const std::vector<Step> expected{Step::stopTransport, Step::stopDriver, Step::changeSessionRate,
                                     Step::startDriver, Step::deviceChanged};
    DAW_CHECK(host.steps == expected);
    DAW_CHECK(host.rateChanges == std::vector<double>{44100.0});
    DAW_CHECK(host.starts.size() == 1 && host.starts[0].sampleRate == 44100.0);
    DAW_CHECK(host.changes.size() == 1);
    if (host.changes.size() == 1) {
        const DeviceChange& c = host.changes[0];
        DAW_CHECK(c.reason == DeviceChangeReason::deviceLost && !c.error && c.device == 2);
        DAW_CHECK(c.previousSessionRate == kRate && c.sessionRate == 44100.0);
    }
    DAW_CHECK(driver.waitUntilIdle());
    DAW_CHECK(driver.current().outputDevice == 2 && driver.current().sampleRate == 44100.0);
    driver.stop();
    DAW_CHECK(driver.rtViolations() == 0);
    DAW_CHECK(engine.telemetry().snapshot().rtViolations == 0);
    return checks;
}

CheckResult deviceMonitorWaitsForADevice() {
    CheckResult checks;
    Engine engine;
    DAW_CHECK(publishSource(engine) != nullptr);
    FakeDeviceSpec spec = fastSpec({device(1)});
    spec.script = {{512, FakeDeviceEventType::deviceLost, 1, 0}};
    FakeDeviceDriver driver(engine, spec);
    RecordingHost host(engine, driver, spec);
    host.requested = config(0);
    DeviceMonitor monitor(host);

    DAW_CHECK(startPlaying(engine, driver, host, 20, false));
    DAW_CHECK(pump(driver, monitor) == 3);  // aliveChanged, devicesChanged, defaultOutputChanged(0)
    const std::vector<Step> lost{Step::stopTransport, Step::stopDriver, Step::deviceChanged};
    DAW_CHECK(host.steps == lost);  // nothing to start
    DAW_CHECK(host.changes.size() == 1);
    if (host.changes.size() == 1) {
        const DeviceChange& c = host.changes[0];
        DAW_CHECK(c.reason == DeviceChangeReason::deviceLost && c.previousDevice == 1 && c.device == 0);
        DAW_CHECK(c.error && c.error->code == ErrorCode::notFound);
    }
    DAW_CHECK(!driver.running());
    // The two notifications after the first found nothing running and retried quietly.
    DAW_CHECK(monitor.swaps() == 3 && monitor.failedRetries() == 2);

    // Still nothing: another quiet retry.
    host.clear();
    DAW_CHECK(!monitor.handle(notification(DeviceNotificationType::devicesChanged, 0)));
    DAW_CHECK(host.changes.empty() && monitor.failedRetries() == 3);

    // It comes back (and becomes the default): the first notification starts it.
    host.clear();
    DAW_CHECK(driver.inject({0, FakeDeviceEventType::deviceRestored, 1, 0}).ok());
    DAW_CHECK(pump(driver, monitor) == 3);
    const std::vector<Step> back{Step::startDriver, Step::deviceChanged};  // nothing was running
    DAW_CHECK(host.steps == back);
    DAW_CHECK(host.changes.size() == 1);
    if (host.changes.size() == 1) {
        const DeviceChange& c = host.changes[0];
        DAW_CHECK(c.reason == DeviceChangeReason::deviceAvailable && !c.error);
        DAW_CHECK(c.previousDevice == 0 && c.device == 1);
    }
    DAW_CHECK(driver.waitUntilIdle());
    DAW_CHECK(driver.running() && driver.current().outputDevice == 1);
    driver.stop();
    DAW_CHECK(driver.rtViolations() == 0);
    DAW_CHECK(engine.telemetry().snapshot().rtViolations == 0);
    return checks;
}

CheckResult deviceMonitorIgnoresUnrelatedNotifications() {
    CheckResult checks;
    Engine engine;
    DAW_CHECK(publishSource(engine) != nullptr);
    FakeDeviceSpec spec = fastSpec({device(1), device(2)});
    FakeDeviceDriver driver(engine, spec);
    RecordingHost host(engine, driver, spec);
    host.requested = config(1);
    DeviceMonitor monitor(host);
    DAW_CHECK(startPlaying(engine, driver, host, 4, false));

    using T = DeviceNotificationType;
    const DeviceNotification unrelated[] = {
        notification(T::processorOverload, 1),         // an xrun (IO-023), counted by the driver
        notification(T::devicesChanged, 0),            // B came or went; A is alive
        notification(T::aliveChanged, 2),              // another device
        notification(T::nominalRateChanged, 2, 44100), // another device's rate
        notification(T::nominalRateChanged, 1, kRate), // the rate A runs at
        notification(T::defaultOutputChanged, 2),      // A was chosen explicitly
    };
    for (const DeviceNotification& n : unrelated) DAW_CHECK(!monitor.handle(n));
    // Not wanted (offline, an export): not even a rate change of A.
    host.wanted = false;
    DAW_CHECK(!monitor.handle(notification(T::nominalRateChanged, 1, 44100)));
    host.wanted = true;
    DAW_CHECK(host.steps.empty() && monitor.swaps() == 0);
    DAW_CHECK(driver.running() && driver.current().outputDevice == 1);

    // Following the default, a default move swaps to the new default.
    host.requested = config(0);
    host.defaultOverride = 2;
    auto change = monitor.handle(notification(T::defaultOutputChanged, 2));
    DAW_CHECK(change && change->reason == DeviceChangeReason::defaultOutputChanged && !change->error);
    if (change) DAW_CHECK(change->previousDevice == 1 && change->device == 2);
    DAW_CHECK(driver.waitUntilIdle());
    DAW_CHECK(driver.current().outputDevice == 2);
    // The same default again is no move.
    DAW_CHECK(!monitor.handle(notification(T::defaultOutputChanged, 2)));
    DAW_CHECK(monitor.swaps() == 1);
    driver.stop();
    DAW_CHECK(driver.rtViolations() == 0);
    DAW_CHECK(engine.telemetry().snapshot().rtViolations == 0);
    return checks;
}

CheckResult deviceRendererCountsOverruns() {
    CheckResult checks;
    Engine engine;
    SlowSource* source = publishSource(engine);
    DAW_CHECK(source != nullptr);
    if (!source) return checks;

    std::vector<float> left(16384), right(16384);
    float* out[2] = {left.data(), right.data()};
    auto cycle = [&](DeviceRenderer& renderer, uint32_t frames) {
        RtScope scope;
        renderer.renderCycle(out, 2, nullptr, 0, frames);
        return scope.violations();
    };
    uint64_t violations = 0;
    // 128 frames at 48 kHz last 2.67 ms; the node spins 6 ms per block.
    constexpr uint64_t kSlow = 6'000'000;

    DeviceRenderer renderer(engine);
    renderer.configure(128, kRate);
    DAW_CHECK(renderer.inStartGrace());
    // In the grace window (12000 frames) slow cycles don't count.
    source->spinNanos = kSlow;
    for (int i = 0; i < 2; ++i) violations += cycle(renderer, 128);
    DAW_CHECK(renderer.overruns() == 0 && engine.telemetry().snapshot().xruns == 0);
    source->spinNanos = 0;
    violations += cycle(renderer, 12000 - 256);  // fast, to the end of the window
    DAW_CHECK(!renderer.inStartGrace());

    // After it, every slow cycle overruns and is an xrun.
    source->spinNanos = kSlow;
    for (int i = 0; i < 5; ++i) violations += cycle(renderer, 128);
    DAW_CHECK(renderer.overruns() == 5 && engine.telemetry().snapshot().xruns == 5);
    // Fast cycles with plenty of time (8192 frames: 170 ms) don't.
    source->spinNanos = 0;
    for (int i = 0; i < 3; ++i) violations += cycle(renderer, 8192);
    DAW_CHECK(renderer.overruns() == 5);

    // A restart opens a new window; rate 0 (no device clock) judges nothing.
    renderer.configure(128, kRate);
    DAW_CHECK(renderer.inStartGrace());
    DeviceRenderer unclocked(engine);
    unclocked.configure(128, 0);
    DAW_CHECK(!unclocked.inStartGrace());
    source->spinNanos = kSlow;
    for (int i = 0; i < 3; ++i) violations += cycle(unclocked, 128);
    DAW_CHECK(unclocked.overruns() == 0 && engine.telemetry().snapshot().xruns == 5);
    source->spinNanos = 0;

    DAW_CHECK(violations == 0);
    DAW_CHECK(engine.telemetry().snapshot().rtViolations == 0);
    return checks;
}

CheckResult fakeDeviceSlowNodeCountsXruns() {
    CheckResult checks;
    Engine engine;
    SlowSource* source = publishSource(engine);
    DAW_CHECK(source != nullptr);
    if (!source) return checks;
    FakeDeviceSpec spec;
    spec.pacing = FakePacing::realtime;
    spec.cycleLimit = 100;  // 25600 frames: past the 12000-frame grace window
    FakeDeviceDriver driver(engine, spec);
    DriverConfig c = config(0);
    DAW_CHECK(driver.start(c).ok());
    DAW_CHECK(driver.waitUntilIdle());
    const uint64_t before = driver.renderer().overruns();  // 0 unless the machine stalled

    source->spinNanos = 8'000'000;  // a 256-frame cycle lasts 5.3 ms
    driver.setCycleLimit(105);
    DAW_CHECK(driver.waitUntilIdle());
    source->spinNanos = 0;
    DAW_CHECK(driver.renderer().overruns() >= before + 5);
    // The overruns are the only xruns here.
    DAW_CHECK(engine.telemetry().snapshot().xruns == driver.renderer().overruns());
    driver.stop();
    DAW_CHECK(driver.rtViolations() == 0);
    DAW_CHECK(engine.telemetry().snapshot().rtViolations == 0);
    return checks;
}

CheckResult coreAudioListenerReportsChanges(bool flipRate) {
    CheckResult checks;
    CoreAudioDeviceListener listener;
    DAW_CHECK(listener.start().ok());
    DAW_CHECK(listener.started());
    DAW_CHECK(listener.start().ok());  // no-op

    auto output = CoreAudioDevice::defaultDevice(DeviceDirection::output);
    if (output) {
        const AudioDeviceRef id = output->id();
        listener.watch(id, id);
        DAW_CHECK(listener.watching(id));
        listener.watch(0, 0);
        DAW_CHECK(!listener.watching(id));
        listener.watch(id);

        auto nominal = output->nominalRate();
        auto caps = output->caps(DeviceDirection::output);
        if (flipRate && nominal && caps) {
            double other = 0;
            for (double rate : kSessionRates)
                if (rate != *nominal && supportsRate(*caps, rate)) other = rate;
            if (other != 0) {
                DeviceNotification drained[CoreAudioDeviceListener::kNotificationCapacity];
                (void)listener.pollNotifications(drained, std::size(drained));
                DAW_CHECK(output->setNominalRate(other).ok());
                bool seen = false;
                const auto deadline = std::chrono::steady_clock::now() + 3s;
                while (!seen && std::chrono::steady_clock::now() < deadline) {
                    if (!listener.waitForNotification(100ms)) continue;
                    DeviceNotification n[16];
                    const std::size_t count = listener.pollNotifications(n, std::size(n));
                    for (std::size_t i = 0; i < count; ++i)
                        if (n[i].type == DeviceNotificationType::nominalRateChanged && n[i].device == id &&
                            n[i].sampleRate == other)
                            seen = true;
                }
                DAW_CHECK(seen);
                DAW_CHECK(output->setNominalRate(*nominal).ok());
            }
        }
    }
    listener.stop();
    DAW_CHECK(!listener.started());
    DAW_CHECK(listener.droppedNotifications() == 0);
    return checks;
}

} // namespace daw::testing
