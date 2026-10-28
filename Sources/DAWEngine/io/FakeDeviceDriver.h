#pragma once
// TEST-005: a device driver without a device, for IO and REC tests (CoreAudio never starts in
// tests). It plays a set of made-up devices: its own render thread (CONV §3 daw.audio) runs IO
// cycles through a DeviceRenderer, like CoreAudioDriver's AUHAL callback (DW-070), either paced
// in real time or as fast as possible, and
//   - reports configurable latency (IO-005, published with publishDeviceLatency),
//   - counts render overruns as xruns in real-time pacing (IO-023, DeviceRenderer),
//   - loops output back to input with N frames of delay while input is enabled,
//   - plays scripted device events (device loss and return, rate change, processor overload) and
//     reports them as DeviceNotifications, the seam DeviceMonitor (T-051, IO-020..023) consumes.
// It doesn't react to its own events: after a loss it simply stops cycling, like a dead device.
//
// Every IO cycle runs inside an RtScope; rtViolations() is what those scopes counted (CONV §5.3).
// Tests stay deterministic with a cycle limit: the thread renders only while cycles() is below it
// and parks there (no Engine::render calls) until it is raised, so a test can run exactly N
// cycles with waitUntilIdle(), and scripted events fall on exact frames.
//
// Threads: start/stop/latency/current like any AudioDriver (one non-RT thread at a time). The
// control and query functions are safe from any non-RT thread, also while another starts or
// stops the driver (the facade's export thread does). pollNotifications has one consumer.

#include <chrono>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "core/Realtime.h"
#include "io/AudioDriver.h"
#include "io/DeviceNotification.h"
#include "io/DriverConfig.h"

namespace daw {

class DeviceRenderer;
class Engine;

// One made-up device. Its IDs share the AudioDeviceRef space (0 is "the default").
struct FakeDevice {
    AudioDeviceRef id = 1;
    std::string name = "Fake Device";
    // IO-003: what resolveConfig sees. Input channels 0: an output-only device.
    DeviceCaps output{48000.0, {{44100, 44100}, {48000, 48000}, {88200, 88200}, {96000, 96000}}, 32, 2048, 2};
    DeviceCaps input{48000.0, {{44100, 44100}, {48000, 48000}, {88200, 88200}, {96000, 96000}}, 32, 2048, 2};
    // IO-005: per direction. bufferFrames is ignored; the resolved buffer size is added.
    LatencyComponents outputLatency;
    LatencyComponents inputLatency;
};

enum class FakePacing : uint8_t {
    realtime,          // a cycle every cycle-frames / device-rate seconds (steady clock)
    asFastAsPossible,  // cycles back to back
};

enum class FakeDeviceEventType : uint8_t {
    // The device disappears: not alive, gone from devices(); a default output moves to the next
    // live device (or none). The driver running on it stops cycling (no more Engine::render
    // calls); running() stays true until stop(), as with a CoreAudio device. Notifies
    // aliveChanged, devicesChanged, then defaultOutputChanged if the default moved.
    deviceLost,
    // It comes back (aliveChanged, devicesChanged); it becomes the default only if there was none.
    // A driver that was running on it stays parked until restarted.
    deviceRestored,
    // Another app set its nominal rate to `sampleRate` (nominalRateChanged). Cycles go on with
    // the frames they had; real-time pacing follows the new rate. The next start() with rate 0
    // resolves to it.
    sampleRateChanged,
    // A kAudioDeviceProcessorOverload notification: counted as an xrun like CoreAudioDriver does
    // (IO-023, DW-049), then notified.
    processorOverload,
};

struct FakeDeviceEvent {
    // Scripted: happens before the first cycle that starts at or after this many frames rendered
    // by the driver (all runs together). Ignored by inject().
    uint64_t atFrame = 0;
    FakeDeviceEventType type = FakeDeviceEventType::deviceLost;
    AudioDeviceRef device = 0;  // 0: the device the driver runs on (stopped: the default output)
    double sampleRate = 0;      // sampleRateChanged: a rate the device supports
};

// One IO cycle as a tap sees it, after Engine::render: the input handed to the engine and the
// output it wrote. Valid only during the call.
struct FakeCycle {
    const float* const* input = nullptr;
    uint32_t inputChannels = 0;
    const float* const* output = nullptr;
    uint32_t outputChannels = 0;
    uint32_t numFrames = 0;
    uint64_t startFrame = 0;  // frames rendered by the driver before this cycle (all runs)
};
// Called on the render thread inside the cycle's RtScope, so it must be RT-safe.
using FakeCycleTap = void (*)(void* context, const FakeCycle& cycle) DAW_RT;

struct FakeDeviceSpec {
    static constexpr uint64_t kUnlimited = UINT64_MAX;

