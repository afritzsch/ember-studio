#include "io/CoreAudioDriver.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <os/log.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstring>
#include <optional>
#include <thread>
#include <vector>

#include "core/Engine.h"
#include "core/Node.h"
#include "io/CoreAudioDevice.h"
#include "io/CoreAudioError.h"
#include "io/DeviceRenderer.h"
#include "io/InputFifo.h"
#include "io/WorkgroupJoin.h"

namespace daw {

namespace {

// AUHAL never asks for more than this per cycle (kAudioUnitProperty_MaximumFramesPerSlice), so the
// input scratch buffers can be sized once.
constexpr uint32_t kMaxCycleFrames = kMaxBlock;

os_log_t ioLog() {
    static os_log_t log = os_log_create("dev.emberstudio", "io");  // CONV §4
    return log;
}

Result<void> check(OSStatus status, const char* what) {
    if (status == noErr) return {};
    return coreAudioError(status, ErrorCode::io, what);
}

// 32-bit float, non-interleaved: what Engine::render reads and writes (ENG-003).
AudioStreamBasicDescription floatFormat(double rate, uint32_t channels) {
    AudioStreamBasicDescription format{};
    format.mSampleRate = rate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags =
        static_cast<AudioFormatFlags>(kAudioFormatFlagsNativeFloatPacked) | kAudioFormatFlagIsNonInterleaved;
    format.mBytesPerPacket = sizeof(float);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = sizeof(float);
    format.mChannelsPerFrame = channels;
    format.mBitsPerChannel = 32;
    return format;
}

template <class T>
Result<void> setProperty(AudioUnit unit, AudioUnitPropertyID id, AudioUnitScope scope,
                         AudioUnitElement element, const T& value, const char* what) {
    return check(AudioUnitSetProperty(unit, id, scope, element, &value, sizeof(T)), what);
}

Result<AudioUnit> makeHalUnit() {
    const AudioComponentDescription description{kAudioUnitType_Output, kAudioUnitSubType_HALOutput,
                                                kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(nullptr, &description);
    if (component == nullptr) return makeError(ErrorCode::notFound, "no AUHAL output unit");
    AudioUnit unit = nullptr;
    if (auto ok = check(AudioComponentInstanceNew(component, &unit), "creating the AUHAL unit"); !ok)
        return ok.error();
    return unit;
}

// AUHAL elements: 0 is the output (to the device), 1 the input (from it).
constexpr AudioUnitElement kOutputElement = 0;
constexpr AudioUnitElement kInputElement = 1;

// Non-interleaved scratch audio for one direction: channels × kMaxCycleFrames, and an
// AudioBufferList over it for AudioUnitRender. Allocated before the units start.
class ScratchBuffers {
public:
    void allocate(uint32_t channels) {
        channels_ = channels;
        storage_.assign(std::size_t{channels} * kMaxCycleFrames, 0.0f);
        pointers_.resize(channels);
        for (uint32_t c = 0; c < channels; ++c) pointers_[c] = storage_.data() + std::size_t{c} * kMaxCycleFrames;
        list_.resize(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * std::max(channels, 1u));
    }

    uint32_t numChannels() const DAW_RT { return channels_; }
    float* const* channels() const DAW_RT { return pointers_.data(); }

    // IO thread. AudioUnitRender may repoint or resize the buffers, so they are reset every cycle.
    AudioBufferList* list(uint32_t frames) DAW_RT {
        auto* list = reinterpret_cast<AudioBufferList*>(list_.data());
        list->mNumberBuffers = channels_;
        for (uint32_t c = 0; c < channels_; ++c)
            list->mBuffers[c] = {1, static_cast<UInt32>(frames * sizeof(float)), pointers_[c]};
        return list;
    }

    void clear(uint32_t frames) DAW_RT {
        for (uint32_t c = 0; c < channels_; ++c) std::memset(pointers_[c], 0, frames * sizeof(float));
    }

private:
    uint32_t channels_ = 0;
    std::vector<float> storage_;
    std::vector<float*> pointers_;
    std::vector<std::byte> list_;  // an AudioBufferList; operator new aligns it well enough
};

} // namespace

struct CoreAudioDriver::Impl {
    explicit Impl(Engine& e) : engine(e), renderer(e) {}

