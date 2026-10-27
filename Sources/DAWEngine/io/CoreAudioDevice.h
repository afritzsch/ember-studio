#pragma once
// The HAL properties CoreAudioDriver needs from one audio device (IO-003..005). Non-RT; every
// getter reads the property afresh. Framework-free header (AudioObjectID is a uint32_t).

#include <cstdint>
#include <string>
#include <vector>

#include "core/Result.h"
#include "io/DeviceLatency.h"
#include "io/DriverConfig.h"

namespace daw {

enum class DeviceDirection : uint8_t { output, input };

class CoreAudioDevice {
public:
    // kAudioHardwarePropertyDefaultOutputDevice / DefaultInputDevice. notFound when there is none
    // (e.g. a headless CI machine).
    static Result<CoreAudioDevice> defaultDevice(DeviceDirection direction);
    // kAudioHardwarePropertyDevices.
    static std::vector<CoreAudioDevice> allDevices();

    explicit CoreAudioDevice(AudioDeviceRef id) : id_(id) {}
    AudioDeviceRef id() const { return id_; }

    std::string name() const;   // kAudioObjectPropertyName; empty if unreadable
    bool isAlive() const;       // kAudioDevicePropertyDeviceIsAlive
    uint32_t clockDomain() const;  // kAudioDevicePropertyClockDomain; 0 = unknown
    uint32_t channels(DeviceDirection direction) const;  // kAudioDevicePropertyStreamConfiguration

    // IO-003: rates, buffer range and channels of one direction.
    Result<DeviceCaps> caps(DeviceDirection direction) const;
    Result<double> nominalRate() const;
    // Sets kAudioDevicePropertyNominalSampleRate and waits (up to `timeoutSeconds`) until the
    // device reports it: the change is asynchronous. No-op when it is already the rate.
    Result<void> setNominalRate(double rate, double timeoutSeconds = 2.0);
    Result<uint32_t> bufferFrames() const;
    Result<void> setBufferFrames(uint32_t frames);

    // IO-005: the latency properties of one direction, with the current buffer size.
    Result<LatencyComponents> latency(DeviceDirection direction) const;

    // IO-002: kAudioDevicePropertyIOThreadOSWorkgroup, as a retained os_workgroup_t the caller
    // releases (WorkgroupJoin::attach takes it over). Null when the device has none.
    void* copyWorkgroup() const;

private:
    AudioDeviceRef id_;
};

} // namespace daw
