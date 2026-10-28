#pragma once
// IO-020 seam (TEST-005 → T-051): what the device layer reports about devices, one notification
// per HAL property change that DeviceMonitor listens to, plus processor overloads (IO-023).
// FakeDeviceDriver produces them from scripted events; a CoreAudio listener can produce the same
// from kAudioObjectPropertyListener callbacks. Plain data, so they cross threads in an SpscQueue
// (CONV-RT-05). Reacting to them (IO-021) is DeviceMonitor's job, not the producer's.

#include <cstdint>

#include "io/DriverConfig.h"

namespace daw {

enum class DeviceNotificationType : uint8_t {
    devicesChanged,        // kAudioHardwarePropertyDevices: a device appeared or disappeared
    defaultOutputChanged,  // kAudioHardwarePropertyDefaultOutputDevice: `device` is the new default (0: none)
    aliveChanged,          // kAudioDevicePropertyDeviceIsAlive of `device`: `alive`
    nominalRateChanged,    // kAudioDevicePropertyNominalSampleRate of `device`: `sampleRate`
    processorOverload,     // kAudioDeviceProcessorOverload on `device` (IO-023)
};

struct DeviceNotification {
    DeviceNotificationType type = DeviceNotificationType::devicesChanged;
    AudioDeviceRef device = 0;
    bool alive = false;     // aliveChanged
    double sampleRate = 0;  // nominalRateChanged
    // Device frames the driver had rendered when it happened (all runs; FakeDeviceDriver only).
    uint64_t frame = 0;
};

} // namespace daw
