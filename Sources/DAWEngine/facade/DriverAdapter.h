#pragma once
// The facade's seam for a device driver (BRIDGE-008 realtime mode, 04 IO-001..005). The
// facade doesn't name CoreAudioDriver (T-011): it talks to a DriverAdapter, so the driver can be
// attached once it exists, and tests can attach a fake one that renders on demand.
//
// Threads: the facade calls every method from non-RT threads, one at a time (under its lock).

#include <memory>
#include <vector>

#include "core/Engine.h"
#include "core/Result.h"
#include "daw/EngineFacade.h"

namespace daw {

class DriverAdapter {
public:
    virtual ~DriverAdapter() = default;

    // Opens the device(s) in `config` and calls engine.render() from the device's IO thread
    // from then on. The driver reports its output latency to engine.transport() (DW-059) and
    // telemetry (IO-005), and counts xruns (IO-023).
    virtual Result<void> start(Engine& engine, const DriverConfig& config) = 0;
    // Returns once render() is no longer being called and won't be again until start().
    virtual void stop() = 0;
    virtual bool running() const = 0;
    // The rate the device runs at; meaningful once start() succeeded.
    virtual double sampleRate() const = 0;
    virtual std::vector<DeviceInfoPOD> devices() const = 0;
};

// The production driver for realtime mode. Null until the CoreAudio driver lands (T-011); the
// facade then runs without a device.
std::unique_ptr<DriverAdapter> makeDefaultDriverAdapter();

} // namespace daw
