#include "facade/DriverAdapter.h"

#include <utility>

#include "io/CoreAudioDevice.h"
#include "io/CoreAudioDriver.h"

namespace daw {

namespace {

// CoreAudioDriver (IO-001..005) as a DriverAdapter. The driver is made on the first start(),
// once the engine it renders exists.
class CoreAudioDriverAdapter final : public DriverAdapter {
public:
    Result<void> start(Engine& engine, const DriverConfig& config) override {
        if (!driver_ || engine_ != &engine) {
            driver_.reset();
            driver_ = std::make_unique<CoreAudioDriver>(engine);
            engine_ = &engine;
        }
        return driver_->start(config);
    }
    void stop() override {
        if (driver_) driver_->stop();
    }
    bool running() const override { return driver_ && driver_->running(); }
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
    Engine* engine_ = nullptr;
    std::unique_ptr<CoreAudioDriver> driver_;  // destroyed (stopped) before the engine: the facade
                                               // destroys its adapter first
};

} // namespace

std::unique_ptr<DriverAdapter> makeDefaultDriverAdapter() { return std::make_unique<CoreAudioDriverAdapter>(); }

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

std::vector<DeviceInfoPOD> FakeDeviceDriverAdapter::devices() const {
    std::vector<FakeDeviceState> states;
    AudioDeviceRef defaultOutput = 0;
    if (owned_) {
        states = owned_->devices();
        defaultOutput = owned_->defaultOutput();
    } else {
        // Not started yet: the devices as the spec makes them.
        for (const FakeDevice& device : spec_.devices)
            states.push_back({device.id, device.name, device.input.channels, device.output.channels,
                              device.output.nominalRate, true});
        defaultOutput = spec_.defaultOutput != 0 ? spec_.defaultOutput
                                                 : (spec_.devices.empty() ? 0 : spec_.devices[0].id);
    }
    std::vector<DeviceInfoPOD> out;
    for (const FakeDeviceState& state : states) {
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
