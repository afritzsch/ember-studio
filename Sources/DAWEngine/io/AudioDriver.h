#pragma once
// 04 Interfaces: a device driver. It owns the engine's render thread while running (02: one
// render thread at a time), so a driver is stopped before an offline render (OfflineDriver.h).
// CoreAudioDriver is the real one; FakeDeviceDriver (T-050) stands in for it in tests.
//
// Threads: start/stop/latency from one non-RT thread at a time (the facade serializes them).

#include "core/Result.h"
#include "io/DeviceLatency.h"
#include "io/DriverConfig.h"

namespace daw {

class AudioDriver {
public:
    // Opens the device(s) as `config` asks (IO-003, IO-004) and starts calling Engine::render.
    // Fails without starting anything; fails with invalidArgument while already running.
    virtual Result<void> start(const DriverConfig& config) = 0;
    // Returns once Engine::render is no longer called. Idempotent.
    virtual void stop() = 0;
    // IO-005: of the running device(s); zeros while stopped.
    virtual DeviceLatency latency() const = 0;
    virtual ~AudioDriver() = default;
};

} // namespace daw
