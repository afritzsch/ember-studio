// PLUG-011/013/014/015/016: VST3Instance over the VST3 SDK (see VST3Instance.h).

#include "plugins/VST3Instance.h"

#include <dispatch/dispatch.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>

#include "core/Realtime.h"
#include "time/TempoMap.h"

#include "pluginterfaces/base/funknownimpl.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/vsttypes.h"
#include "public.sdk/source/common/memorystream.h"
#include "public.sdk/source/vst/hosting/hostclasses.h"
#include "public.sdk/source/vst/hosting/module.h"
#include "public.sdk/source/vst/utility/stringconvert.h"

namespace daw {

namespace {

using namespace Steinberg;
using namespace Steinberg::Vst;

constexpr int32 kMaxEventsPerBlock = 1024;          // the graph's MIDI writers hold fewer
constexpr int32 kMaxOutputParamQueues = 256;
constexpr int32 kMaxPointsPerOutputQueue = 16;
constexpr int32 kMaxBusChannels = 2;                // main and aux buses are mono or stereo
constexpr uint32_t kStateMagic = 0x33535645;        // "EVS3" little-endian
constexpr uint32_t kStateVersion = 1;
constexpr uint64_t kLatencyPollNanos = 50 * NSEC_PER_MSEC;

// Module loading and bundleEntry/bundleExit bookkeeping aren't thread-safe across modules of one
// bundle (daw.compile and a caller's instantiatePlugin can race), so loading and unloading are
// serialized process-wide.
std::mutex& moduleMutex() {
    static std::mutex mutex;
    return mutex;
}

Error vst3Error(ErrorCode code, std::string message) { return makeError(code, std::move(message)); }

// Some plugins show the host name or branch on it, so hosted instances identify as the DAW.
class HostContext final : public HostApplication {
public:
    tresult PLUGIN_API getName(String128 name) override {
        static constexpr char16 hostName[] = u"Ember Studio";
        std::memcpy(name, hostName, sizeof(hostName));
        return kResultOk;
    }
};

// PLUG-013 / PLUG-015: the plugin's controller reports here. The plugin → model direction
// (DW-204) is T-063: until then edits are accepted and dropped.
class ComponentHandler final : public U::Implements<U::Directly<IComponentHandler>> {
public:
    tresult PLUGIN_API beginEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API performEdit(ParamID, ParamValue) override { return kResultOk; }
    tresult PLUGIN_API endEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API restartComponent(int32 flags) override {
        // Any thread, the audio thread included: only an atomic (the timer does the rest).
        if (flags & kLatencyChanged) latencyDirty.store(true, std::memory_order_release);
        return kResultOk;
    }

    std::atomic<bool> latencyDirty{false};
};

// The owner (Impl) keeps these alive, so reference counting is a no-op and nothing allocates.
template <class Interface>
class NonRefCounted : public Interface {
public:
    tresult PLUGIN_API queryInterface(const TUID, void** obj) override {
        if (obj != nullptr) *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
};

// PLUG-011: a fixed-capacity IEventList, sized at prepare.
class FixedEventList final : public NonRefCounted<IEventList> {
public:
    void reserve(int32 capacity) {
        events_.resize(static_cast<std::size_t>(capacity));
        capacity_ = capacity;
    }
    void clear() DAW_RT { count_ = 0; }
    bool push(const Event& e) DAW_RT {
        if (count_ >= capacity_) return false;
        events_[static_cast<std::size_t>(count_++)] = e;
        return true;
    }

    int32 PLUGIN_API getEventCount() DAW_RT override { return count_; }
    tresult PLUGIN_API getEvent(int32 index, Event& e) DAW_RT override {
        if (index < 0 || index >= count_) return kInvalidArgument;
        e = events_[static_cast<std::size_t>(index)];
        return kResultOk;
    }
    tresult PLUGIN_API addEvent(Event& e) DAW_RT override { return push(e) ? kResultOk : kResultFalse; }

private:
    std::vector<Event> events_;
    int32 capacity_ = 0;
    int32 count_ = 0;
};

// PLUG-011: one parameter's points for one block, capacity fixed at prepare.
class FixedParamQueue final : public NonRefCounted<IParamValueQueue> {
public:
    void assign(ParamValue* points, int32* offsets, int32 capacity) {
        points_ = points;
        offsets_ = offsets;
        capacity_ = capacity;
    }
    void reset(ParamID id) DAW_RT {
        id_ = id;
        count_ = 0;
    }

