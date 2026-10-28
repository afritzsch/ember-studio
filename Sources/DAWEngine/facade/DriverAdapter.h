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
#include <memory>
#include <vector>

#include "core/Engine.h"
#include "core/Result.h"
#include "daw/EngineFacade.h"
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
};

// The production driver for realtime mode: CoreAudioDriver (T-011).
std::unique_ptr<DriverAdapter> makeDefaultDriverAdapter();

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

    // The driver, for pacing, scripting and polling it from tests (any thread); null until the
    // first start(). It lives as long as the adapter, i.e. as long as the facade that owns it.
    FakeDeviceDriver* driver() const { return driver_.load(std::memory_order_acquire); }

private:
    FakeDeviceSpec spec_;
    Engine* engine_ = nullptr;
    std::unique_ptr<FakeDeviceDriver> owned_;
    std::atomic<FakeDeviceDriver*> driver_{nullptr};
};

} // namespace daw
