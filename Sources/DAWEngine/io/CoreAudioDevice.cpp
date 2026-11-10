#include "io/CoreAudioDevice.h"

#include <CoreAudio/CoreAudio.h>
#include <os/workgroup.h>

#include <chrono>
#include <cmath>
#include <memory>
#include <thread>

#include "io/CoreAudioError.h"

namespace daw {

namespace {

AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
                                   AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    return {selector, scope, kAudioObjectPropertyElementMain};
}

AudioObjectPropertyScope scopeOf(DeviceDirection direction) {
    return direction == DeviceDirection::output ? kAudioObjectPropertyScopeOutput
                                                : kAudioObjectPropertyScopeInput;
}

template <class T>
Result<T> getScalar(AudioObjectID object, const AudioObjectPropertyAddress& addr, const char* what) {
    T value{};
    UInt32 size = sizeof(T);
    const OSStatus status = AudioObjectGetPropertyData(object, &addr, 0, nullptr, &size, &value);
    if (status != noErr) return coreAudioError(status, ErrorCode::io, std::string("reading ") + what);
    return value;
}

template <class T>
Result<std::vector<T>> getArray(AudioObjectID object, const AudioObjectPropertyAddress& addr,
                                const char* what) {
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(object, &addr, 0, nullptr, &size);
    if (status != noErr) return coreAudioError(status, ErrorCode::io, std::string("sizing ") + what);
    std::vector<T> values(size / sizeof(T));
    if (values.empty()) return values;
    status = AudioObjectGetPropertyData(object, &addr, 0, nullptr, &size, values.data());
    if (status != noErr) return coreAudioError(status, ErrorCode::io, std::string("reading ") + what);
    values.resize(size / sizeof(T));
    return values;
}

} // namespace

Result<CoreAudioDevice> CoreAudioDevice::defaultDevice(DeviceDirection direction) {
    const auto addr = address(direction == DeviceDirection::output
                                  ? kAudioHardwarePropertyDefaultOutputDevice
                                  : kAudioHardwarePropertyDefaultInputDevice);
    auto id = getScalar<AudioObjectID>(kAudioObjectSystemObject, addr, "the default device");
    if (!id) return id.error();
    if (*id == kAudioObjectUnknown)
        return makeError(ErrorCode::notFound, direction == DeviceDirection::output
                                                  ? "no default output device"
                                                  : "no default input device");
    return CoreAudioDevice(*id);
}

std::vector<CoreAudioDevice> CoreAudioDevice::allDevices() {
    auto ids = getArray<AudioObjectID>(kAudioObjectSystemObject,
                                       address(kAudioHardwarePropertyDevices), "the device list");
    std::vector<CoreAudioDevice> devices;
    if (ids)
        for (AudioObjectID id : *ids) devices.emplace_back(id);
    return devices;
}

std::string CoreAudioDevice::name() const {
    auto ref = getScalar<CFStringRef>(id_, address(kAudioObjectPropertyName), "the device name");
    if (!ref || *ref == nullptr) return {};
    std::string result;
    char buffer[512];
    if (CFStringGetCString(*ref, buffer, sizeof(buffer), kCFStringEncodingUTF8)) result = buffer;
    CFRelease(*ref);
    return result;
}

bool CoreAudioDevice::isAlive() const {
    auto alive = getScalar<UInt32>(id_, address(kAudioDevicePropertyDeviceIsAlive), "IsAlive");
    return alive && *alive != 0;
}

uint32_t CoreAudioDevice::clockDomain() const {
    return getScalar<UInt32>(id_, address(kAudioDevicePropertyClockDomain), "ClockDomain").valueOr(0u);
}

bool CoreAudioDevice::isBuiltIn() const {
    const auto type = getScalar<UInt32>(id_, address(kAudioDevicePropertyTransportType), "TransportType");
    return type && *type == kAudioDeviceTransportTypeBuiltIn;
}

uint32_t CoreAudioDevice::dataSource(DeviceDirection direction) const {
    const auto addr = address(kAudioDevicePropertyDataSource, scopeOf(direction));
    if (!AudioObjectHasProperty(id_, &addr)) return 0;
    return getScalar<UInt32>(id_, addr, "DataSource").valueOr(0u);
}