    ParamID PLUGIN_API getParameterId() DAW_RT override { return id_; }
    int32 PLUGIN_API getPointCount() DAW_RT override { return count_; }
    tresult PLUGIN_API getPoint(int32 index, int32& offset, ParamValue& value) DAW_RT override {
        if (index < 0 || index >= count_) return kInvalidArgument;
        offset = offsets_[index];
        value = points_[index];
        return kResultOk;
    }
    tresult PLUGIN_API addPoint(int32 offset, ParamValue value, int32& index) DAW_RT override {
        if (count_ >= capacity_) return kResultFalse;
        points_[count_] = value;
        offsets_[count_] = offset;
        index = count_++;
        return kResultOk;
    }

private:
    ParamValue* points_ = nullptr;
    int32* offsets_ = nullptr;
    int32 capacity_ = 0;
    int32 count_ = 0;
    ParamID id_ = 0;
};

// PLUG-011: IParameterChanges with fixed capacity, one queue per parameter that changed.
class FixedParameterChanges final : public NonRefCounted<IParameterChanges> {
public:
    void reserve(int32 queues, int32 pointsPerQueue) {
        queues_.resize(static_cast<std::size_t>(queues));
        points_.resize(static_cast<std::size_t>(queues) * static_cast<std::size_t>(pointsPerQueue));
        offsets_.resize(points_.size());
        for (std::size_t q = 0; q < queues_.size(); ++q)
            queues_[q].assign(points_.data() + q * static_cast<std::size_t>(pointsPerQueue),
                              offsets_.data() + q * static_cast<std::size_t>(pointsPerQueue), pointsPerQueue);
        capacity_ = queues;
    }
    void clear() DAW_RT { used_ = 0; }

    // The host's side: a new queue with a single point at offset 0 (D-13).
    bool pushSingle(ParamID id, ParamValue value) DAW_RT {
        if (used_ >= capacity_) return false;
        FixedParamQueue& queue = queues_[static_cast<std::size_t>(used_++)];
        queue.reset(id);
        int32 index = 0;
        queue.addPoint(0, value, index);
        return true;
    }

    int32 PLUGIN_API getParameterCount() DAW_RT override { return used_; }
    IParamValueQueue* PLUGIN_API getParameterData(int32 index) DAW_RT override {
        if (index < 0 || index >= used_) return nullptr;
        return &queues_[static_cast<std::size_t>(index)];
    }
    IParamValueQueue* PLUGIN_API addParameterData(const ParamID& id, int32& index) DAW_RT override {
        for (int32 q = 0; q < used_; ++q) {  // bounded by capacity_
            if (queues_[static_cast<std::size_t>(q)].getParameterId() == id) {
                index = q;
                return &queues_[static_cast<std::size_t>(q)];
            }
        }
        if (used_ >= capacity_) return nullptr;
        index = used_;
        FixedParamQueue& queue = queues_[static_cast<std::size_t>(used_++)];
        queue.reset(id);
        return &queue;
    }

private:
    std::vector<FixedParamQueue> queues_;
    std::vector<ParamValue> points_;
    std::vector<int32> offsets_;
    int32 capacity_ = 0;
    int32 used_ = 0;
};

// The plugin's process() isn't annotated nonblocking (it's foreign code); the RT trap checks it at
// runtime (CONV §5.3), so the call is exempt from the compile-time effect analysis only.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
tresult callProcess(IAudioProcessor* processor, ProcessData& data) DAW_RT { return processor->process(data); }
#pragma clang diagnostic pop

} // namespace

struct VST3Instance::Impl {
    // Declared first, destroyed last: the plugin objects live inside its code.
    std::shared_ptr<VST3::Hosting::Module> module;
    IPtr<FUnknown> host;
    IPtr<IComponent> component;
    IPtr<IAudioProcessor> processor;
    IPtr<IEditController> controller;
    bool separateController = false;
    IPtr<IConnectionPoint> componentPoint, controllerPoint;
    IPtr<ComponentHandler> handler;

    mutable std::mutex mutex;              // non-RT calls
    bool processing = false;

    // Latency (PLUG-013): atomics for readers on any thread; the reporter under its own lock.
    std::atomic<uint32_t> latency{0};
    std::mutex reporterMutex;
    LatencyReporter reporter;
    dispatch_source_t latencyTimer = nullptr;

    // Bus layout, fixed at instantiation. -1: none.
    int32 mainInput = -1, auxInput = -1, mainOutput = -1, eventInput = -1;
    double tailSamples = 0;

    // RT state, sized at prepare.
    ProcessData data{};
    std::vector<AudioBusBuffers> inputs, outputs;
    std::vector<Sample32*> channelPointers;
    std::vector<float> channelScratch;
    uint32_t maxBlock = 0;
    FixedEventList inEvents, outEvents;
    FixedParameterChanges inParams, outParams;
    Steinberg::Vst::ProcessContext context{};
    bool hadTransport = false;
    Tick lastEndTick = 0;
    int64 continuousSamples = 0;

    // PLUG-015: the last value pushed per parameter (NaN: none), from the audio thread; read off
    // it to keep the controller in step for params(true) and state() (see syncController).
    std::unique_ptr<std::atomic<float>[]> pushed;
    std::vector<float> syncedToController;

    std::vector<ParamID> paramIDs;

