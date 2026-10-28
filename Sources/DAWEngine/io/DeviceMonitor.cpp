#include "io/DeviceMonitor.h"

namespace daw {

std::optional<DeviceSwap> DeviceMonitor::handle(const DeviceNotification& notification) {
    const std::optional<DeviceSwapReason> reason = trigger(notification);
    if (!reason) return std::nullopt;
    // A retry with nothing running is reported only once it succeeds.
    return swap(*reason, *reason != DeviceSwapReason::deviceAvailable);
}

std::optional<DeviceSwapReason> DeviceMonitor::trigger(const DeviceNotification& n) const {
    if (n.type == DeviceNotificationType::processorOverload) return std::nullopt;  // IO-023: an xrun
    if (!host_.deviceWanted()) return std::nullopt;
    const RunningConfig running = host_.runningConfig();
    if (running.outputDevice == 0) return DeviceSwapReason::deviceAvailable;

    // Loss first: the HAL sends aliveChanged, devicesChanged and defaultOutputChanged in no
    // particular order, and whichever comes first should say "lost".
    const bool separateInput = running.separateInput && running.inputDevice != 0;
    if (!host_.deviceAlive(running.outputDevice) || (separateInput && !host_.deviceAlive(running.inputDevice)))
        return DeviceSwapReason::deviceLost;

    switch (n.type) {
    case DeviceNotificationType::nominalRateChanged: {
        const bool ours = n.device == running.outputDevice || (separateInput && n.device == running.inputDevice);
        // The rate the driver set itself on start is no change.
        if (ours && n.sampleRate > 0 && n.sampleRate != running.sampleRate)
            return DeviceSwapReason::sampleRateChanged;
        return std::nullopt;
    }
    case DeviceNotificationType::defaultOutputChanged:
        if (host_.requestedConfig().outputDevice == 0 && n.device != 0 && n.device != running.outputDevice)
            return DeviceSwapReason::defaultOutputChanged;
        return std::nullopt;
    default:
        return std::nullopt;
    }
}

std::optional<DeviceSwap> DeviceMonitor::swap(DeviceSwapReason reason, bool report) {
    ++swaps_;
    DeviceSwap change;
    change.reason = reason;
    change.previousDevice = host_.runningConfig().outputDevice;
    change.previousSessionRate = host_.sessionRate();
    const DriverConfig requested = host_.requestedConfig();

    // (1)..(3). With nothing running (deviceAvailable) there is nothing to stop.
    if (reason != DeviceSwapReason::deviceAvailable) {
        host_.stopTransport();
        if (host_.recording()) host_.finalizeRecordings();
        host_.stopDriver();
    }

    // (4) A device that is gone falls back to the system default (D-26); after a rate change or a
    // default move the request stands (the same device, or still "the default").
    DriverConfig config = requested;
    if (config.outputDevice != 0 && !host_.deviceAlive(config.outputDevice)) config.outputDevice = 0;
    if (config.inputDevice != 0 && !host_.deviceAlive(config.inputDevice)) config.inputDevice = 0;
    const AudioDeviceRef target = config.outputDevice != 0 ? config.outputDevice : host_.defaultOutputDevice();

    auto restart = [&]() -> Result<void> {
        if (target == 0) return makeError(ErrorCode::notFound, "no output device to fall back to");
        auto caps = host_.outputCaps(target);
        if (!caps) return caps.error();
        // (5) Keep the session rate if the device can run at it; otherwise take the rate it
        // runs at (its nominal rate, or the first fallback rate it supports, IO-003).
        double rate = host_.sessionRate();
        if (!supportsRate(*caps, rate)) {
            auto resolved = resolveConfig(0, config.bufferFrames, config.outputChannels, *caps);
            if (!resolved) return resolved.error();
            rate = resolved->sampleRate;
            if (auto changed = host_.changeSessionRate(rate); !changed) return changed;
        }
        config.sampleRate = rate;
        // (6)
        return host_.startDriver(config);
    };
    if (auto ok = restart(); !ok) change.error = ok.error();
    change.device = host_.runningConfig().outputDevice;
    change.sessionRate = host_.sessionRate();

    if (change.error && !report) {
        ++failedRetries_;
        return std::nullopt;
    }
    host_.deviceChanged(change);  // (7)
    return change;
}

} // namespace daw
