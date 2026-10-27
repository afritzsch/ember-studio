#pragma once
// IO-001..005: plays the engine through a CoreAudio device.
//
// IO-001: an AUHAL output unit on the output device; its render callback (the device's IO thread,
// CONV §3 daw.audio) calls Engine::render through a DeviceRenderer, in blocks of at most the
// configured buffer size. Input is enabled only when DriverConfig::inputEnabled (recording or
// monitoring armed): from the same AUHAL unit when input and output are one device, otherwise
// from a second AUHAL unit on the input device whose IO thread feeds an InputFifo (IO-004).
// IO-002: the IO thread joins the output device's os_workgroup (WorkgroupJoin).
// IO-003: the device is switched to the resolved rate and buffer size before starting.
// IO-005: latency() from the device properties; published to telemetry and the transport.
// IO-023 (with T-051): kAudioDeviceProcessorOverload notifications count as xruns.
//
// Threads: start/stop/latency/current from one non-RT thread at a time; the diagnostics from any.
// The graph published to the engine must be prepared for current().bufferFrames frames or more.

#include <cstdint>
#include <memory>

#include "io/AudioDriver.h"

namespace daw {

class DeviceRenderer;
class Engine;
class InputFifo;
class WorkgroupJoin;

// What start() resolved (IO-003, IO-004). Zeros while stopped.
struct RunningConfig {
    AudioDeviceRef outputDevice = 0;
    AudioDeviceRef inputDevice = 0;  // 0: no input (not enabled, or the device has none)
    bool separateInput = false;      // input comes from another device through the InputFifo
    double sampleRate = 0;
    uint32_t bufferFrames = 0;
    uint32_t outputChannels = 0;
    uint32_t inputChannels = 0;
};

class CoreAudioDriver final : public AudioDriver {
public:
    explicit CoreAudioDriver(Engine& engine);
    ~CoreAudioDriver() override;  // stops
    CoreAudioDriver(const CoreAudioDriver&) = delete;
    CoreAudioDriver& operator=(const CoreAudioDriver&) = delete;

    Result<void> start(const DriverConfig& config) override;
    void stop() override;
    DeviceLatency latency() const override;

    bool running() const;
    const RunningConfig& current() const;

    // Diagnostics, any thread.
    const DeviceRenderer& renderer() const;
    const WorkgroupJoin& workgroup() const;
    const InputFifo& inputFifo() const;
    uint64_t inputErrors() const;  // failed AudioUnitRender calls pulling input
    uint64_t overloads() const;    // kAudioDeviceProcessorOverload notifications

private:
    struct Impl;  // keeps AudioToolbox out of this header
    std::unique_ptr<Impl> impl_;
};

} // namespace daw