    ~Impl() {
        if (latencyTimer != nullptr) {
            dispatch_source_cancel(latencyTimer);
            dispatch_release(latencyTimer);
        }
        if (processor) {
            if (processing) {
                processor->setProcessing(false);
                component->setActive(false);
            }
        }
        if (componentPoint && controllerPoint) {
            componentPoint->disconnect(controllerPoint);
            controllerPoint->disconnect(componentPoint);
        }
        componentPoint = nullptr;
        controllerPoint = nullptr;
        if (controller) controller->setComponentHandler(nullptr);
        if (separateController && controller) controller->terminate();
        controller = nullptr;
        processor = nullptr;
        if (component) component->terminate();
        component = nullptr;
        handler = nullptr;
        host = nullptr;
        std::lock_guard lock(moduleMutex());
        module.reset();
    }

    // Non-RT, caller holds `mutex`. Slot pushes reach the processor through process(); a host keeps
    // the controller in step on a non-RT thread. Without this a controller whose getState or
    // params read its own (edit-side) value would be stale.
    void syncController() {
        if (!controller) return;
        for (std::size_t i = 0; i < paramIDs.size(); ++i) {
            const float value = pushed[i].load(std::memory_order_relaxed);
            if (std::isnan(value) || value == syncedToController[i]) continue;
            controller->setParamNormalized(paramIDs[i], value);
            syncedToController[i] = value;
        }
    }

    // PLUG-013: from the timer's queue, off the RT thread.
    void refreshLatency() {
        if (!handler->latencyDirty.exchange(false, std::memory_order_acq_rel)) return;
        uint32_t next = 0;
        {
            std::lock_guard lock(mutex);
            if (processor) next = processor->getLatencySamples();
        }
        if (latency.exchange(next, std::memory_order_acq_rel) == next) return;
        LatencyReporter copy;
        {
            std::lock_guard lock(reporterMutex);
            copy = reporter;
        }
        copy.changed();
    }