    Engine& engine;
    DeviceRenderer renderer;
    WorkgroupJoin workgroup;
    InputFifo fifo;
    ScratchBuffers input;     // the cycle's input: pulled from the output unit, or from the FIFO
    ScratchBuffers captured;  // separate input device: what its IO thread renders into the FIFO

    AudioUnit outputUnit = nullptr;
    AudioUnit inputUnit = nullptr;  // separate input device only
    bool inputOnOutputUnit = false;
    uint32_t maxBacklog = 0;
    AudioDeviceRef listenerDevice = 0;

    bool running = false;
    RunningConfig config;
    DeviceLatency latency;
    std::atomic<uint64_t> inputErrors{0};
    std::atomic<uint64_t> overloads{0};

    Result<void> open(const DriverConfig& request);
    void close();

    // AURenderCallbacks, which the SDK declares nonblocking (CA_REALTIME_API).
    static OSStatus render(void* ref, AudioUnitRenderActionFlags* flags, const AudioTimeStamp* time,
                           UInt32 bus, UInt32 frames, AudioBufferList* io) DAW_RT;
    static OSStatus capture(void* ref, AudioUnitRenderActionFlags* flags, const AudioTimeStamp* time,
                            UInt32 bus, UInt32 frames, AudioBufferList* io) DAW_RT;
    static OSStatus overload(AudioObjectID device, UInt32 count,
                             const AudioObjectPropertyAddress* addresses, void* ref);
};

namespace {
constexpr AudioObjectPropertyAddress kOverloadAddress{
    kAudioDeviceProcessorOverload, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
}

// IO-001: the output IO cycle, on the output device's IO thread (daw.audio). Pulling input and
// joining the workgroup happen outside Engine's RtScope; DeviceRenderer::renderCycle opens it.
OSStatus CoreAudioDriver::Impl::render(void* ref, AudioUnitRenderActionFlags* flags,
                                       const AudioTimeStamp* time, UInt32, UInt32 frames,
                                       AudioBufferList* io) DAW_RT {
    auto& self = *static_cast<Impl*>(ref);
    // IO-002: join on the first cycle; after stop() asked to leave, render nothing more.
    if (!self.workgroup.onCycle() || frames > kMaxCycleFrames) {
        for (UInt32 b = 0; b < io->mNumberBuffers; ++b)
            std::memset(io->mBuffers[b].mData, 0, io->mBuffers[b].mDataByteSize);
        *flags |= kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }

    float* output[kMaxDeviceChannels];
    const uint32_t numOutput = std::min<uint32_t>(io->mNumberBuffers, kMaxDeviceChannels);
    for (uint32_t b = 0; b < numOutput; ++b) output[b] = static_cast<float*>(io->mBuffers[b].mData);
    for (UInt32 b = numOutput; b < io->mNumberBuffers; ++b)
        std::memset(io->mBuffers[b].mData, 0, io->mBuffers[b].mDataByteSize);

    uint32_t numInput = 0;
    if (self.inputOnOutputUnit) {
        AudioUnitRenderActionFlags inputFlags = 0;
        if (AudioUnitRender(self.outputUnit, &inputFlags, time, kInputElement, frames,
                            self.input.list(frames)) != noErr) {
            self.input.clear(frames);
            self.inputErrors.fetch_add(1, std::memory_order_relaxed);
        }
        numInput = self.input.numChannels();
    } else if (self.inputUnit != nullptr) {
        // IO-004: the input device's IO thread filled the FIFO.
        self.fifo.pull(self.input.channels(), self.input.numChannels(), frames, self.maxBacklog);
        numInput = self.input.numChannels();
    }

    self.renderer.renderCycle(output, numOutput, self.input.channels(), numInput, frames);
    return noErr;
}

// IO-004: the separate input device's IO cycle. Renders its input into the FIFO.
OSStatus CoreAudioDriver::Impl::capture(void* ref, AudioUnitRenderActionFlags* flags,
                                        const AudioTimeStamp* time, UInt32 bus, UInt32 frames,
                                        AudioBufferList*) DAW_RT {
    auto& self = *static_cast<Impl*>(ref);
    if (frames > kMaxCycleFrames ||
        AudioUnitRender(self.inputUnit, flags, time, bus, frames, self.captured.list(frames)) != noErr) {
        self.inputErrors.fetch_add(1, std::memory_order_relaxed);
        return noErr;
    }
    self.fifo.write(self.captured.channels(), self.captured.numChannels(), frames);
    return noErr;
}

// IO-023 (DW-049): a HAL notification thread, not the IO thread.
OSStatus CoreAudioDriver::Impl::overload(AudioObjectID, UInt32 count,
                                         const AudioObjectPropertyAddress* addresses, void* ref) {
    auto& self = *static_cast<Impl*>(ref);
    for (UInt32 i = 0; i < count; ++i)
        if (addresses[i].mSelector == kAudioDeviceProcessorOverload) {
            self.engine.telemetry().countXrun();
            self.overloads.fetch_add(1, std::memory_order_relaxed);
        }
    return noErr;
}

Result<void> CoreAudioDriver::Impl::open(const DriverConfig& request) {
    // IO-003: the output device and what it can do.
    std::optional<CoreAudioDevice> out;
    if (request.outputDevice != 0) {
        out.emplace(request.outputDevice);
    } else {
        auto device = CoreAudioDevice::defaultDevice(DeviceDirection::output);
        if (!device) return device.error();
        out = *device;
    }
    if (!out->isAlive()) return makeError(ErrorCode::notFound, "the output device is gone");
    auto outCaps = out->caps(DeviceDirection::output);
    if (!outCaps) return outCaps.error();
    auto resolved = resolveConfig(request.sampleRate, request.bufferFrames, request.outputChannels, *outCaps);
    if (!resolved) return resolved.error();
    const double rate = resolved->sampleRate;

    // IO-004: input from the requested device only if it shares the output's clock. A device
    // without input channels (say, built-in speakers chosen as the fallback) means no input.
    std::optional<CoreAudioDevice> in;
    ResolvedConfig inResolved;
    if (request.inputEnabled) {
        AudioDeviceRef requested = request.inputDevice;
        if (requested == 0)
            if (auto device = CoreAudioDevice::defaultDevice(DeviceDirection::input)) requested = device->id();
        const uint32_t requestedDomain = requested != 0 ? CoreAudioDevice(requested).clockDomain() : 0;
        const CoreAudioDevice candidate(chooseInputDevice(out->id(), out->clockDomain(), requested, requestedDomain));
        if (candidate.channels(DeviceDirection::input) > 0) {
            auto inCaps = candidate.caps(DeviceDirection::input);
            if (!inCaps) return inCaps.error();
            auto r = resolveConfig(rate, resolved->bufferFrames, request.inputChannels, *inCaps);
            if (!r) return r.error();
            in = candidate;
            inResolved = *r;
        }
    }
    const bool separate = in && in->id() != out->id();

    // IO-003: switch the device(s) to the session rate and buffer size.
    if (auto ok = out->setNominalRate(rate); !ok) return ok;
    if (auto ok = out->setBufferFrames(resolved->bufferFrames); !ok) return ok;
    if (separate) {
        if (auto ok = in->setNominalRate(rate); !ok) return ok;
        if (auto ok = in->setBufferFrames(inResolved.bufferFrames); !ok) return ok;
    }

    // Scratch and FIFO first: the units may call back as soon as they start.
    renderer.configure(resolved->bufferFrames);
    if (in) input.allocate(inResolved.channels);
    if (separate) {
        captured.allocate(inResolved.channels);
        if (auto ok = fifo.configure(inResolved.channels, 4 * kMaxCycleFrames); !ok) return ok;
        // The FIFO may hold up to two device buffers beyond the cycle; more is dropped.
        maxBacklog = 2 * std::max(resolved->bufferFrames, inResolved.bufferFrames);
    }

    // IO-001: the AUHAL output unit. EnableIO must precede CurrentDevice.
    auto unit = makeHalUnit();
    if (!unit) return unit.error();
    outputUnit = *unit;
    inputOnOutputUnit = in && !separate;
    const UInt32 enable = 1, disable = 0;
    const UInt32 maxFrames = kMaxCycleFrames;
    const AudioDeviceID outID = out->id();
    if (inputOnOutputUnit)
        if (auto ok = setProperty(outputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                                  kInputElement, enable, "enabling input"); !ok) return ok;
    if (auto ok = setProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                              0, outID, "selecting the output device"); !ok) return ok;
    if (auto ok = setProperty(outputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                              kOutputElement, floatFormat(rate, resolved->channels),
                              "setting the output format"); !ok) return ok;
    if (inputOnOutputUnit)
        if (auto ok = setProperty(outputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                                  kInputElement, floatFormat(rate, inResolved.channels),
                                  "setting the input format"); !ok) return ok;
    if (auto ok = setProperty(outputUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global,
                              0, maxFrames, "setting the maximum cycle"); !ok) return ok;
    const AURenderCallbackStruct renderCallback{&Impl::render, this};
    if (auto ok = setProperty(outputUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                              kOutputElement, renderCallback, "setting the render callback"); !ok) return ok;
    if (auto ok = check(AudioUnitInitialize(outputUnit), "initializing the output unit"); !ok) return ok;

