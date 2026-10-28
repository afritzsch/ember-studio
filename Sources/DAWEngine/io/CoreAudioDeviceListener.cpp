#include "io/CoreAudioDeviceListener.h"

#include <CoreAudio/CoreAudio.h>

#include <condition_variable>
#include <deque>
#include <mutex>
#include <vector>

#include "io/CoreAudioDevice.h"
#include "io/CoreAudioError.h"

namespace daw {

namespace {

constexpr AudioObjectPropertyAddress address(AudioObjectPropertySelector selector) {
    return {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
}

// IO-020: on the system object.
constexpr AudioObjectPropertySelector kSystemSelectors[] = {
    kAudioHardwarePropertyDevices,
    kAudioHardwarePropertyDefaultOutputDevice,
};
// IO-020/023: on each watched device.
constexpr AudioObjectPropertySelector kDeviceSelectors[] = {
    kAudioDevicePropertyDeviceIsAlive,
    kAudioDevicePropertyNominalSampleRate,
    kAudioDeviceProcessorOverload,
};

} // namespace

struct CoreAudioDeviceListener::Impl {
    // Control side: start/stop/watch.
    bool started = false;
    std::vector<AudioDeviceRef> watched;

    // HAL threads → consumer.
    mutable std::mutex mutex;
    std::condition_variable wake;
    std::deque<DeviceNotification> queue;
    uint64_t dropped = 0;

    static OSStatus onProperty(AudioObjectID object, UInt32 count,
                               const AudioObjectPropertyAddress* addresses, void* ref);

    void push(const DeviceNotification& n) {
        {
            std::lock_guard lock(mutex);
            if (queue.size() >= kNotificationCapacity) {
                ++dropped;
                return;
            }
            queue.push_back(n);
        }
        wake.notify_all();
    }

    // Adds `selectors` on `object`; on a failure removes what it added and says why.
    Result<void> add(AudioObjectID object, const AudioObjectPropertySelector* selectors, std::size_t n) {
        for (std::size_t i = 0; i < n; ++i) {
            const AudioObjectPropertyAddress a = address(selectors[i]);
            const OSStatus status = AudioObjectAddPropertyListener(object, &a, &Impl::onProperty, this);
            if (status != noErr) {
                remove(object, selectors, i);
                return coreAudioError(status, ErrorCode::io, "adding a device listener");
            }
        }
        return {};
    }

    void remove(AudioObjectID object, const AudioObjectPropertySelector* selectors, std::size_t n) {
        for (std::size_t i = 0; i < n; ++i) {
            const AudioObjectPropertyAddress a = address(selectors[i]);
            // Fails for a device that is gone already; there is nothing left to remove then.
            (void)AudioObjectRemovePropertyListener(object, &a, &Impl::onProperty, this);
        }
    }
};

// A HAL notification thread. Reads the new value here: by the time the consumer looks, the
// property may have moved on, and the notification should say what this change was.
OSStatus CoreAudioDeviceListener::Impl::onProperty(AudioObjectID object, UInt32 count,
                                                   const AudioObjectPropertyAddress* addresses,
                                                   void* ref) {
    auto& self = *static_cast<Impl*>(ref);
    for (UInt32 i = 0; i < count; ++i) {
        DeviceNotification n;
        switch (addresses[i].mSelector) {
        case kAudioHardwarePropertyDevices:
            n.type = DeviceNotificationType::devicesChanged;
            break;
        case kAudioHardwarePropertyDefaultOutputDevice: {
            n.type = DeviceNotificationType::defaultOutputChanged;
            auto device = CoreAudioDevice::defaultDevice(DeviceDirection::output);
            n.device = device ? device->id() : 0;
            break;
        }
        case kAudioDevicePropertyDeviceIsAlive:
            n.type = DeviceNotificationType::aliveChanged;
            n.device = object;
            n.alive = CoreAudioDevice(object).isAlive();
            break;
        case kAudioDevicePropertyNominalSampleRate:
            n.type = DeviceNotificationType::nominalRateChanged;
            n.device = object;
            n.sampleRate = CoreAudioDevice(object).nominalRate().valueOr(0.0);
            break;
        case kAudioDeviceProcessorOverload:
            n.type = DeviceNotificationType::processorOverload;
            n.device = object;
            break;
        default:
            continue;
        }
        self.push(n);
    }
    return noErr;
}

CoreAudioDeviceListener::CoreAudioDeviceListener() : impl_(std::make_unique<Impl>()) {}

CoreAudioDeviceListener::~CoreAudioDeviceListener() { stop(); }

Result<void> CoreAudioDeviceListener::start() {
    if (impl_->started) return {};
    if (auto ok = impl_->add(kAudioObjectSystemObject, kSystemSelectors, std::size(kSystemSelectors)); !ok)
        return ok;
    impl_->started = true;
    return {};
}

void CoreAudioDeviceListener::stop() {
    watch(0, 0);
    if (!impl_->started) return;
    impl_->remove(kAudioObjectSystemObject, kSystemSelectors, std::size(kSystemSelectors));
    impl_->started = false;
}

bool CoreAudioDeviceListener::started() const { return impl_->started; }

void CoreAudioDeviceListener::watch(AudioDeviceRef output, AudioDeviceRef input) {
    for (AudioDeviceRef device : impl_->watched)
        impl_->remove(device, kDeviceSelectors, std::size(kDeviceSelectors));
    impl_->watched.clear();
    for (AudioDeviceRef device : {output, input}) {
        if (device == 0 || watching(device)) continue;
        if (impl_->add(device, kDeviceSelectors, std::size(kDeviceSelectors)))
            impl_->watched.push_back(device);
    }
}

bool CoreAudioDeviceListener::watching(AudioDeviceRef device) const {
    for (AudioDeviceRef d : impl_->watched)
        if (d == device) return true;
    return false;
}

std::size_t CoreAudioDeviceListener::pollNotifications(DeviceNotification* out, std::size_t max) {
    std::lock_guard lock(impl_->mutex);
    std::size_t n = 0;
    while (n < max && !impl_->queue.empty()) {
        out[n++] = impl_->queue.front();
        impl_->queue.pop_front();
    }
    return n;
}

bool CoreAudioDeviceListener::waitForNotification(std::chrono::milliseconds timeout) {
    std::unique_lock lock(impl_->mutex);
    return impl_->wake.wait_for(lock, timeout, [this] { return !impl_->queue.empty(); });
}

uint64_t CoreAudioDeviceListener::droppedNotifications() const {
    std::lock_guard lock(impl_->mutex);
    return impl_->dropped;
}

} // namespace daw