    // RT: copies `src` (or silence) into an input bus's channels.
    void fillInput(const AudioBufferView& src, AudioBusBuffers& bus, uint32_t frames) DAW_RT {
        const std::size_t bytes = std::size_t{frames} * sizeof(float);
        const bool has = !src.empty() && src.numFrames >= frames;
        for (int32 c = 0; c < bus.numChannels; ++c) {
            float* dst = bus.channelBuffers32[c];
            if (!has) {
                std::memset(dst, 0, bytes);
            } else if (bus.numChannels == 1 && src.numChannels >= 2) {
                // A mono bus gets the mid of a stereo source.
                const float* l = src.channels[0];
                const float* r = src.channels[1];
                for (uint32_t i = 0; i < frames; ++i) dst[i] = 0.5f * (l[i] + r[i]);
            } else {
                std::memcpy(dst, src.channels[std::min(static_cast<uint32_t>(c), src.numChannels - 1)], bytes);
            }
        }
    }
};

VST3Instance::VST3Instance(VST3PluginID plugin, std::shared_ptr<Impl> impl)
    : plugin_(std::move(plugin)), impl_(std::move(impl)) {}

VST3Instance::~VST3Instance() = default;

namespace {

bool channelsOf(IAudioProcessor& processor, BusDirection dir, int32 bus, int32& channels) {
    SpeakerArrangement arr = SpeakerArr::kEmpty;
    if (processor.getBusArrangement(dir, bus, arr) != kResultOk) return false;
    channels = SpeakerArr::getChannelCount(arr);
    return true;
}

std::string string128(const String128 text) { return Steinberg::Vst::StringConvert::convert(text); }

} // namespace

Result<std::shared_ptr<VST3Instance>> VST3Instance::instantiate(const VST3PluginID& plugin) {
    auto uid = VST3::UID::fromString(plugin.classUID);
    if (!uid) return vst3Error(ErrorCode::invalidArgument, "invalid VST3 class UID " + plugin.classUID);
    if (::access(plugin.path.c_str(), F_OK) != 0)
        return vst3Error(ErrorCode::notFound, "no VST3 bundle at " + plugin.path);

    auto impl = std::make_shared<Impl>();
    std::string error;
    {
        std::lock_guard lock(moduleMutex());
        impl->module = VST3::Hosting::Module::create(plugin.path, error);
    }
    if (!impl->module)
        return vst3Error(ErrorCode::unsupported, "can't load " + plugin.path + (error.empty() ? "" : ": " + error));

    auto factory = impl->module->getFactory();
    impl->host = owned(new HostContext());
    factory.setHostContext(impl->host);

    std::string name;
    bool found = false;
    for (const auto& info : factory.classInfos()) {
        if (info.ID() == *uid && info.category() == kVstAudioEffectClass) {
            name = info.name();
            found = true;
            break;
        }
    }
    if (!found)
        return vst3Error(ErrorCode::notFound, plugin.path + " has no audio effect class " + plugin.classUID);

    impl->component = factory.createInstance<IComponent>(*uid);
    if (!impl->component) return vst3Error(ErrorCode::unsupported, "can't create the component of " + plugin.identifier());
    if (impl->component->initialize(impl->host) != kResultOk) {
        impl->component = nullptr;
        return vst3Error(ErrorCode::unsupported, "IComponent::initialize failed for " + plugin.identifier());
    }
    impl->processor = FUnknownPtr<IAudioProcessor>(impl->component);
    if (!impl->processor)
        return vst3Error(ErrorCode::unsupported, plugin.identifier() + " has no IAudioProcessor");

    // The controller is the component itself (single-component effect) or a separate class.
    impl->controller = FUnknownPtr<IEditController>(impl->component);
    if (!impl->controller) {
        TUID controllerID{};
        if (impl->component->getControllerClassId(controllerID) == kResultOk) {
            impl->controller = factory.createInstance<IEditController>(VST3::UID::fromTUID(controllerID));
            if (impl->controller && impl->controller->initialize(impl->host) == kResultOk) {
                impl->separateController = true;
            } else {
                impl->controller = nullptr;
            }
        }
    }

    impl->handler = owned(new ComponentHandler());
    if (impl->controller) impl->controller->setComponentHandler(impl->handler);

    if (impl->separateController) {
        // Connected before state, as PlugProvider does: a controller may only build its parameters
        // once connected. Direct connection, since host and plugin share one process (no proxy).
        impl->componentPoint = FUnknownPtr<IConnectionPoint>(impl->component);
        impl->controllerPoint = FUnknownPtr<IConnectionPoint>(impl->controller);
        if (impl->componentPoint && impl->controllerPoint) {
            impl->componentPoint->connect(impl->controllerPoint);
            impl->controllerPoint->connect(impl->componentPoint);
        }
        // The controller starts from the component's state.
        MemoryStream stream;
        if (impl->component->getState(&stream) == kResultOk && stream.getSize() > 0) {
            stream.seek(0, IBStream::kIBSeekSet, nullptr);
            impl->controller->setComponentState(&stream);
        }
    }

    // Bus layout: the first of each kind (PLUG-011, PLUG-014).
    for (int32 i = 0, n = impl->component->getBusCount(kAudio, kInput); i < n; ++i) {
        BusInfo info{};
        if (impl->component->getBusInfo(kAudio, kInput, i, info) != kResultOk) continue;
        if (info.busType == kMain && impl->mainInput < 0) impl->mainInput = i;
        if (info.busType == kAux && impl->auxInput < 0) impl->auxInput = i;
    }
    for (int32 i = 0, n = impl->component->getBusCount(kAudio, kOutput); i < n; ++i) {
        BusInfo info{};
        if (impl->component->getBusInfo(kAudio, kOutput, i, info) != kResultOk) continue;
        if (info.busType == kMain && impl->mainOutput < 0) impl->mainOutput = i;
    }
    if (impl->component->getBusCount(kEvent, kInput) > 0) impl->eventInput = 0;

    std::shared_ptr<VST3Instance> instance(new VST3Instance(plugin, impl));
    instance->name_ = std::move(name);

    // PLUG-015: index i ↔ getParameterInfo(i), fixed for the instance.
    if (impl->controller) {
        const int32 count = std::max<int32>(0, impl->controller->getParameterCount());
        for (int32 i = 0; i < count; ++i) {
            ParameterInfo pi{};
            if (impl->controller->getParameterInfo(i, pi) != kResultOk) continue;
            VST3ParamInfo info;
            info.id = pi.id;
            info.name = string128(pi.title);
            info.unit = string128(pi.units);
            info.value = static_cast<float>(impl->controller->getParamNormalized(pi.id));
            info.writable = (pi.flags & ParameterInfo::kIsReadOnly) == 0;
            instance->params_.push_back(std::move(info));
            impl->paramIDs.push_back(pi.id);
        }
    }
    const std::size_t params = instance->params_.size();
    impl->pushed = std::make_unique<std::atomic<float>[]>(params);
    impl->syncedToController.assign(params, std::numeric_limits<float>::quiet_NaN());
    for (std::size_t i = 0; i < params; ++i)
        impl->pushed[i].store(std::numeric_limits<float>::quiet_NaN(), std::memory_order_relaxed);

    return instance;
}

bool VST3Instance::hasAudioInput() const { return impl_->mainInput >= 0; }
bool VST3Instance::acceptsMIDI() const { return impl_->eventInput >= 0; }
bool VST3Instance::hasAuxInput() const { return impl_->auxInput >= 0; }
uint32_t VST3Instance::latencySamples() const { return impl_->latency.load(std::memory_order_acquire); }
double VST3Instance::tailSeconds() const {
    return rate_ > 0 ? impl_->tailSamples / rate_ : 0.0;
}
Steinberg::Vst::IEditController* VST3Instance::editController() const { return impl_->controller; }

void VST3Instance::setLatencyReporter(LatencyReporter reporter) {
    std::lock_guard lock(impl_->reporterMutex);
    impl_->reporter = std::move(reporter);
}

void VST3Instance::startLatencyTimer() {
    if (impl_->latencyTimer != nullptr) return;
    dispatch_source_t timer =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(kLatencyPollNanos)),
                              kLatencyPollNanos, 10 * NSEC_PER_MSEC);
    std::weak_ptr<Impl> weak = impl_;
    dispatch_source_set_event_handler(timer, ^{
        if (auto impl = weak.lock()) impl->refreshLatency();
    });
    dispatch_resume(timer);
    impl_->latencyTimer = timer;
}