    // IO-004: a second AUHAL unit, input only, on the separate input device.
    if (separate) {
        auto inputUnitResult = makeHalUnit();
        if (!inputUnitResult) return inputUnitResult.error();
        inputUnit = *inputUnitResult;
        const AudioDeviceID inID = in->id();
        if (auto ok = setProperty(inputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                                  kInputElement, enable, "enabling input"); !ok) return ok;
        if (auto ok = setProperty(inputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
                                  kOutputElement, disable, "disabling output"); !ok) return ok;
        if (auto ok = setProperty(inputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                  0, inID, "selecting the input device"); !ok) return ok;
        if (auto ok = setProperty(inputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                                  kInputElement, floatFormat(rate, inResolved.channels),
                                  "setting the input format"); !ok) return ok;
        if (auto ok = setProperty(inputUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global,
                                  0, maxFrames, "setting the maximum cycle"); !ok) return ok;
        const AURenderCallbackStruct inputCallback{&Impl::capture, this};
        if (auto ok = setProperty(inputUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global,
                                  0, inputCallback, "setting the input callback"); !ok) return ok;
        if (auto ok = check(AudioUnitInitialize(inputUnit), "initializing the input unit"); !ok) return ok;
    }

    // IO-002: the IO thread joins this on its first cycle.
    workgroup.attach(out->copyWorkgroup());

