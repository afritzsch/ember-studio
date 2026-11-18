// PLUG-011/013/014/015/016: VST3Instance over the VST3 SDK (see VST3Instance.h).

#include "plugins/VST3Instance.h"

#include <dispatch/dispatch.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>
#include <unordered_map>

#include "core/Realtime.h"
#include "plugins/HeldNotes.h"
#include "plugins/PluginEditQueue.h"
#include "plugins/PluginReset.h"
#include "time/TempoMap.h"

#include "pluginterfaces/base/funknownimpl.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/ivstmidicontrollers.h"
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
// T-097: points per input parameter queue in one block. A parameter gets its slot point at offset 0
// and, at a loop wrap, a hold and a jump point (DW-233); one the plugin maps a MIDI controller to
// (IMidiMapping, DW-210) gets room for that many MIDI changes as well (more in one block keep the
// last value at the last frame).
constexpr int32 kSlotPoints = 3;
constexpr int32 kMidiPoints = 128;
constexpr int32 kMidiChannels = 16;

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

// PLUG-015 second half, DW-204 (T-063): what the plugin's own editor did to its parameters. The
// controller calls beginEdit/performEdit/endEdit on its UI thread; they go to the slot's
// PluginEditQueue (→ pluginParamEdited events → one SetParam gesture in the model). The model's
// value comes back as a slot push; `editValue` keeps syncController from writing an older model
// value into the controller while the plugin is ahead of the model (a drag between polls), which
// would make the knob jump back.
struct EditState {
    std::mutex mutex;
    std::shared_ptr<PluginEditQueue> queue;  // null: edits are dropped (no facade, tests)
    NodeID slot = 0;
    IEditController* controller = nullptr;  // for a begin's value; cleared before the controller goes
    std::unordered_map<ParamID, uint32_t> indexOf;
    std::vector<uint32_t> open;    // per index: beginEdit nesting
    std::vector<float> editValue;  // the plugin's newest value not yet seen back from the model (NaN)
    std::vector<std::chrono::steady_clock::time_point> editTime;

    // How long a plugin-made value waits for the model's echo before the model wins again.
    static constexpr auto kEchoWait = std::chrono::seconds(1);

    void push(uint32_t index, float value, PluginEditKind phase) {
        if (queue) queue->push(PluginParamEdit{slot, index, value, phase});
    }
};

// PLUG-013 / PLUG-015: the plugin's controller reports here.
class ComponentHandler final : public U::Implements<U::Directly<IComponentHandler>> {
public:
    explicit ComponentHandler(std::shared_ptr<EditState> edits) : edits_(std::move(edits)) {}

    // DW-204: a gesture on one parameter. Nested begins of one parameter count once.
    tresult PLUGIN_API beginEdit(ParamID id) override {
        std::lock_guard lock(edits_->mutex);
        const auto it = edits_->indexOf.find(id);
        if (it == edits_->indexOf.end()) return kInvalidArgument;
        if (edits_->open[it->second]++ == 0) {
            // The value before the gesture (the editor calls beginEdit before it changes it).
            const float before = edits_->controller != nullptr ? static_cast<float>(edits_->controller->getParamNormalized(id))
                                                               : std::numeric_limits<float>::quiet_NaN();
            edits_->push(it->second, before, PluginEditKind::begin);
        }
        return kResultOk;
    }
    // DW-204: inside a gesture a step of it; outside one an ungestured edit (the model groups those).
    tresult PLUGIN_API performEdit(ParamID id, ParamValue normalized) override {
        std::lock_guard lock(edits_->mutex);
        const auto it = edits_->indexOf.find(id);
        if (it == edits_->indexOf.end()) return kInvalidArgument;
        const float value = static_cast<float>(std::clamp(normalized, 0.0, 1.0));
        edits_->editValue[it->second] = value;
        edits_->editTime[it->second] = std::chrono::steady_clock::now();
        edits_->push(it->second, value, PluginEditKind::value);
        return kResultOk;
    }
    tresult PLUGIN_API endEdit(ParamID id) override {
        std::lock_guard lock(edits_->mutex);
        const auto it = edits_->indexOf.find(id);
        if (it == edits_->indexOf.end()) return kInvalidArgument;
        uint32_t& open = edits_->open[it->second];
        if (open == 0) return kResultFalse;  // an end without a begin
        if (--open == 0) edits_->push(it->second, std::numeric_limits<float>::quiet_NaN(), PluginEditKind::end);
        return kResultOk;
    }
    tresult PLUGIN_API restartComponent(int32 flags) override {
        // Any thread, the audio thread included: only an atomic (the timer does the rest).
        if (flags & kLatencyChanged) latencyDirty.store(true, std::memory_order_release);
        return kResultOk;
    }