namespace {

// Asks for `want` on the main audio buses and `wantAux` on the aux input. False if the plugin refuses.
bool tryArrangement(IAudioProcessor& processor, IComponent& component, int32 mainIn, int32 aux, int32 mainOut,
                    SpeakerArrangement want, SpeakerArrangement wantAux) {
    const int32 numIn = component.getBusCount(kAudio, kInput);
    const int32 numOut = component.getBusCount(kAudio, kOutput);
    std::vector<SpeakerArrangement> ins(static_cast<std::size_t>(numIn), SpeakerArr::kEmpty);
    std::vector<SpeakerArrangement> outs(static_cast<std::size_t>(numOut), SpeakerArr::kEmpty);
    for (int32 i = 0; i < numIn; ++i) processor.getBusArrangement(kInput, i, ins[static_cast<std::size_t>(i)]);
    for (int32 i = 0; i < numOut; ++i) processor.getBusArrangement(kOutput, i, outs[static_cast<std::size_t>(i)]);
    if (mainIn >= 0) ins[static_cast<std::size_t>(mainIn)] = want;
    if (aux >= 0) ins[static_cast<std::size_t>(aux)] = wantAux;
    if (mainOut >= 0) outs[static_cast<std::size_t>(mainOut)] = want;
    return processor.setBusArrangements(ins.data(), numIn, outs.data(), numOut) == kResultTrue;
}

} // namespace

