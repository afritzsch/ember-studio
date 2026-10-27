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

} // namespace daw