    // IO-005: from the properties, now that rate and buffer size are set.
    auto outLatency = out->latency(DeviceDirection::output);
    if (!outLatency) return outLatency.error();
    latency = {};
    latency.output = totalLatency(*outLatency);
    if (in) {
        auto inLatency = in->latency(DeviceDirection::input);
        if (!inLatency) return inLatency.error();
        latency.input = totalLatency(*inLatency);
    }
    publishDeviceLatency(engine, latency);

    // IO-023 (DW-049): CPU overloads count as xruns. A failure here only costs the counter.
    if (AudioObjectAddPropertyListener(outID, &kOverloadAddress, &Impl::overload, this) == noErr)
        listenerDevice = outID;

    config = {};
    config.outputDevice = outID;
    config.inputDevice = in ? in->id() : 0;
    config.separateInput = separate;
    config.sampleRate = rate;
    config.bufferFrames = resolved->bufferFrames;
    config.outputChannels = resolved->channels;
    config.inputChannels = in ? inResolved.channels : 0;

    // The input first, so the FIFO is filling by the time the output cycle reads it.
    if (inputUnit != nullptr)
        if (auto ok = check(AudioOutputUnitStart(inputUnit), "starting the input unit"); !ok) return ok;
    if (auto ok = check(AudioOutputUnitStart(outputUnit), "starting the output unit"); !ok) return ok;