Result<void> VST3Instance::prepare(double sampleRate, uint32_t maxBlock) {
    Impl& impl = *impl_;
    std::lock_guard lock(impl.mutex);
    if (prepared_.load(std::memory_order_acquire) && rate_ == sampleRate && maxBlock_ == maxBlock) return {};
    prepared_.store(false, std::memory_order_release);
    if (impl.processing) {
        impl.processor->setProcessing(false);
        impl.component->setActive(false);
        impl.processing = false;
    }
    if (impl.mainOutput < 0) return makeError(ErrorCode::unsupported, identifier() + " has no main audio output");

    IComponent& component = *impl.component;
    IAudioProcessor& processor = *impl.processor;
    if (processor.canProcessSampleSize(kSample32) != kResultTrue)
        return makeError(ErrorCode::unsupported, identifier() + " can't process 32-bit audio");

    // PLUG-011 / PLUG-014: stereo where the plugin takes it, else a mono sidechain (common), else
    // mono throughout, else what it has.
    const auto attempt = [&](SpeakerArrangement main, SpeakerArrangement aux) {
        return tryArrangement(processor, component, impl.mainInput, impl.auxInput, impl.mainOutput, main, aux);
    };
    if (!attempt(SpeakerArr::kStereo, SpeakerArr::kStereo) && !attempt(SpeakerArr::kStereo, SpeakerArr::kMono))
        (void)attempt(SpeakerArr::kMono, SpeakerArr::kMono);

    int32 in = 0, aux = 0, out = 0;
    if (impl.mainInput >= 0 && (!channelsOf(processor, kInput, impl.mainInput, in) || in < 1 || in > kMaxBusChannels))
        return makeError(ErrorCode::unsupported, identifier() + ": no mono or stereo input");
    if (!channelsOf(processor, kOutput, impl.mainOutput, out) || out < 1 || out > kMaxBusChannels)
        return makeError(ErrorCode::unsupported, identifier() + ": no mono or stereo output");
    // An aux bus the plugin won't make mono or stereo just runs without a sidechain.
    if (impl.auxInput >= 0 && (!channelsOf(processor, kInput, impl.auxInput, aux) || aux < 1 || aux > kMaxBusChannels))
        aux = 0;

    const int32 numIn = component.getBusCount(kAudio, kInput);
    const int32 numOut = component.getBusCount(kAudio, kOutput);
    for (int32 i = 0; i < numIn; ++i) component.activateBus(kAudio, kInput, i, i == impl.mainInput || (i == impl.auxInput && aux > 0));
    for (int32 i = 0; i < numOut; ++i) component.activateBus(kAudio, kOutput, i, i == impl.mainOutput);
    for (int32 i = 0, n = component.getBusCount(kEvent, kInput); i < n; ++i) component.activateBus(kEvent, kInput, i, i == impl.eventInput);
    for (int32 i = 0, n = component.getBusCount(kEvent, kOutput); i < n; ++i) component.activateBus(kEvent, kOutput, i, false);

    // Buffers for every bus the plugin declared (inactive ones too: it may read their channel
    // counts), one scratch block per channel.
    impl.inputs.assign(static_cast<std::size_t>(numIn), AudioBusBuffers{});
    impl.outputs.assign(static_cast<std::size_t>(numOut), AudioBusBuffers{});
    int32 totalChannels = 0;
    const auto setUp = [&](std::vector<AudioBusBuffers>& buses, BusDirection dir) {
        for (int32 i = 0; i < static_cast<int32>(buses.size()); ++i) {
            int32 channels = 0;
            channelsOf(processor, dir, i, channels);
            buses[static_cast<std::size_t>(i)].numChannels = std::max<int32>(0, channels);
            totalChannels += std::max<int32>(0, channels);
        }
    };
    setUp(impl.inputs, kInput);
    setUp(impl.outputs, kOutput);
    impl.channelPointers.assign(static_cast<std::size_t>(totalChannels), nullptr);
    impl.channelScratch.assign(static_cast<std::size_t>(totalChannels) * maxBlock, 0.0f);
    int32 next = 0;
    const auto wire = [&](std::vector<AudioBusBuffers>& buses) {
        for (AudioBusBuffers& bus : buses) {
            bus.channelBuffers32 = impl.channelPointers.data() + next;
            for (int32 c = 0; c < bus.numChannels; ++c, ++next)
                impl.channelPointers[static_cast<std::size_t>(next)] =
                    impl.channelScratch.data() + static_cast<std::size_t>(next) * maxBlock;
        }
    };
    wire(impl.inputs);
    wire(impl.outputs);
    impl.maxBlock = maxBlock;

    // The block's lists, sized now so the audio thread never grows them.
    impl.inEvents.reserve(kMaxEventsPerBlock);
    impl.outEvents.reserve(kMaxEventsPerBlock);
    impl.inParams.reserve(std::max<int32>(1, static_cast<int32>(params_.size())), 1);
    impl.outParams.reserve(kMaxOutputParamQueues, kMaxPointsPerOutputQueue);

    ProcessSetup setup{};
    setup.processMode = kRealtime;
    setup.symbolicSampleSize = kSample32;
    setup.maxSamplesPerBlock = static_cast<int32>(maxBlock);
    setup.sampleRate = sampleRate;
    if (processor.setupProcessing(setup) != kResultOk)
        return makeError(ErrorCode::unsupported, identifier() + ": setupProcessing failed");
    if (component.setActive(true) != kResultOk)
        return makeError(ErrorCode::unsupported, identifier() + ": setActive failed");
    // kNotImplemented is allowed (the plugin needs no signal).
    processor.setProcessing(true);
    impl.processing = true;

    impl.data = ProcessData{};
    impl.data.processMode = kRealtime;
    impl.data.symbolicSampleSize = kSample32;
    impl.data.numInputs = numIn;
    impl.data.numOutputs = numOut;
    impl.data.inputs = impl.inputs.empty() ? nullptr : impl.inputs.data();
    impl.data.outputs = impl.outputs.empty() ? nullptr : impl.outputs.data();
    impl.data.inputParameterChanges = &impl.inParams;
    impl.data.outputParameterChanges = &impl.outParams;
    impl.data.inputEvents = &impl.inEvents;
    impl.data.outputEvents = &impl.outEvents;
    impl.data.processContext = &impl.context;

    impl.context = Steinberg::Vst::ProcessContext{};
    impl.context.sampleRate = sampleRate;
    impl.context.tempo = 120.0;
    impl.context.timeSigNumerator = 4;
    impl.context.timeSigDenominator = 4;
    impl.hadTransport = false;
    impl.lastEndTick = 0;

    const uint32_t tail = processor.getTailSamples();
    impl.tailSamples = tail == kInfiniteTail ? std::numeric_limits<double>::infinity() : tail;

    rate_ = sampleRate;
    maxBlock_ = maxBlock;
    inChannels_ = static_cast<uint32_t>(in);
    outChannels_ = static_cast<uint32_t>(out);
    sidechainChannels_ = static_cast<uint32_t>(aux);
    impl.latency.store(processor.getLatencySamples(), std::memory_order_release);
    startLatencyTimer();
    prepared_.store(true, std::memory_order_release);
    return {};
}

std::vector<VST3ParamInfo> VST3Instance::params(bool current) const {
    if (!current) return params_;
    std::vector<VST3ParamInfo> out = params_;
    Impl& impl = *impl_;
    std::lock_guard lock(impl.mutex);
    if (!impl.controller) return out;
    impl.syncController();
    for (std::size_t i = 0; i < out.size(); ++i)
        out[i].value = static_cast<float>(impl.controller->getParamNormalized(impl.paramIDs[i]));
    return out;
}

