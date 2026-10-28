#pragma once
// IO-020, DW-090: the HAL property listeners DeviceMonitor needs, turned into the same
// io/DeviceNotification.h notifications FakeDeviceDriver produces, so DeviceMonitor reads either
// source. System-wide it listens to kAudioHardwarePropertyDevices and
// kAudioHardwarePropertyDefaultOutputDevice; on the watched devices (the ones the driver runs on)
// to kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate and
// kAudioDeviceProcessorOverload (IO-023; CoreAudioDriver counts those as xruns itself).
//
// HAL listener callbacks run on HAL notification threads, never the IO thread. Each reads the
// property's new value there and queues a notification; it never calls anything else, so no
// reaction (IO-021) happens on a HAL thread either. DeviceNotification::frame is always 0.
//
// Threads: start/stop/watch from one non-RT thread at a time; pollNotifications from one consumer;
// waitForNotification from that consumer too.

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory>

#include "core/Result.h"
#include "io/DeviceNotification.h"
#include "io/DriverConfig.h"

namespace daw {

class CoreAudioDeviceListener {
public:
    static constexpr std::size_t kNotificationCapacity = 256;

    CoreAudioDeviceListener();
    ~CoreAudioDeviceListener();  // stops
    CoreAudioDeviceListener(const CoreAudioDeviceListener&) = delete;
    CoreAudioDeviceListener& operator=(const CoreAudioDeviceListener&) = delete;

    // Adds the system-object listeners. io error if the HAL refuses one (nothing stays added).
    // No-op while started.
    Result<void> start();
    // Removes every listener, the watched devices' too. Queued notifications stay.
    void stop();
    bool started() const;

    // Listens to `output` and `input` (0: none; the same device once) instead of the devices
    // watched before. Works whether or not start() was called. A device the HAL refuses (say, it
    // is already gone) isn't watched; watching() says which are.
    void watch(AudioDeviceRef output, AudioDeviceRef input = 0);
    bool watching(AudioDeviceRef device) const;

    // Moves up to `max` queued notifications into `out`, oldest first. The queue holds
    // kNotificationCapacity; more are dropped and counted.
    std::size_t pollNotifications(DeviceNotification* out, std::size_t max);
    // True once a notification is queued (immediately if one is), false on timeout.
    bool waitForNotification(std::chrono::milliseconds timeout);
    uint64_t droppedNotifications() const;

private:
    struct Impl;  // keeps CoreAudio out of this header
    std::unique_ptr<Impl> impl_;
};

} // namespace daw
