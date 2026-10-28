// T-051 checks for the facade's device handling. Run from Tests/DAWEngineTests/
// FacadeDeviceTests.swift; see FacadeDeviceChecks.h for why they're C++.

#include "FacadeDeviceChecks.h"

#include <chrono>
#include <cmath>
#include <functional>
#include <memory>
#include <optional>
#include <thread>
#include <utility>
#include <vector>

#include "daw/EngineFacade.h"
#include "facade/DriverAdapter.h"
#include "facade/FacadeOptions.h"
#include "io/FakeDeviceDriver.h"

using namespace std::chrono_literals;

namespace daw::testing {

namespace {

// A realtime facade on the default fake devices (DW-089), with the adapter kept for its driver.
struct FakeFacade {
    EngineFacade* facade = nullptr;
    FakeDeviceDriverAdapter* adapter = nullptr;
    std::vector<EngineEventPOD> events;  // everything polled so far

    explicit FakeFacade(FakeDeviceSpec spec = defaultFakeDeviceSpec(), double rate = 0) {
        auto owned = std::make_unique<FakeDeviceDriverAdapter>(std::move(spec));
        adapter = owned.get();
        FacadeOptions options;
        options.driver = std::move(owned);
        DriverConfigPOD config;
        config.driver = DeviceDriverKind::fake;
        config.sampleRate = rate;  // 0: Fake Device A's nominal 48 kHz
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

    void poll() {
        EngineEventPOD batch[16];
        for (size_t n; (n = facade->pollEvents(batch, 16)) > 0;)
            for (size_t i = 0; i < n; ++i) events.push_back(batch[i]);
    }
    // The first event of `type` not taken yet, waiting up to `timeout` for it.
    std::optional<EngineEventPOD> take(EngineEventType type, std::chrono::milliseconds timeout = 2000ms) {
        const auto deadline = std::chrono::steady_clock::now() + timeout;
        for (;;) {
            poll();
            for (auto it = events.begin(); it != events.end(); ++it)
                if (it->type == type) {
                    EngineEventPOD e = *it;
                    events.erase(it);
                    return e;
                }
            if (std::chrono::steady_clock::now() > deadline) return std::nullopt;
            std::this_thread::sleep_for(2ms);
        }
    }
};

GraphDescription masterOnly() {
    GraphDescriptionBuilder b;
    b.addNode(1, NodeKind::master, 1, 0, 0, "");
    b.setTempo(0, 120.0);
    b.setTimeSignature(0, 4, 4);
    b.setMaster(1);
    return b.description();
}

bool waitUntil(const std::function<bool()>& condition, std::chrono::milliseconds timeout = 2000ms) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (!condition()) {
        if (std::chrono::steady_clock::now() > deadline) return false;
        std::this_thread::sleep_for(1ms);
    }
    return true;
}

DeviceEventPOD event(DeviceEventKind kind, uint32_t device = 0, double rate = 0) {
    DeviceEventPOD e;
    e.kind = kind;
    e.deviceID = device;
    e.sampleRate = rate;
    return e;
}

} // namespace

CheckResult facadeDeviceLossFallsBack() {
    CheckResult checks;
    FakeFacade f;
    DAW_CHECK(f.facade != nullptr);
    if (!f.facade) return checks;
    EngineFacade& facade = *f.facade;
    TelemetryPOD t = facade.telemetry();
    DAW_CHECK(t.deviceRunning && t.outputDeviceID == 1 && t.sampleRate == 48000.0);

    const uint64_t version = facade.applyGraph(masterOnly());
    DAW_CHECK(facade.waitForGraph(version, 5000).publishedVersion == version);
    facade.locate(1920);  // one second at 120 bpm
    facade.play();
    DAW_CHECK(waitUntil([&] { return facade.transport().playing && facade.transport().tick > 1920; }));

    DAW_CHECK(facade.simulateDeviceEvent(event(DeviceEventKind::deviceLost)).ok());
    auto changed = f.take(EngineEventType::deviceChanged, 0ms);  // already reacted on return
    DAW_CHECK(changed.has_value());
    if (changed) {
        DAW_CHECK(changed->error.ok());
        DAW_CHECK(changed->device.reason == DeviceChangeReason::deviceLost);
        DAW_CHECK(changed->device.previousDeviceID == 1 && changed->device.deviceID == 2);
        DAW_CHECK(changed->device.previousSampleRate == 48000.0 && changed->device.sampleRate == 44100.0);
    }

    // IO-021 (5): B runs only at 44.1 kHz, so the session moved there and the graph was rebuilt.
    t = facade.telemetry();
    DAW_CHECK(t.deviceRunning && t.outputDeviceID == 2 && t.sampleRate == 44100.0);
    const GraphStatusPOD status = facade.graphStatus();
    DAW_CHECK(status.submittedVersion == version + 1 && status.publishedVersion == version + 1);
    DAW_CHECK(status.completedVersion == version + 1 && status.lastError.ok());
    DAW_CHECK(facade.waitForGraph(version, 0).completedVersion >= version);  // an older one: at once
    DAW_CHECK(t.graphVersion == version + 1);
    // (1): stopped, at the tick it stopped at, which is now at 44.1 kHz samples.
    const TransportPOD transport = facade.transport();
    DAW_CHECK(!transport.playing && transport.tick > 1920);
    DAW_CHECK(std::abs(static_cast<double>(transport.sample) - transport.tick * 44100.0 / 1920.0) <= 1.0);
    // The fallback renders, and later restarts keep it (the request now follows the default).
    FakeDeviceDriver* driver = f.adapter->driver();
    DAW_CHECK(driver != nullptr);
    if (driver) {
        const uint64_t cycles = driver->cycles();
        DAW_CHECK(waitUntil([&] { return driver->cycles() > cycles + 5; }));
        DAW_CHECK(driver->current().outputDevice == 2 && driver->current().sampleRate == 44100.0);
    }
    facade.armInput(9, 0, true);  // DW-067: a restart
    DAW_CHECK(facade.telemetry().outputDeviceID == 2 && facade.telemetry().sampleRate == 44100.0);
    DAW_CHECK(!f.take(EngineEventType::deviceChanged, 0ms));
    DAW_CHECK(f.violations() == 0);
    return checks;
}

CheckResult facadeRateChangeKeepsSessionRate() {
    CheckResult checks;
    FakeFacade f;
    DAW_CHECK(f.facade != nullptr);
    if (!f.facade) return checks;
    EngineFacade& facade = *f.facade;
    const uint64_t version = facade.applyGraph(masterOnly());
    DAW_CHECK(facade.waitForGraph(version, 5000).publishedVersion == version);

    // Another app sets A to 44.1 kHz; A also does 48 kHz, so the session keeps it.
    DAW_CHECK(facade.simulateDeviceEvent(event(DeviceEventKind::sampleRateChanged, 1, 44100.0)).ok());
    auto changed = f.take(EngineEventType::deviceChanged, 0ms);
    DAW_CHECK(changed.has_value());
    if (changed) {
        DAW_CHECK(changed->error.ok() && changed->device.reason == DeviceChangeReason::sampleRateChanged);
        DAW_CHECK(changed->device.previousDeviceID == 1 && changed->device.deviceID == 1);
        DAW_CHECK(changed->device.previousSampleRate == 48000.0 && changed->device.sampleRate == 48000.0);
    }
    const TelemetryPOD t = facade.telemetry();
    DAW_CHECK(t.deviceRunning && t.outputDeviceID == 1 && t.sampleRate == 48000.0);
    DAW_CHECK(facade.graphStatus().publishedVersion == version);  // nothing to rebuild
    FakeDeviceDriver* driver = f.adapter->driver();
    DAW_CHECK(driver && driver->current().sampleRate == 48000.0);
    // A rate the device doesn't have is refused.
    DAW_CHECK(facade.simulateDeviceEvent(event(DeviceEventKind::sampleRateChanged, 2, 96000.0)).code ==
              FacadeErrorCode::invalidArgument);
    DAW_CHECK(f.violations() == 0);
    return checks;
}

CheckResult facadeWaitsForDeviceAndPollsOnItsOwn() {
    CheckResult checks;
    {
        FakeFacade f;
        DAW_CHECK(f.facade != nullptr);
        if (!f.facade) return checks;
        EngineFacade& facade = *f.facade;
        DAW_CHECK(facade.simulateDeviceEvent(event(DeviceEventKind::deviceLost, 1)).ok());
        DAW_CHECK(f.take(EngineEventType::deviceChanged, 0ms).has_value());  // 1 → 2
        DAW_CHECK(facade.simulateDeviceEvent(event(DeviceEventKind::deviceLost, 2)).ok());
        auto lost = f.take(EngineEventType::deviceChanged, 0ms);
        DAW_CHECK(lost.has_value());
        if (lost) {
            DAW_CHECK(lost->device.reason == DeviceChangeReason::deviceLost);
            DAW_CHECK(lost->device.previousDeviceID == 2 && lost->device.deviceID == 0);
            DAW_CHECK(lost->error.code == FacadeErrorCode::notFound);
        }
        TelemetryPOD t = facade.telemetry();
        DAW_CHECK(!t.deviceRunning && t.outputDeviceID == 0 && t.sampleRate == 44100.0);
        DAW_CHECK(facade.devices().empty());

        // A comes back: it runs 44.1 kHz too, so the session stays there.
        DAW_CHECK(facade.simulateDeviceEvent(event(DeviceEventKind::deviceRestored, 1)).ok());
        auto back = f.take(EngineEventType::deviceChanged, 0ms);
        DAW_CHECK(back.has_value());
        if (back) {
            DAW_CHECK(back->error.ok() && back->device.reason == DeviceChangeReason::deviceAvailable);
            DAW_CHECK(back->device.previousDeviceID == 0 && back->device.deviceID == 1);
            DAW_CHECK(back->device.sampleRate == 44100.0);
        }
        t = facade.telemetry();
        DAW_CHECK(t.deviceRunning && t.outputDeviceID == 1 && t.sampleRate == 44100.0);
        DAW_CHECK(!f.take(EngineEventType::deviceChanged, 0ms));  // one event per change
        DAW_CHECK(f.violations() == 0);
    }
    {
        // IO-022: nobody calls into the facade; daw.device notices a scripted loss by itself.
        FakeDeviceSpec spec = defaultFakeDeviceSpec();
        spec.script = {{4800, FakeDeviceEventType::deviceLost, 1, 0}};  // 0.1 s in
        FakeFacade f(spec);
        DAW_CHECK(f.facade != nullptr);
        if (!f.facade) return checks;
        auto changed = f.take(EngineEventType::deviceChanged, 3000ms);
        DAW_CHECK(changed.has_value());
        if (changed) {
            DAW_CHECK(changed->error.ok() && changed->device.reason == DeviceChangeReason::deviceLost);
            DAW_CHECK(changed->device.deviceID == 2);
        }
        DAW_CHECK(f.facade->telemetry().outputDeviceID == 2);
        DAW_CHECK(f.violations() == 0);
    }
    return checks;
}

CheckResult facadeDeviceTelemetryAndSimulation() {
    CheckResult checks;
    {
        FakeFacade f;
        DAW_CHECK(f.facade != nullptr);
        if (!f.facade) return checks;
        EngineFacade& facade = *f.facade;
        DAW_CHECK(facade.simulateDeviceEvent(event(DeviceEventKind::processorOverload)).ok());
        const TelemetryPOD t = facade.telemetry();
        DAW_CHECK(t.processorOverloads == 1 && t.xruns == t.processorOverloads + t.renderOverruns);
        auto overload = f.take(EngineEventType::overload, 0ms);
        DAW_CHECK(overload && overload->count == t.xruns);
        DAW_CHECK(!f.take(EngineEventType::deviceChanged, 0ms));  // an overload changes no device
        DAW_CHECK(facade.simulateDeviceEvent(event(DeviceEventKind::deviceLost, 7)).code ==
                  FacadeErrorCode::invalidArgument);
        DAW_CHECK(f.violations() == 0);
    }
    {
        // DW-089: EngineFacade::create picks the fake from the config.
        DriverConfigPOD config;
        config.driver = DeviceDriverKind::fake;
        config.sampleRate = 0;
        EngineFacade* facade = EngineFacade::create(EngineMode::realtime, config);
        DAW_CHECK(facade != nullptr);
        if (facade) {
            const auto devices = facade->devices();
            DAW_CHECK(devices.size() == 2);
            if (devices.size() == 2) {
                DAW_CHECK(devices[0].deviceID == 1 && devices[0].name == "Fake Device A" && devices[0].isDefaultOutput);
                DAW_CHECK(devices[1].deviceID == 2 && devices[1].name == "Fake Device B");
                DAW_CHECK(devices[1].nominalSampleRate == 44100.0);
            }
            const TelemetryPOD t = facade->telemetry();
            DAW_CHECK(t.deviceRunning && t.outputDeviceID == 1 && t.sampleRate == 48000.0);
            DAW_CHECK(facade->simulateDeviceEvent(event(DeviceEventKind::deviceLost)).ok());
            DAW_CHECK(facade->telemetry().outputDeviceID == 2);
            DAW_CHECK(facade->telemetry().rtViolations == 0);
            releaseFacade(facade);
        }
    }
    {
        // Off the fake driver there is nothing to simulate.
        EngineFacade* offline = EngineFacade::create(EngineMode::offline, DriverConfigPOD{});
        DAW_CHECK(offline != nullptr);
        if (offline) {
            DAW_CHECK(offline->simulateDeviceEvent(event(DeviceEventKind::deviceLost)).code ==
                      FacadeErrorCode::unsupported);
            const TelemetryPOD t = offline->telemetry();
            DAW_CHECK(t.outputDeviceID == 0 && t.processorOverloads == 0 && t.renderOverruns == 0);
            releaseFacade(offline);
        }
    }
    return checks;
}

CheckResult facadeSetDeviceChangesSessionRate() {
    CheckResult checks;
    FakeFacade f;
    DAW_CHECK(f.facade != nullptr);
    if (!f.facade) return checks;
    EngineFacade& facade = *f.facade;
    const uint64_t version = facade.applyGraph(masterOnly());
    DAW_CHECK(facade.waitForGraph(version, 5000).publishedVersion == version);
    facade.locate(960);

    DriverConfigPOD config;
    config.driver = DeviceDriverKind::fake;
    config.bufferFrames = 128;
    config.sampleRate = 96000.0;  // A can
    DAW_CHECK(facade.setDevice(config).ok());
    TelemetryPOD t = facade.telemetry();
    DAW_CHECK(t.deviceRunning && t.outputDeviceID == 1 && t.sampleRate == 96000.0);
    GraphStatusPOD status = facade.graphStatus();
    DAW_CHECK(status.publishedVersion == version + 1 && status.lastError.ok());
    DAW_CHECK(facade.waitForGraph(version, 0).completedVersion == version + 1);
    DAW_CHECK(facade.transport().tick == 960 && facade.transport().sample == 48000);  // 0.5 s at 96k
    // The model's next graph builds at the new rate, with ordinary versions.
    const uint64_t next = facade.applyGraph(masterOnly());
    DAW_CHECK(next == version + 2);
    DAW_CHECK(facade.waitForGraph(next, 5000).publishedVersion == next);

    // Rate 0 keeps the session rate if the device supports it…
    config.sampleRate = 0;
    DAW_CHECK(facade.setDevice(config).ok());
    DAW_CHECK(facade.telemetry().sampleRate == 96000.0);
    DAW_CHECK(facade.graphStatus().publishedVersion == next);
    // …and takes the device's when it doesn't (B: 44.1 kHz only).
    config.outputDevice = 2;
    DAW_CHECK(facade.setDevice(config).ok());
    t = facade.telemetry();
    DAW_CHECK(t.outputDeviceID == 2 && t.sampleRate == 44100.0);
    DAW_CHECK(facade.graphStatus().publishedVersion == next + 1);
    // No deviceChanged for a change the caller asked for.
    DAW_CHECK(!f.take(EngineEventType::deviceChanged, 0ms));

    // Not a session rate; another driver kind.
    config.sampleRate = 22050.0;
    DAW_CHECK(facade.setDevice(config).code == FacadeErrorCode::invalidArgument);
    config.sampleRate = 0;
    config.driver = DeviceDriverKind::coreAudio;
    DAW_CHECK(facade.setDevice(config).code == FacadeErrorCode::invalidArgument);
    DAW_CHECK(facade.telemetry().deviceRunning);
    DAW_CHECK(f.violations() == 0);
    return checks;
}

} // namespace daw::testing