namespace {

void appendU32(std::vector<uint8_t>& out, uint32_t v) {
    for (int i = 0; i < 4; ++i) out.push_back(static_cast<uint8_t>(v >> (8 * i)));
}

void appendU64(std::vector<uint8_t>& out, uint64_t v) {
    for (int i = 0; i < 8; ++i) out.push_back(static_cast<uint8_t>(v >> (8 * i)));
}

bool readU32(const std::vector<uint8_t>& in, std::size_t& at, uint32_t& v) {
    if (in.size() < at + 4) return false;
    v = 0;
    for (int i = 0; i < 4; ++i) v |= static_cast<uint32_t>(in[at + static_cast<std::size_t>(i)]) << (8 * i);
    at += 4;
    return true;
}

bool readU64(const std::vector<uint8_t>& in, std::size_t& at, uint64_t& v) {
    if (in.size() < at + 8) return false;
    v = 0;
    for (int i = 0; i < 8; ++i) v |= static_cast<uint64_t>(in[at + static_cast<std::size_t>(i)]) << (8 * i);
    at += 8;
    return true;
}

} // namespace

Result<std::vector<uint8_t>> VST3Instance::state() const {
    Impl& impl = *impl_;
    std::lock_guard lock(impl.mutex);
    impl.syncController();

    MemoryStream componentStream;
    if (impl.component->getState(&componentStream) != kResultOk)
        return makeError(ErrorCode::internal, identifier() + ": IComponent::getState failed");

    MemoryStream controllerStream;
    if (impl.controller && impl.controller->getState(&controllerStream) != kResultOk) {
        // A controller with nothing of its own to save may refuse; only the component's matters.
        controllerStream.setSize(0);
    }

    std::vector<uint8_t> out;
    out.reserve(24 + static_cast<std::size_t>(componentStream.getSize()) + static_cast<std::size_t>(controllerStream.getSize()));
    appendU32(out, kStateMagic);
    appendU32(out, kStateVersion);
    const auto append = [&](MemoryStream& stream) {
        const auto size = static_cast<uint64_t>(std::max<TSize>(0, stream.getSize()));
        appendU64(out, size);
        const auto* data = reinterpret_cast<const uint8_t*>(stream.getData());
        if (size > 0 && data != nullptr) out.insert(out.end(), data, data + size);
    };
    append(componentStream);
    append(controllerStream);
    return out;
}

Result<void> VST3Instance::setState(const std::vector<uint8_t>& state) {
    std::size_t at = 0;
    uint32_t magic = 0, version = 0;
    uint64_t componentSize = 0, controllerSize = 0;
    const auto bad = [&] { return makeError(ErrorCode::invalidArgument, identifier() + ": not a VST3 state container"); };
    if (!readU32(state, at, magic) || magic != kStateMagic || !readU32(state, at, version) || version != kStateVersion)
        return bad();
    if (!readU64(state, at, componentSize)) return bad();
    if (state.size() < at + componentSize) return bad();
    const std::size_t componentAt = at;
    at += componentSize;
    if (!readU64(state, at, controllerSize) || state.size() != at + controllerSize) return bad();

    Impl& impl = *impl_;
    std::lock_guard lock(impl.mutex);

    // MemoryStream wraps the bytes without owning them; the plugin only reads.
    // An empty section means the plugin had nothing to save: nothing to restore either (a plugin
    // may refuse an empty stream, which isn't a bad state).
    void* componentBytes = const_cast<uint8_t*>(state.data() + componentAt);
    if (componentSize > 0) {
        {
            MemoryStream stream(componentBytes, static_cast<TSize>(componentSize));
            if (impl.component->setState(&stream) != kResultOk)
                return makeError(ErrorCode::invalidArgument, identifier() + ": the component refused the state");
        }
        if (impl.controller) {
            MemoryStream stream(componentBytes, static_cast<TSize>(componentSize));
            impl.controller->setComponentState(&stream);
        }
    }
    if (impl.controller && controllerSize > 0) {
        MemoryStream stream(const_cast<uint8_t*>(state.data() + at), static_cast<TSize>(controllerSize));
        impl.controller->setState(&stream);
    }
    // The state wins over what automation pushed last until a slot moves again.
    for (std::size_t i = 0; i < params_.size(); ++i) {
        impl.pushed[i].store(std::numeric_limits<float>::quiet_NaN(), std::memory_order_relaxed);
        impl.syncedToController[i] = std::numeric_limits<float>::quiet_NaN();
    }
    return {};
}

// MARK: RT

void VST3Instance::pushParam(uint32_t index, float normalized) DAW_RT {
    Impl& impl = *impl_;
    if (index >= params_.size()) return;
    impl.inParams.pushSingle(impl.paramIDs[index], normalized);
    impl.pushed[index].store(normalized, std::memory_order_relaxed);
}

