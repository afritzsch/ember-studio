#include "io/DriverConfig.h"

#include <algorithm>
#include <string>

namespace daw {

bool isSessionRate(double rate) {
    return std::find(std::begin(kSessionRates), std::end(kSessionRates), rate) !=
           std::end(kSessionRates);
}

bool supportsRate(const DeviceCaps& caps, double rate) {
    if (caps.rates.empty()) return rate == caps.nominalRate;  // a device that lists nothing
    return std::any_of(caps.rates.begin(), caps.rates.end(), [rate](const SampleRateRange& r) {
        return rate >= r.minimum && rate <= r.maximum;
    });
}

Result<ResolvedConfig> resolveConfig(double requestedRate, uint32_t requestedBuffer,
                                     uint32_t requestedChannels, const DeviceCaps& caps) {
    if (requestedBuffer < kMinDeviceBuffer || requestedBuffer > kMaxDeviceBuffer)
        return makeError(ErrorCode::invalidArgument,
                         "buffer size " + std::to_string(requestedBuffer) + " is outside 32...2048");
    if (requestedRate != 0 && !isSessionRate(requestedRate))
        return makeError(ErrorCode::invalidArgument,
                         "sample rate " + std::to_string(requestedRate) +
                             " is not 44.1, 48, 88.2 or 96 kHz");
    if (requestedChannels == 0)
        return makeError(ErrorCode::invalidArgument, "no channels requested");
    if (caps.channels == 0)
        return makeError(ErrorCode::unsupported, "the device has no channels in this direction");

    ResolvedConfig resolved;
    if (requestedRate != 0) {
        if (!supportsRate(caps, requestedRate))
            return makeError(ErrorCode::unsupported, "the device doesn't support " +
                                                         std::to_string(requestedRate) + " Hz");
        resolved.sampleRate = requestedRate;
    } else if (isSessionRate(caps.nominalRate)) {
        resolved.sampleRate = caps.nominalRate;  // IO-003 default
    } else {
        for (double rate : kFallbackRates)
            if (supportsRate(caps, rate)) {
                resolved.sampleRate = rate;
                break;
            }
        if (resolved.sampleRate == 0)
            return makeError(ErrorCode::unsupported, "the device supports no session rate");
    }

    resolved.bufferFrames = requestedBuffer;
    if (caps.maxBufferFrames != 0)
        resolved.bufferFrames = std::clamp(requestedBuffer, std::min(caps.minBufferFrames, caps.maxBufferFrames),
                                           caps.maxBufferFrames);
    resolved.channels = std::min({requestedChannels, caps.channels, kMaxDeviceChannels});
    return resolved;
}

AudioDeviceRef chooseInputDevice(AudioDeviceRef output, uint32_t outputClockDomain,
                                 AudioDeviceRef input, uint32_t inputClockDomain) {
    if (input == 0 || input == output) return output;
    // IO-004: clock domain 0 means "unknown", which can't be assumed shared.
    const bool sharedClock = outputClockDomain != 0 && outputClockDomain == inputClockDomain;
    return sharedClock ? input : output;
}

} // namespace daw
