#include "facade/DriverAdapter.h"

#include <utility>

#include "io/CoreAudioDevice.h"
#include "io/CoreAudioDriver.h"
#include "io/DeviceRenderer.h"

namespace daw {

namespace {

// CoreAudioDriver (IO-001..005) as a DriverAdapter. The driver is made on the first start(),
// once the engine it renders exists. IO-020: the device listener starts with it and watches the
// device(s) of every run.
class CoreAudioDriverAdapter final : public DriverAdapter {
public:
    Result<void> start(Engine& engine, const DriverConfig& config) override {
        if (!driver_ || engine_ != &engine) {
            countRetired();
            driver_.reset();
            driver_ = std::make_unique<CoreAudioDriver>(engine);
            engine_ = &engine;
        }
        // Without the system listeners device changes go unnoticed, but the device still plays.
        if (!listener_.started()) (void)listener_.start();
        auto started = driver_->start(config);
        if (started) listener_.watch(driver_->current().outputDevice, driver_->current().inputDevice);
        return started;
    }
    void stop() override {
        if (driver_) driver_->stop();
    }
    bool running() const override { return driver_ && driver_->running(); }
    RunningConfig current() const override { return driver_ ? driver_->current() : RunningConfig{}; }

    bool deviceAlive(AudioDeviceRef device) const override { return CoreAudioDevice(device).isAlive(); }
    AudioDeviceRef defaultOutputDevice() const override {
        auto device = CoreAudioDevice::defaultDevice(DeviceDirection::output);
        return device ? device->id() : 0;
    }
    Result<DeviceCaps> outputCaps(AudioDeviceRef device) const override {
        return CoreAudioDevice(device).caps(DeviceDirection::output);
    }
    std::size_t pollNotifications(DeviceNotification* out, std::size_t max) override {
        return listener_.pollNotifications(out, max);
    }
    uint64_t processorOverloads() const override {
        return retiredOverloads_ + (driver_ ? driver_->overloads() : 0);
    }
    uint64_t renderOverruns() const override {
        return retiredOverruns_ + (driver_ ? driver_->renderer().overruns() : 0);
    }
    double sampleRate() const override { return driver_ ? driver_->current().sampleRate : 0; }
    uint32_t bufferFrames() const override { return driver_ ? driver_->current().bufferFrames : 0; }

    std::vector<DeviceInfoPOD> devices() const override {
        AudioDeviceRef defaultOutput = 0;
        if (auto device = CoreAudioDevice::defaultDevice(DeviceDirection::output)) defaultOutput = device->id();
        std::vector<DeviceInfoPOD> out;
        for (const CoreAudioDevice& device : CoreAudioDevice::allDevices()) {
            DeviceInfoPOD info;
            info.deviceID = device.id();
            info.name = device.name();
            info.inputChannels = device.channels(DeviceDirection::input);
            info.outputChannels = device.channels(DeviceDirection::output);
            info.nominalSampleRate = device.nominalRate().valueOr(0.0);
            info.isDefaultOutput = device.id() == defaultOutput;
            out.push_back(std::move(info));
        }
        return out;
    }

private:
    void countRetired() {
        if (!driver_) return;
        retiredOverloads_ += driver_->overloads();
        retiredOverruns_ += driver_->renderer().overruns();
    }