    os_log_info(ioLog(), "CoreAudioDriver started: output %u, input %u%s, %.0f Hz, %u frames, latency in %u out %u",
                config.outputDevice, config.inputDevice, separate ? " (separate)" : "", rate,
                config.bufferFrames, latency.input, latency.output);
    return {};
}

void CoreAudioDriver::Impl::close() {
    if (listenerDevice != 0) {
        AudioObjectRemovePropertyListener(listenerDevice, &kOverloadAddress, &Impl::overload, this);
        listenerDevice = 0;
    }
    for (AudioUnit* unit : {&outputUnit, &inputUnit}) {
        if (*unit == nullptr) continue;
        AudioOutputUnitStop(*unit);
        AudioUnitUninitialize(*unit);
        AudioComponentInstanceDispose(*unit);
        *unit = nullptr;
    }
    inputOnOutputUnit = false;
    fifo.reset();
    config = {};
    latency = {};
}

CoreAudioDriver::CoreAudioDriver(Engine& engine) : impl_(std::make_unique<Impl>(engine)) {}

CoreAudioDriver::~CoreAudioDriver() { stop(); }

Result<void> CoreAudioDriver::start(const DriverConfig& config) {
    if (impl_->running) return makeError(ErrorCode::invalidArgument, "the driver is already running");
    auto ok = impl_->open(config);
    if (!ok) {
        impl_->close();
        os_log_error(ioLog(), "CoreAudioDriver failed to start: %{public}s", ok.error().message.c_str());
        return ok;
    }
    impl_->running = true;
    return {};
}

void CoreAudioDriver::stop() {
    if (!impl_->running) return;
    // IO-002: the IO thread leaves the workgroup itself, at its next cycle; from then on it
    // renders nothing. A device that has stopped calling back doesn't hold this up for long.
    impl_->workgroup.requestLeave();
    const double cycleSeconds = impl_->config.bufferFrames / impl_->config.sampleRate;
    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::duration<double>(std::max(0.1, 8 * cycleSeconds));
    while (!impl_->workgroup.leaveDone() && std::chrono::steady_clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    // AudioOutputUnitStop returns after the IO proc's current cycle, so Engine::render is no
    // longer called either way.
    impl_->close();
    impl_->running = false;
}

DeviceLatency CoreAudioDriver::latency() const { return impl_->latency; }
bool CoreAudioDriver::running() const { return impl_->running; }
const RunningConfig& CoreAudioDriver::current() const { return impl_->config; }
const DeviceRenderer& CoreAudioDriver::renderer() const { return impl_->renderer; }
const WorkgroupJoin& CoreAudioDriver::workgroup() const { return impl_->workgroup; }
const InputFifo& CoreAudioDriver::inputFifo() const { return impl_->fifo; }
uint64_t CoreAudioDriver::inputErrors() const { return impl_->inputErrors.load(std::memory_order_relaxed); }
uint64_t CoreAudioDriver::overloads() const { return impl_->overloads.load(std::memory_order_relaxed); }

} // namespace daw
