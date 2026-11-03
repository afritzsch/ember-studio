#pragma once
// The facade's seam for a device driver (BRIDGE-008 realtime mode, 04 IO-001..005). The 04
// AudioDriver contract has no notion of the engine it renders (CoreAudioDriver takes it at
// construction, after the facade has made it), of whether it runs, or of the rate it resolved, so
// the facade talks to a DriverAdapter: CoreAudioDriverAdapter in production, a fake one that
// renders on demand in tests (CoreAudio never starts in tests), or FakeDeviceDriverAdapter for a
// fake device with its own render thread (TEST-005).
//
// Threads: the facade calls every method from non-RT threads, one at a time (under its lock).

#include <atomic>
#include <cstddef>
#include <memory>
#include <vector>

#include "core/Engine.h"
#include "core/Result.h"
#include "daw/EngineFacade.h"
#include "io/CoreAudioDeviceListener.h"
#include "io/DeviceLatency.h"
#include "io/DeviceNotification.h"
#include "io/DriverConfig.h"
#include "io/FakeDeviceDriver.h"

namespace daw {

class DriverAdapter {
public:
    virtual ~DriverAdapter() = default;

    // Opens the device(s) in `config` and calls engine.render() from the device's IO thread
    // from then on. The driver reports its output latency to the transport and telemetry
    // (IO-005, DW-059) and counts xruns (IO-023). Fails while running.
    virtual Result<void> start(Engine& engine, const DriverConfig& config) = 0;
    // Returns once render() is no longer being called and won't be again until start().
    virtual void stop() = 0;
    virtual bool running() const = 0;
    // What the running device resolved (IO-003); meaningful once start() succeeded.
    virtual double sampleRate() const = 0;
    virtual uint32_t bufferFrames() const = 0;
    virtual std::vector<DeviceInfoPOD> devices() const = 0;

    // MARK: IO-020..023 (T-051). The defaults suit a driver without device events (a test
    // adapter): nothing is ever lost, nothing is notified.

    // What start() resolved; zeros while not running. The default knows only rate and buffer.
    virtual RunningConfig current() const {
        RunningConfig config;
        if (running()) {
            config.sampleRate = sampleRate();
            config.bufferFrames = bufferFrames();
        }
        return config;
    }
    // IO-005 of the running device (zeros while stopped), for REC-003's latency compensation
    // (T-052). The default: none.
    virtual DeviceLatency latency() const { return {}; }
    // Devices as they are now, for DeviceMonitor (IO-021 (4), (5)).
    virtual bool deviceAlive(AudioDeviceRef) const { return true; }
    virtual AudioDeviceRef defaultOutputDevice() const { return 0; }
    virtual Result<DeviceCaps> outputCaps(AudioDeviceRef) const {
        return makeError(ErrorCode::notFound, "this driver can't describe its devices");
    }
    // IO-020: device notifications since the last call (one consumer: the facade).
    virtual std::size_t pollNotifications(DeviceNotification*, std::size_t) { return 0; }
    // IO-023: xruns by source, since the adapter was made.
    virtual uint64_t processorOverloads() const { return 0; }
    virtual uint64_t renderOverruns() const { return 0; }
    // DW-089: plays a made-up device event; unsupported except on the fake device.
    virtual Result<void> simulate(const FakeDeviceEvent&) {
        return makeError(ErrorCode::unsupported, "device events can only be simulated on the fake device driver");
    }
};

// The production driver for realtime mode: CoreAudioDriver (T-011), with a
// CoreAudioDeviceListener that watches the devices it runs on after every start (IO-020).
std::unique_ptr<DriverAdapter> makeDefaultDriverAdapter();

// DeviceDriverKind::fake (DW-089): devices 1 "Fake Device A" (44.1/48/88.2/96 kHz, nominal 48 kHz)
// and 2 "Fake Device B" (44.1 kHz only), both stereo in and out, paced in real time.
FakeDeviceSpec defaultFakeDeviceSpec();

// TEST-005: a FakeDeviceDriver as a DriverAdapter, so a realtime facade runs on made-up devices
// on its own render thread (FacadeOptions::driver). Like CoreAudioDriverAdapter, the driver is
// made on the first start(), once the engine exists; devices() lists the live fake devices.
class FakeDeviceDriverAdapter final : public DriverAdapter {
public:
    explicit FakeDeviceDriverAdapter(FakeDeviceSpec spec);
    ~FakeDeviceDriverAdapter() override;

    Result<void> start(Engine& engine, const DriverConfig& config) override;
    void stop() override;
    bool running() const override;
    double sampleRate() const override;
    uint32_t bufferFrames() const override;
    std::vector<DeviceInfoPOD> devices() const override;
    RunningConfig current() const override;
    DeviceLatency latency() const override;
    bool deviceAlive(AudioDeviceRef device) const override;
    AudioDeviceRef defaultOutputDevice() const override;
    Result<DeviceCaps> outputCaps(AudioDeviceRef device) const override;
    std::size_t pollNotifications(DeviceNotification* out, std::size_t max) override;
    uint64_t processorOverloads() const override;
    uint64_t renderOverruns() const override;
    Result<void> simulate(const FakeDeviceEvent& event) override;

    // The driver, for pacing, scripting and polling it from tests (any thread); null until the
    // first start(). It lives as long as the adapter, i.e. as long as the facade that owns it.
    FakeDeviceDriver* driver() const { return driver_.load(std::memory_order_acquire); }

private:
    std::vector<FakeDeviceState> states() const;

    FakeDeviceSpec spec_;
    Engine* engine_ = nullptr;
    std::unique_ptr<FakeDeviceDriver> owned_;
    std::atomic<FakeDeviceDriver*> driver_{nullptr};
};

} // namespace daw