void VST3Instance::addMidi(const MidiEvent& event, uint32_t numFrames) DAW_RT {
    Impl& impl = *impl_;
    if (impl.eventInput < 0 || event.size < 3 || numFrames == 0) return;
    const uint8_t status = event.data[0] & 0xF0;
    const auto channel = static_cast<int16>(event.data[0] & 0x0F);
    const auto pitch = static_cast<int16>(event.data[1] & 0x7F);
    const float velocity = (event.data[2] & 0x7F) / 127.0f;
    Event e{};
    e.busIndex = impl.eventInput;
    e.sampleOffset = static_cast<int32>(std::min(event.frameOffset, numFrames - 1));
    e.flags = Event::kIsLive;
    if (status == 0x90 && (event.data[2] & 0x7F) > 0) {
        e.type = Event::kNoteOnEvent;
        e.noteOn.channel = channel;
        e.noteOn.pitch = pitch;
        e.noteOn.velocity = velocity;
        e.noteOn.noteId = -1;
    } else if (status == 0x80 || status == 0x90) {
        e.type = Event::kNoteOffEvent;
        e.noteOff.channel = channel;
        e.noteOff.pitch = pitch;
        e.noteOff.velocity = status == 0x80 ? velocity : 0.0f;
        e.noteOff.noteId = -1;
    } else {
        return;  // PLUG-011 asks for notes; CC and pitch bend need IMidiMapping (discovered work)
    }
    impl.inEvents.push(e);
}

void VST3Instance::setTransport(const TransportBlock& transport) DAW_RT {
    Impl& impl = *impl_;
    Steinberg::Vst::ProcessContext& c = impl.context;
    uint32 state = 0;
    if (transport.playing) state |= Steinberg::Vst::ProcessContext::kPlaying;
    if (transport.numSegments > 0 && transport.tempo != nullptr) {
        const TransportSegment& seg = transport.seg[0];
        const TempoMap& map = *transport.tempo;
        c.tempo = map.bpmAt(seg.startTick);
        c.projectTimeMusic = static_cast<double>(seg.startTick) / kPPQ;
        c.projectTimeSamples = seg.startSample;
        const BBT bbt = map.tickToBBT(seg.startTick);
        c.barPositionMusic = static_cast<double>(map.bbtToTick(BBT{bbt.bar, 1, 0})) / kPPQ;
        // The signature in force: the last event at or before the tick (bounded by the map's events).
        const size_t n = map.timeSigEventCount();
        for (size_t i = 0; i < n; ++i) {
            const TimeSigEvent e = map.timeSigEvent(i);
            if (e.tick > seg.startTick) break;
            c.timeSigNumerator = e.num;
            c.timeSigDenominator = e.den;
        }
        impl.hadTransport = true;
        impl.lastEndTick = transport.seg[transport.numSegments - 1].endTick;
    }
    if (impl.hadTransport)
        state |= Steinberg::Vst::ProcessContext::kTempoValid | Steinberg::Vst::ProcessContext::kTimeSigValid | Steinberg::Vst::ProcessContext::kProjectTimeMusicValid |
                 Steinberg::Vst::ProcessContext::kBarPositionValid;
    c.state = state | Steinberg::Vst::ProcessContext::kContTimeValid;
    c.continousTimeSamples = impl.continuousSamples;
}

bool VST3Instance::render(const NodeIO& io, uint32_t numFrames) DAW_RT {
    Impl& impl = *impl_;
    if (!prepared_.load(std::memory_order_acquire) || numFrames == 0 || numFrames > impl.maxBlock) return false;

    if (impl.mainInput >= 0) impl.fillInput(io.audioIn, impl.inputs[static_cast<std::size_t>(impl.mainInput)], numFrames);
    if (impl.auxInput >= 0) impl.fillInput(io.sidechain, impl.inputs[static_cast<std::size_t>(impl.auxInput)], numFrames);

    impl.data.numSamples = static_cast<int32>(numFrames);
    const tresult status = callProcess(impl.processor, impl.data);
    impl.continuousSamples += numFrames;

    // Nothing from this block leaks into the next one.
    impl.inEvents.clear();
    impl.outEvents.clear();
    impl.inParams.clear();
    impl.outParams.clear();

    if (status != kResultOk) {
        renderErrors_.fetch_add(1, std::memory_order_relaxed);
        return false;
    }

    const AudioBusBuffers& out = impl.outputs[static_cast<std::size_t>(impl.mainOutput)];
    const std::size_t bytes = std::size_t{numFrames} * sizeof(float);
    for (uint32_t c = 0; c < io.audioOut.numChannels; ++c) {
        const int32 from = std::min(static_cast<int32>(c), out.numChannels - 1);
        std::memcpy(io.audioOut.channels[c], out.channelBuffers32[from], bytes);
    }
    return true;
}

} // namespace daw