uint32_t CoreAudioDevice::channels(DeviceDirection direction) const {
    const auto addr = address(kAudioDevicePropertyStreamConfiguration, scopeOf(direction));
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(id_, &addr, 0, nullptr, &size) != noErr || size == 0) return 0;
    // AudioBufferList is variable-length; allocate the size the HAL asks for.
    auto storage = std::make_unique<std::byte[]>(size);
    auto* list = reinterpret_cast<AudioBufferList*>(storage.get());
    if (AudioObjectGetPropertyData(id_, &addr, 0, nullptr, &size, list) != noErr) return 0;
    uint32_t channels = 0;
    for (UInt32 b = 0; b < list->mNumberBuffers; ++b) channels += list->mBuffers[b].mNumberChannels;
    return channels;
}

Result<DeviceCaps> CoreAudioDevice::caps(DeviceDirection direction) const {
    DeviceCaps caps;
    auto rate = nominalRate();
    if (!rate) return rate.error();
    caps.nominalRate = *rate;

    auto ranges = getArray<AudioValueRange>(id_, address(kAudioDevicePropertyAvailableNominalSampleRates),
                                            "AvailableNominalSampleRates");
    if (!ranges) return ranges.error();
    for (const AudioValueRange& r : *ranges) caps.rates.push_back({r.mMinimum, r.mMaximum});

    auto buffers = getScalar<AudioValueRange>(id_, address(kAudioDevicePropertyBufferFrameSizeRange),
                                              "BufferFrameSizeRange");
    if (!buffers) return buffers.error();
    caps.minBufferFrames = static_cast<uint32_t>(std::ceil(buffers->mMinimum));
    caps.maxBufferFrames = static_cast<uint32_t>(buffers->mMaximum);

    caps.channels = channels(direction);
    return caps;
}

Result<double> CoreAudioDevice::nominalRate() const {
    return getScalar<Float64>(id_, address(kAudioDevicePropertyNominalSampleRate), "NominalSampleRate");
}

Result<void> CoreAudioDevice::setNominalRate(double rate, double timeoutSeconds) {
    auto current = nominalRate();
    if (!current) return current.error();
    if (*current == rate) return {};
    const auto addr = address(kAudioDevicePropertyNominalSampleRate);
    const Float64 value = rate;
    const OSStatus status = AudioObjectSetPropertyData(id_, &addr, 0, nullptr, sizeof(value), &value);
    if (status != noErr)
        return coreAudioError(status, ErrorCode::io, "setting the sample rate to " + std::to_string(rate));
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::duration<double>(timeoutSeconds);
    while (std::chrono::steady_clock::now() < deadline) {
        current = nominalRate();
        if (current && *current == rate) return {};
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    return makeError(ErrorCode::io, "the device didn't switch to " + std::to_string(rate) + " Hz");
}

Result<uint32_t> CoreAudioDevice::bufferFrames() const {
    auto frames = getScalar<UInt32>(id_, address(kAudioDevicePropertyBufferFrameSize), "BufferFrameSize");
    if (!frames) return frames.error();
    return uint32_t{*frames};
}

Result<void> CoreAudioDevice::setBufferFrames(uint32_t frames) {
    const auto addr = address(kAudioDevicePropertyBufferFrameSize);
    const UInt32 value = frames;
    const OSStatus status = AudioObjectSetPropertyData(id_, &addr, 0, nullptr, sizeof(value), &value);
    if (status != noErr)
        return coreAudioError(status, ErrorCode::io, "setting the buffer size to " + std::to_string(frames));
    return {};
}

Result<LatencyComponents> CoreAudioDevice::latency(DeviceDirection direction) const {
    const AudioObjectPropertyScope scope = scopeOf(direction);
    LatencyComponents c;
    auto device = getScalar<UInt32>(id_, address(kAudioDevicePropertyLatency, scope), "Latency");
    if (!device) return device.error();
    auto safety = getScalar<UInt32>(id_, address(kAudioDevicePropertySafetyOffset, scope), "SafetyOffset");
    if (!safety) return safety.error();
    auto buffer = bufferFrames();
    if (!buffer) return buffer.error();
    c.device = *device;
    c.safetyOffset = *safety;
    c.bufferFrames = *buffer;
    // IO-005 "(+ stream latency)": the first stream of this direction; a device may have none.
    auto streams = getArray<AudioStreamID>(id_, address(kAudioDevicePropertyStreams, scope), "Streams");
    if (streams && !streams->empty())
        c.stream = getScalar<UInt32>(streams->front(), address(kAudioStreamPropertyLatency),
                                     "stream Latency").valueOr(0u);
    return c;
}

void* CoreAudioDevice::copyWorkgroup() const {
    auto workgroup = getScalar<os_workgroup_t>(id_, address(kAudioDevicePropertyIOThreadOSWorkgroup),
                                               "IOThreadOSWorkgroup");
    return workgroup ? static_cast<void*>(*workgroup) : nullptr;
}

} // namespace daw
