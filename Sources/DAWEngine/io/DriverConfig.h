#pragma once
// IO-003/IO-004: what a device driver is asked to run with, and how a request is resolved against
// what the device can do. Device-independent, so it is tested without hardware; CoreAudioDriver
// fills DeviceCaps from the HAL (CoreAudioDevice) and a fake driver (T-050) can make them up.

#include <cstdint>
#include <vector>

#include "core/Result.h"

namespace daw {

// An AudioObjectID. 0 (kAudioObjectUnknown) means "the system default".
using AudioDeviceRef = uint32_t;

// IO-003: buffer sizes the driver accepts, and the session rates.
inline constexpr uint32_t kMinDeviceBuffer = 32;
inline constexpr uint32_t kMaxDeviceBuffer = 2048;
inline constexpr uint32_t kDefaultDeviceBuffer = 256;
inline constexpr double kSessionRates[] = {44100.0, 48000.0, 88200.0, 96000.0};
// When the device's nominal rate isn't a session rate, the first of these it supports is used.
inline constexpr double kFallbackRates[] = {48000.0, 44100.0, 96000.0, 88200.0};

// The driver's view of the device's channels is capped here, so the IO cycle can hold its channel
// pointers on the stack.
inline constexpr uint32_t kMaxDeviceChannels = 32;

struct DriverConfig {
    AudioDeviceRef outputDevice = 0;  // 0: system default output
    AudioDeviceRef inputDevice = 0;   // 0: system default input (IO-004 may replace it)
    // IO-001: input runs only while recording or monitoring is armed.
    bool inputEnabled = false;
    double sampleRate = 0;            // IO-003: 0 = the device's nominal rate
    uint32_t bufferFrames = kDefaultDeviceBuffer;
    // The first N device channels; fewer if the device has fewer.
    uint32_t outputChannels = 2;
    uint32_t inputChannels = 2;
};

struct SampleRateRange {
    double minimum = 0;
    double maximum = 0;
};

// What a device reports for one direction.
struct DeviceCaps {
    double nominalRate = 0;
    std::vector<SampleRateRange> rates;  // kAudioDevicePropertyAvailableNominalSampleRates
    uint32_t minBufferFrames = 0;        // kAudioDevicePropertyBufferFrameSizeRange
    uint32_t maxBufferFrames = 0;
    uint32_t channels = 0;               // in this direction's streams
};

struct ResolvedConfig {
    double sampleRate = 0;
    uint32_t bufferFrames = 0;
    uint32_t channels = 0;
};

bool isSessionRate(double rate);
bool supportsRate(const DeviceCaps& caps, double rate);

// IO-003. Fails with invalidArgument when the request is out of range (buffer outside 32…2048, a
// rate other than a session rate, no channels) and with unsupported when the device can't do the
// requested rate or has no channels in this direction. A request of rate 0 takes the nominal rate
// if it is a session rate, else the first fallback rate the device supports. The buffer size is
// clamped to the device's range (e.g. a Bluetooth minimum); the result says what it became.
Result<ResolvedConfig> resolveConfig(double requestedRate, uint32_t requestedBuffer,
                                     uint32_t requestedChannels, const DeviceCaps& caps);

// IO-004: the device input is read from. A separate input device needs a clock shared with the
// output (the same non-zero kAudioDevicePropertyClockDomain); otherwise input = output device.
// `input` 0 (no input device, or none requested) also gives the output device.
AudioDeviceRef chooseInputDevice(AudioDeviceRef output, uint32_t outputClockDomain,
                                 AudioDeviceRef input, uint32_t inputClockDomain);

} // namespace daw