    Engine* engine_ = nullptr;
    CoreAudioDeviceListener listener_;
    std::unique_ptr<CoreAudioDriver> driver_;  // destroyed (stopped) before the engine: the facade
                                               // destroys its adapter first
    uint64_t retiredOverloads_ = 0;            // of drivers made for an earlier engine
    uint64_t retiredOverruns_ = 0;
};

} // namespace

std::unique_ptr<DriverAdapter> makeDefaultDriverAdapter() { return std::make_unique<CoreAudioDriverAdapter>(); }

FakeDeviceSpec defaultFakeDeviceSpec() {
    FakeDeviceSpec spec;
    FakeDevice a;
    a.id = 1;
    a.name = "Fake Device A";
    FakeDevice b;
    b.id = 2;
    b.name = "Fake Device B";
    b.output = DeviceCaps{44100.0, {{44100, 44100}}, 32, 2048, 2};
    b.input = b.output;
    spec.devices = {a, b};
    spec.pacing = FakePacing::realtime;
    return spec;
}

FakeDeviceDriverAdapter::FakeDeviceDriverAdapter(FakeDeviceSpec spec) : spec_(std::move(spec)) {}

FakeDeviceDriverAdapter::~FakeDeviceDriverAdapter() = default;  // the driver stops itself

Result<void> FakeDeviceDriverAdapter::start(Engine& engine, const DriverConfig& config) {
    if (!owned_ || engine_ != &engine) {
        if (owned_ && owned_->running()) return makeError(ErrorCode::invalidArgument, "the driver is already running");
        driver_.store(nullptr, std::memory_order_release);
        owned_ = std::make_unique<FakeDeviceDriver>(engine, spec_);
        engine_ = &engine;
        driver_.store(owned_.get(), std::memory_order_release);
    }
    return owned_->start(config);
}

void FakeDeviceDriverAdapter::stop() {
    if (owned_) owned_->stop();
}

bool FakeDeviceDriverAdapter::running() const { return owned_ && owned_->running(); }
double FakeDeviceDriverAdapter::sampleRate() const { return owned_ ? owned_->current().sampleRate : 0; }
uint32_t FakeDeviceDriverAdapter::bufferFrames() const { return owned_ ? owned_->current().bufferFrames : 0; }

std::vector<FakeDeviceState> FakeDeviceDriverAdapter::states() const {
    if (owned_) return owned_->devices();
    // Not started yet: the devices as the spec makes them.
    std::vector<FakeDeviceState> states;
    for (const FakeDevice& device : spec_.devices)
        states.push_back({device.id, device.name, device.input.channels, device.output.channels,
                          device.output.nominalRate, true});
    return states;
}

AudioDeviceRef FakeDeviceDriverAdapter::defaultOutputDevice() const {
    if (owned_) return owned_->defaultOutput();
    return spec_.defaultOutput != 0 ? spec_.defaultOutput : (spec_.devices.empty() ? 0 : spec_.devices[0].id);
}

std::vector<DeviceInfoPOD> FakeDeviceDriverAdapter::devices() const {
    const AudioDeviceRef defaultOutput = defaultOutputDevice();
    std::vector<DeviceInfoPOD> out;
    for (const FakeDeviceState& state : states()) {
        if (!state.alive) continue;  // a lost device is gone from the list
        DeviceInfoPOD info;
        info.deviceID = state.id;
        info.name = state.name;
        info.inputChannels = state.inputChannels;
        info.outputChannels = state.outputChannels;
        info.nominalSampleRate = state.nominalRate;
        info.isDefaultOutput = state.id == defaultOutput;
        out.push_back(std::move(info));
    }
    return out;
}

} // namespace daw

namespace daw {

RunningConfig FakeDeviceDriverAdapter::current() const {
    return owned_ && owned_->running() ? owned_->current() : RunningConfig{};
}

bool FakeDeviceDriverAdapter::deviceAlive(AudioDeviceRef device) const {
    for (const FakeDeviceState& state : states())
        if (state.id == device) return state.alive;
    return false;
}

Result<DeviceCaps> FakeDeviceDriverAdapter::outputCaps(AudioDeviceRef device) const {
    for (const FakeDeviceState& state : states())
        if (state.id == device)
            for (const FakeDevice& spec : spec_.devices)
                if (spec.id == device) {
                    DeviceCaps caps = spec.output;
                    caps.nominalRate = state.nominalRate;  // events move it
                    return caps;
                }
    return makeError(ErrorCode::notFound, "no such fake device");
}

std::size_t FakeDeviceDriverAdapter::pollNotifications(DeviceNotification* out, std::size_t max) {
    return owned_ ? owned_->pollNotifications(out, max) : 0;
}

uint64_t FakeDeviceDriverAdapter::processorOverloads() const { return owned_ ? owned_->overloads() : 0; }
uint64_t FakeDeviceDriverAdapter::renderOverruns() const { return owned_ ? owned_->renderer().overruns() : 0; }

Result<void> FakeDeviceDriverAdapter::simulate(const FakeDeviceEvent& event) {
    if (!owned_) return makeError(ErrorCode::invalidArgument, "the fake device driver hasn't started yet");
    return owned_->inject(event);
}

} // namespace daw
