#pragma once
// The facade's seam for a device driver (BRIDGE-008 realtime mode, 04 IO-001..005). The 04
// AudioDriver contract has no notion of the engine it renders (CoreAudioDriver takes it at
// construction, after the facade has made it), of whether it runs, or of the rate it resolved, so
// the facade talks to a DriverAdapter: CoreAudioDriverAdapter in production, a fake one that
// renders on demand in tests (CoreAudio never starts in tests).
//
// Threads: the facade calls every method from non-RT threads, one at a time (under its lock).

#include <memory>
#include <vector>

#include "core/Engine.h"
#include "core/Result.h"
#include "daw/EngineFacade.h"
#include "io/DriverConfig.h"

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

} // namespace daw
