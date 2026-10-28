#pragma once
// IO-020..022 (D-12, D-26): reacts to device changes. It reads DeviceNotifications (IO-020; from
// CoreAudioDeviceListener or FakeDeviceDriver, the io/DeviceNotification.h seam), decides whether
// one concerns the device the engine runs on, and if so runs the IO-021 hot-swap sequence through
// its host, which owns the engine, the driver and the session (the facade, or a test):
//
//   (1) stop the transport, (2) finalize recordings if recording (09), (3) stop the driver,
//   (4) pick the device: the same one after a rate change, the system default after a loss,
//   (5) if that device can't run at the session rate, switch the session to the rate it runs at
//       (the host re-prepares nodes, re-resamples assets (IO-033) and rebuilds the graph);
//       otherwise keep the session rate, which the driver sets on the device again,
//   (6) restart the driver, (7) report a DeviceSwap (EngineEvent.deviceChanged{reason}).
//
// What triggers it:
//   - deviceLost: the output device (or the separate input device) isn't alive any more
//     (aliveChanged; devicesChanged and defaultOutputChanged re-check it, since the HAL doesn't
//     order them). An explicitly chosen device falls back to the default (D-26) and stays there.
//   - sampleRateChanged: the output (or separate input) device's nominal rate is no longer the
//     rate the driver runs at.
//   - defaultOutputChanged: the engine follows the system default (DriverConfig::outputDevice 0)
//     and the default moved to another device.
//   - deviceAvailable: the device should run but doesn't (the last start failed, e.g. nothing was
//     plugged in) and a device notification arrives; it tries again from (4). Failed retries stay quiet.
// processorOverload notifications are xruns, which the drivers count (IO-023); they change nothing
// here. Nothing happens while the host doesn't want the device running (offline mode, an export).
//
// IO-022: it runs on whichever non-RT thread calls handle(), never on the audio thread; the audio
// thread only produces notifications through a lock-free queue (FakeDeviceDriver) or not at all
// (CoreAudio's arrive on HAL threads). DeviceSwaps reach the UI as polled deviceChanged events (facade).
//
// Threads: one thread at a time calls handle(), and the host's state must not change meanwhile
// (the facade holds its lock).

#include <cstdint>
#include <optional>

#include "core/Result.h"
#include "io/DeviceNotification.h"
#include "io/DriverConfig.h"

namespace daw {

// The facade maps these onto EngineFacade.h's DeviceChangeReason (08 T-051 delta).
enum class DeviceSwapReason : uint8_t {
    deviceLost,
    sampleRateChanged,
    defaultOutputChanged,
    deviceAvailable,
};

// IO-021 (7): what the sequence did, for a UI toast.
struct DeviceSwap {
    DeviceSwapReason reason = DeviceSwapReason::deviceLost;
    AudioDeviceRef previousDevice = 0;  // the output device before (0: none was running)
    AudioDeviceRef device = 0;          // the output device running now (0: none, see error)
    double previousSessionRate = 0;
    double sessionRate = 0;             // after; differs from previousSessionRate only via (5)
    // Set when the driver couldn't be restarted: notFound when there is no device to fall back
    // to, otherwise what step 5 or 6 failed with. The device stays stopped until a later
    // notification lets it start (deviceAvailable).
    std::optional<Error> error;
};

// What IO-021 needs from whoever owns the engine. Called only from handle(), on its thread.
class DeviceMonitorHost {
public:
    virtual ~DeviceMonitorHost() = default;

    // State.
    // False while the device is meant to be off (offline engine, an export pausing it): then
    // notifications are ignored.
    virtual bool deviceWanted() const = 0;
    // The config the driver is started with (outputDevice 0: follow the system default).
    virtual DriverConfig requestedConfig() const = 0;
    // What the running driver resolved; zeros while it isn't running.
    virtual RunningConfig runningConfig() const = 0;
    virtual double sessionRate() const = 0;
    virtual bool recording() const = 0;

    // Devices, as they are now.
    virtual bool deviceAlive(AudioDeviceRef device) const = 0;
    virtual AudioDeviceRef defaultOutputDevice() const = 0;  // 0: none
    virtual Result<DeviceCaps> outputCaps(AudioDeviceRef device) const = 0;

    // The sequence, in order.
    virtual void stopTransport() = 0;                               // (1)
    virtual void finalizeRecordings() = 0;                          // (2), only while recording
    virtual void stopDriver() = 0;                                  // (3)
    virtual Result<void> changeSessionRate(double sampleRate) = 0;  // (5), only for a new rate
    // (6). `config` becomes the requested config, so later restarts (say, arming input) keep the
    // fallback device and the session rate.
    virtual Result<void> startDriver(const DriverConfig& config) = 0;
    virtual void deviceChanged(const DeviceSwap& change) = 0;     // (7)
};

class DeviceMonitor {
public:
    explicit DeviceMonitor(DeviceMonitorHost& host) : host_(host) {}
    DeviceMonitor(const DeviceMonitor&) = delete;
    DeviceMonitor& operator=(const DeviceMonitor&) = delete;

    // Reacts to one notification. Returns the change if it ran the sequence and reported it.
    std::optional<DeviceSwap> handle(const DeviceNotification& notification);

    // Diagnostics: sequences run (reported or not), and retries that found no device yet.
    uint64_t swaps() const { return swaps_; }
    uint64_t failedRetries() const { return failedRetries_; }

private:
    std::optional<DeviceSwapReason> trigger(const DeviceNotification& n) const;
    // `report`: whether a failed restart is reported (not for quiet retries).
    std::optional<DeviceSwap> swap(DeviceSwapReason reason, bool report);

    DeviceMonitorHost& host_;
    uint64_t swaps_ = 0;
    uint64_t failedRetries_ = 0;
};

} // namespace daw