    std::atomic<bool> latencyDirty{false};

private:
    std::shared_ptr<EditState> edits_;
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
    // T-097: a point in offset order (after the points at the same offset). When the queue is full
    // a point at or after the last one replaces it, so the block still ends at the newest value.
    void insert(int32 offset, ParamValue value) DAW_RT {
        if (count_ >= capacity_) {
            if (count_ > 0 && offset >= offsets_[count_ - 1]) {
                offsets_[count_ - 1] = offset;
                points_[count_ - 1] = value;
            }
            return;
        }
        int32 at = count_;
        while (at > 0 && offsets_[at - 1] > offset) {  // CONV-RT-04: bounded by the capacity
            offsets_[at] = offsets_[at - 1];
            points_[at] = points_[at - 1];
            --at;
        }
        offsets_[at] = offset;
        points_[at] = value;
        ++count_;
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

// T-097 (DW-210, DW-233): the input IParameterChanges. One queue per parameter index (params()),
// each with its own capacity, so a block can carry several points per parameter (a wrap jump,
// MIDI-mapped controller changes) in offset order; the queues used this block are listed in the
// order they were first touched.
class IndexedParameterChanges final : public NonRefCounted<IParameterChanges> {
public:
    void reserve(const std::vector<ParamID>& ids, const std::vector<int32>& capacities) {
        const std::size_t n = ids.size();
        queues_.resize(n);
        std::size_t total = 0;
        for (int32 c : capacities) total += static_cast<std::size_t>(std::max<int32>(1, c));
        points_.assign(total, 0.0);
        offsets_.assign(total, 0);
        order_.assign(n, 0);
        used_.assign(n, 0);
        std::size_t at = 0;
        for (std::size_t q = 0; q < n; ++q) {
            const int32 capacity = std::max<int32>(1, capacities[q]);
            queues_[q].assign(points_.data() + at, offsets_.data() + at, capacity);
            queues_[q].reset(ids[q]);
            at += static_cast<std::size_t>(capacity);
        }
        count_ = 0;
    }
    void clear() DAW_RT {
        for (int32 i = 0; i < count_; ++i) used_[order_[static_cast<std::size_t>(i)]] = 0;
        count_ = 0;
    }
    // A point for parameter `index` at `offset`; false for an unknown index.
    bool add(uint32_t index, int32 offset, ParamValue value) DAW_RT {
        if (index >= queues_.size()) return false;
        FixedParamQueue& queue = queues_[index];
        if (!used_[index]) {
            used_[index] = 1;
            order_[static_cast<std::size_t>(count_++)] = index;
            queue.reset(queue.getParameterId());
        }
        queue.insert(offset, value);
        return true;
    }

    int32 PLUGIN_API getParameterCount() DAW_RT override { return count_; }
    IParamValueQueue* PLUGIN_API getParameterData(int32 index) DAW_RT override {
        if (index < 0 || index >= count_) return nullptr;
        return &queues_[order_[static_cast<std::size_t>(index)]];
    }
    // The host fills this list; a plugin adding to its input gets the queue only if it is in use.
    IParamValueQueue* PLUGIN_API addParameterData(const ParamID& id, int32& index) DAW_RT override {
        for (int32 i = 0; i < count_; ++i) {  // bounded by the parameter count
            FixedParamQueue& queue = queues_[order_[static_cast<std::size_t>(i)]];
            if (queue.getParameterId() == id) {
                index = i;
                return &queue;
            }
        }
        return nullptr;
    }

private:
    std::vector<FixedParamQueue> queues_;
    std::vector<ParamValue> points_;
    std::vector<int32> offsets_;
    std::vector<uint32_t> order_;
    std::vector<uint8_t> used_;
    int32 count_ = 0;
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
    std::shared_ptr<EditState> edits = std::make_shared<EditState>();  // DW-204

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
    IndexedParameterChanges inParams;  // T-097: several points per parameter
    FixedParameterChanges outParams;
    // DW-225 (T-097): the notes the plugin holds (audio thread; the reset worker clears them while
    // the audio thread waits for it).
    HeldNotes held;
    // DW-210 (T-097): IMidiMapping, read at prepare: the parameter index each channel's controller
    // (0…127 CC, 128 channel aftertouch, 129 pitch bend) drives, -1 for none.
    std::vector<int32> midiMap;  // kMidiChannels × kCountCtrlNumber
    bool hasMidiMap = false;
    bool offline = false;  // DW-211 (T-097): prepared with kOffline
    Steinberg::Vst::ProcessContext context{};
    bool hadTransport = false;
    Tick lastEndTick = 0;
    int64 continuousSamples = 0;

    // PLUG-015: the last value pushed per parameter (NaN: none), from the audio thread; read off
    // it to keep the controller in step for params(true) and state() (see syncController).
    std::unique_ptr<std::atomic<float>[]> pushed;
    std::vector<float> syncedToController;

    std::vector<ParamID> paramIDs;
    std::unordered_map<ParamID, uint32_t> indexOfID;  // T-097: paramIDs inverted (IMidiMapping)
    // DW-213 (T-094): each stepped parameter's value names, read once on the first params(true)
    // (not at instantiation, which runs on daw.compile), under `mutex`.
    std::vector<std::vector<std::string>> labels;
    bool labelsRead = false;

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
        {
            std::lock_guard lock(edits->mutex);  // DW-204
            edits->controller = nullptr;
        }
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
    //
    // DW-204 (T-063): a parameter the plugin's editor is changing (a gesture is open, or its newest
    // value hasn't come back from the model yet, for up to EditState::kEchoWait) keeps the
    // controller's value, so the editor's knob never jumps back to an older model value.
    void syncController() {
        if (!controller) return;
        const auto now = std::chrono::steady_clock::now();
        for (std::size_t i = 0; i < paramIDs.size(); ++i) {
            const float value = pushed[i].load(std::memory_order_relaxed);
            if (std::isnan(value) || value == syncedToController[i]) continue;
            {
                std::lock_guard lock(edits->mutex);
                if (edits->open[i] > 0) continue;
                const float edited = edits->editValue[i];
                if (!std::isnan(edited)) {
                    if (std::fabs(value - edited) <= 1e-6f) {
                        // The model caught up: the controller already holds it.
                        edits->editValue[i] = std::numeric_limits<float>::quiet_NaN();
                        syncedToController[i] = value;
                        continue;
                    }
                    if (now - edits->editTime[i] < EditState::kEchoWait) continue;
                    edits->editValue[i] = std::numeric_limits<float>::quiet_NaN();
                }
            }
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

VST3Instance::~VST3Instance() {
    reset_.reset();  // DW-242: unregistered (and any reset of it finished) before the plugin goes
}

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

    impl->handler = owned(new ComponentHandler(impl->edits));
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
            info.steps = static_cast<uint32_t>(std::max<int32>(0, pi.stepCount));  // DW-213
            instance->params_.push_back(std::move(info));
            impl->indexOfID.emplace(pi.id, static_cast<uint32_t>(impl->paramIDs.size()));
            impl->paramIDs.push_back(pi.id);
        }
    }
    const std::size_t params = instance->params_.size();
    {
        // DW-204: performEdit names a ParamID; the model knows the parameter by its index.
        std::lock_guard lock(impl->edits->mutex);
        for (std::size_t i = 0; i < params; ++i) impl->edits->indexOf.emplace(impl->paramIDs[i], static_cast<uint32_t>(i));
        impl->edits->controller = impl->controller;
        impl->edits->open.assign(params, 0);
        impl->edits->editValue.assign(params, std::numeric_limits<float>::quiet_NaN());
        impl->edits->editTime.assign(params, {});
    }
    impl->pushed = std::make_unique<std::atomic<float>[]>(params);
    impl->syncedToController.assign(params, std::numeric_limits<float>::quiet_NaN());
    for (std::size_t i = 0; i < params; ++i)
        impl->pushed[i].store(std::numeric_limits<float>::quiet_NaN(), std::memory_order_relaxed);

    // DW-242 (T-097): resets run on the reset worker; the instance outlives its registration.
    VST3Instance* self = instance.get();
    instance->reset_ = std::make_unique<PluginReset>([self] { self->clearState(); });
    return instance;
}

// DW-242 (T-097), on the thread that resets before an export, or on the reset worker (PluginReset.h): the plugin
// clears its processing state the way the VST3 docs prescribe, a deactivate/activate cycle
// (setProcessing(false), setActive(false), setActive(true), setProcessing(true)). Its parameters
// and state are kept. The host's own per-render state goes too: held notes (the voices are gone)
// and the transport history.
void VST3Instance::clearState() {
    Impl& impl = *impl_;
    std::lock_guard lock(impl.mutex);
    if (!impl.processing) return;
    impl.processor->setProcessing(false);
    impl.component->setActive(false);
    impl.component->setActive(true);
    impl.processor->setProcessing(true);
    impl.held.clear();
    impl.inEvents.clear();
    impl.inParams.clear();
    impl.hadTransport = false;
    impl.lastEndTick = 0;
}

void VST3Instance::resetNow() { reset_->resetNow(); }
bool VST3Instance::consumeFreshReset() DAW_RT { return reset_->consumeFresh(); }
void VST3Instance::requestReset() DAW_RT { reset_->request(); }
bool VST3Instance::resetBusy() const DAW_RT { return reset_->busy(); }
uint64_t VST3Instance::resetsDone() const { return reset_->completed(); }

bool VST3Instance::hasAudioInput() const { return impl_->mainInput >= 0; }
bool VST3Instance::preparedOffline() const { return impl_->offline; }
bool VST3Instance::acceptsMIDI() const { return impl_->eventInput >= 0; }
bool VST3Instance::hasAuxInput() const { return impl_->auxInput >= 0; }
uint32_t VST3Instance::latencySamples() const { return impl_->latency.load(std::memory_order_acquire); }
double VST3Instance::tailSeconds() const {
    return rate_ > 0 ? impl_->tailSamples / rate_ : 0.0;
}
Steinberg::Vst::IEditController* VST3Instance::editController() const { return impl_->controller; }

// DW-204 (T-063).
void VST3Instance::setEditSink(std::shared_ptr<PluginEditQueue> queue, NodeID slot) {
    std::lock_guard lock(impl_->edits->mutex);
    impl_->edits->queue = std::move(queue);
    impl_->edits->slot = slot;
}

// PLUG-017 / DW-204 (T-063): model values (undo, automation, another control) reach an open editor.
void VST3Instance::syncEditor() {
    std::lock_guard lock(impl_->mutex);
    impl_->syncController();
}

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

Result<void> VST3Instance::prepare(double sampleRate, uint32_t maxBlock) { return prepare(sampleRate, maxBlock, false); }

Result<void> VST3Instance::prepare(double sampleRate, uint32_t maxBlock, bool offline) {
    Impl& impl = *impl_;
    std::lock_guard lock(impl.mutex);
    if (prepared_.load(std::memory_order_acquire) && rate_ == sampleRate && maxBlock_ == maxBlock &&
        impl.offline == offline)
        return {};
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
    impl.outParams.reserve(kMaxOutputParamQueues, kMaxPointsPerOutputQueue);

    // DW-210 (T-097): which parameter each MIDI controller drives, asked once per prepare (a
    // plugin's mapping is static in practice; IMidiMapping has no change notification).
    impl.midiMap.assign(static_cast<std::size_t>(kMidiChannels) * kCountCtrlNumber, -1);
    impl.hasMidiMap = false;
    std::vector<int32> capacities(params_.size(), kSlotPoints);
    if (impl.eventInput >= 0 && impl.controller) {
        FUnknownPtr<IMidiMapping> mapping(impl.controller);
        if (mapping) {
            for (int16 channel = 0; channel < kMidiChannels; ++channel) {
                for (CtrlNumber cc = 0; cc < kCountCtrlNumber; ++cc) {
                    ParamID id = 0;
                    if (mapping->getMidiControllerAssignment(impl.eventInput, channel, cc, id) != kResultTrue) continue;
                    const auto it = impl.indexOfID.find(id);
                    if (it == impl.indexOfID.end()) continue;
                    impl.midiMap[static_cast<std::size_t>(channel) * kCountCtrlNumber + static_cast<std::size_t>(cc)] =
                        static_cast<int32>(it->second);
                    capacities[it->second] = kSlotPoints + kMidiPoints;
                    impl.hasMidiMap = true;
                }
            }
        }
    }
    impl.inParams.reserve(impl.paramIDs, capacities);
    impl.held.clear();

    ProcessSetup setup{};
    // DW-211 (T-097): an offline engine's plugins render in kOffline mode (they may use their
    // high-quality, non-realtime paths), every other kRealtime.
    setup.processMode = offline ? kOffline : kRealtime;
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

    impl.offline = offline;
    impl.data = ProcessData{};
    impl.data.processMode = setup.processMode;
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
    // DW-213 (T-094): value names of stepped parameters, read once.
    if (!impl.labelsRead) {
        impl.labelsRead = true;
        impl.labels.resize(out.size());
        for (std::size_t i = 0; i < out.size(); ++i) {
            const uint32_t steps = out[i].steps;
            if (steps == 0 || steps > VST3ParamInfo::kMaxLabelledSteps) continue;
            std::vector<std::string> names;
            names.reserve(steps + 1);
            for (uint32_t k = 0; k <= steps; ++k) {
                String128 text{};
                if (impl.controller->getParamStringByValue(impl.paramIDs[i], static_cast<ParamValue>(k) / steps, text) !=
                    kResultOk)
                    break;
                names.push_back(string128(text));
            }
            if (names.size() == steps + 1) impl.labels[i] = std::move(names);
        }
    }
    for (std::size_t i = 0; i < out.size(); ++i) {
        const ParamValue value = impl.controller->getParamNormalized(impl.paramIDs[i]);
        out[i].value = static_cast<float>(value);
        String128 text{};
        if (impl.controller->getParamStringByValue(impl.paramIDs[i], value, text) == kResultOk)
            out[i].display = string128(text);
        if (i < impl.labels.size()) out[i].labels = impl.labels[i];
    }
    return out;
}

std::string VST3Instance::displayString(uint32_t index, float normalized) const {
    Impl& impl = *impl_;
    std::lock_guard lock(impl.mutex);
    if (!impl.controller || index >= impl.paramIDs.size() || !std::isfinite(normalized)) return {};
    String128 text{};
    const ParamValue value = std::clamp(static_cast<ParamValue>(normalized), 0.0, 1.0);
    if (impl.controller->getParamStringByValue(impl.paramIDs[index], value, text) != kResultOk) return {};
    return string128(text);
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
    impl.inParams.add(index, 0, normalized);
    impl.pushed[index].store(normalized, std::memory_order_relaxed);
}

// AUTO-003 / DW-233 (T-097): the value holds until the frame before the wrap and jumps at it (a
// queue's points are interpolated linearly, so the hold point keeps the ramp out of the wrap).
void VST3Instance::pushParamJump(uint32_t index, float before, float after, uint32_t frame) DAW_RT {
    Impl& impl = *impl_;
    if (index >= params_.size() || frame == 0) return;
    if (frame > 1) impl.inParams.add(index, static_cast<int32>(frame - 1), before);
    impl.inParams.add(index, static_cast<int32>(frame), after);
    impl.pushed[index].store(after, std::memory_order_relaxed);
}

// DW-210 (T-097): a MIDI controller (CC, channel aftertouch, pitch bend) the plugin maps to a
// parameter (IMidiMapping) becomes a point of that parameter at the event's frame. False when the
// plugin maps nothing to it.
bool VST3Instance::addMappedController(uint8_t channel, uint32_t controller, double normalized, uint32_t frame) DAW_RT {
    Impl& impl = *impl_;
    if (!impl.hasMidiMap || channel >= kMidiChannels || controller >= static_cast<uint32_t>(kCountCtrlNumber)) return false;
    const int32 index = impl.midiMap[std::size_t{channel} * kCountCtrlNumber + controller];
    if (index < 0) return false;
    const float value = static_cast<float>(std::clamp(normalized, 0.0, 1.0));
    impl.inParams.add(static_cast<uint32_t>(index), static_cast<int32>(frame), value);
    // The controller follows (syncController), as a host keeps it in step with mapped changes.
    impl.pushed[static_cast<std::size_t>(index)].store(value, std::memory_order_relaxed);
    return true;
}

void VST3Instance::addMidi(const MidiEvent& event, uint32_t numFrames) DAW_RT {
    Impl& impl = *impl_;
    if (impl.eventInput < 0 || event.size < 2 || numFrames == 0) return;
    const uint8_t status = event.data[0] & 0xF0;
    const uint32_t frame = std::min(event.frameOffset, numFrames - 1);
    // DW-210 (T-097): controllers, channel aftertouch and pitch bend through IMidiMapping.
    switch (status) {
    case 0xB0:  // control change
        if (event.size >= 3) addMappedController(event.data[0] & 0x0F, event.data[1] & 0x7F, (event.data[2] & 0x7F) / 127.0, frame);
        return;
    case 0xD0:  // channel pressure (two bytes)
        addMappedController(event.data[0] & 0x0F, kAfterTouch, (event.data[1] & 0x7F) / 127.0, frame);
        return;
    case 0xE0:  // pitch bend: 14 bits, LSB first; 0x2000 is the centre (0.5)
        if (event.size >= 3)
            addMappedController(event.data[0] & 0x0F, kPitchBend,
                                ((event.data[1] & 0x7F) | ((event.data[2] & 0x7F) << 7)) / 16383.0, frame);
        return;
    default:
        break;
    }
    if (event.size < 3) return;
    const auto channel = static_cast<int16>(event.data[0] & 0x0F);
    const auto pitch = static_cast<int16>(event.data[1] & 0x7F);
    const float velocity = (event.data[2] & 0x7F) / 127.0f;
    Event e{};
    e.busIndex = impl.eventInput;
    e.sampleOffset = static_cast<int32>(frame);
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
        return;  // other messages (program change, poly pressure, system) aren't passed on
    }
    if (impl.inEvents.push(e)) impl.held.track(event);  // DW-225
}

// DW-225 (T-097): note-offs for every note the plugin holds, then All Notes Off (CC 123) on each
// channel that had notes, if the plugin maps CC 123 to a parameter (VST3 has no raw CC input), all
// at `frame`, after the block's other events.
void VST3Instance::releaseHeldNotes(uint32_t frame) DAW_RT {
    Impl& impl = *impl_;
    if (impl.eventInput < 0 || !impl.held.any()) return;
    impl.held.release(
        [&](uint8_t channel, uint8_t key) DAW_RT {
            Event e{};
            e.busIndex = impl.eventInput;
            e.sampleOffset = static_cast<int32>(frame);
            e.flags = Event::kIsLive;
            e.type = Event::kNoteOffEvent;
            e.noteOff.channel = channel;
            e.noteOff.pitch = key;
            e.noteOff.velocity = 0.0f;
            e.noteOff.noteId = -1;
            impl.inEvents.push(e);
        },
        [&](uint8_t channel) DAW_RT { addMappedController(channel, HeldNotes::kAllNotesOff, 0.0, frame); });
}

bool VST3Instance::holdsNotes() const DAW_RT { return impl_->held.any(); }

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