    std::vector<FakeDevice> devices{FakeDevice{}};  // non-empty, distinct non-zero IDs
    AudioDeviceRef defaultOutput = 0;               // 0: the first device
    FakePacing pacing = FakePacing::realtime;
    // Frames per IO cycle, used in turn (cycle k uses cycleFrames[k % size]); each 1…kMaxBlock
    // (DeviceRenderer splits them into blocks of at most the buffer size). Empty: the buffer size.
    std::vector<uint32_t> cycleFrames;
    // While input is enabled, input channel c is output channel c `loopbackDelay` frames earlier
    // (silence before that, and on input channels the output doesn't have). nullopt: the device's
    // input + output latency, what a cable from output to input would measure. It must be at
    // least the longest cycle (a frame is rendered before it can come back) and at most
    // kMaxLoopbackDelay. loopback false: the input is silence.
    bool loopback = true;
    std::optional<uint32_t> loopbackDelay;
    static constexpr uint32_t kMaxLoopbackDelay = 1u << 20;
    // In atFrame order; each event names a known device (or 0).
    std::vector<FakeDeviceEvent> script;
    // The initial cycle limit (see setCycleLimit).
    uint64_t cycleLimit = kUnlimited;
    FakeCycleTap tap = nullptr;
    void* tapContext = nullptr;
};

// A device as it is now (events change `alive`, `nominalRate` and the default output).
struct FakeDeviceState {
    AudioDeviceRef id = 0;
    std::string name;
    uint32_t inputChannels = 0;
    uint32_t outputChannels = 0;
    double nominalRate = 0;
    bool alive = true;
};

class FakeDeviceDriver final : public AudioDriver {
public:
    static constexpr uint64_t kUnlimited = FakeDeviceSpec::kUnlimited;

    FakeDeviceDriver(Engine& engine, FakeDeviceSpec spec = {});
    ~FakeDeviceDriver() override;  // stops
    FakeDeviceDriver(const FakeDeviceDriver&) = delete;
    FakeDeviceDriver& operator=(const FakeDeviceDriver&) = delete;

    // IO-003/004 like CoreAudioDriver: device 0 is the default output; input (only when enabled)
    // always comes from the output device (fake devices share no clock). Fails with
    // invalidArgument for a bad spec or loopback delay or while running, notFound for an unknown,
    // lost or missing default device, and whatever resolveConfig fails with.
    Result<void> start(const DriverConfig& config) override;
    void stop() override;
    DeviceLatency latency() const override;

    bool running() const;
    // What start() resolved; zeros while stopped. From the thread that starts and stops.
    const RunningConfig& current() const;
    // Diagnostics: cycles(), frames(), blocks() of all runs.
    const DeviceRenderer& renderer() const;

    // The render thread renders while cycles() < the limit (kUnlimited: no limit). To run exactly
    // N cycles from a start, set the limit before start(): the count can't move while stopped,
    // whereas a running unlimited thread may pass a limit computed from cycles() before it lands.
    void setCycleLimit(uint64_t totalCycles);
    uint64_t cycleLimit() const;
    // Waits until the render thread is parked with nothing to render (at the cycle limit, or its
    // device is lost) or the driver isn't running. False on timeout.
    bool waitUntilIdle(std::chrono::milliseconds timeout = std::chrono::milliseconds(5000)) const;
    uint64_t cycles() const;
    uint64_t frames() const;
    // Violations counted by the IO cycles' RtScopes, all runs (DW-019). 0 in Release.
    uint64_t rtViolations() const;

    // An event now (atFrame ignored): while running, the render thread applies it before its next
    // cycle; otherwise it is applied here. Returns once applied. invalidArgument for an unknown
    // device or a rate the device doesn't support.
    Result<void> inject(const FakeDeviceEvent& event);

    // IO-020 seam: notifications in the order the events made them, from one consumer thread.
    // The queue holds kNotificationCapacity; more are dropped and counted.
    static constexpr std::size_t kNotificationCapacity = 256;
    std::size_t pollNotifications(DeviceNotification* out, std::size_t max);
    uint64_t droppedNotifications() const;

    std::vector<FakeDeviceState> devices() const;  // every device, alive or not
    AudioDeviceRef defaultOutput() const;          // 0: none alive

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace daw
