// PLUG-010/013/014/015/016: AUInstance over AUAudioUnit (see AUInstance.h).
//
// ARC (SwiftPM compiles Objective-C++ with -fobjc-arc): Impl's strong members own the unit and the
// blocks (block properties copy). Non-RT entry points drain an @autoreleasepool, since daw.compile
// and daw.reclaim have no pool of their own. The audio thread never sends a message, retains,
// releases or touches a pool: it only calls blocks Impl already holds (calling a block through a
// strong ivar doesn't retain it).

#include "plugins/AUInstance.h"

#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>

#include <algorithm>
#include <cmath>
#include <atomic>
#include <cstring>
#include <limits>
#include <mutex>
#include <unordered_map>

#include "plugins/PluginEditQueue.h"
#include "time/TempoMap.h"

// The host blocks below are nonblocking (the SDK's block types say so, and their bodies only copy
// or read), but a block literal can't carry noexcept, which clang otherwise asks for.
#pragma clang diagnostic ignored "-Wperf-constraint-implies-noexcept"

namespace daw {

namespace {

constexpr uint32_t kMaxChannels = 2;
constexpr uint32_t kMaxInputBuses = 2;  // main (0) and aux (1, PLUG-014)

Error auError(ErrorCode code, const std::string& what, NSError* error) {
    std::string message = what;
    if (error != nil) message += ": " + std::string(error.localizedDescription.UTF8String ?: "") +
                                 " (" + std::to_string(static_cast<long>(error.code)) + ")";
    return makeError(code, message);
}

std::string str(NSString* s) { return s ? std::string(s.UTF8String ?: "") : std::string(); }

// DW-214. A V2 Audio Unit loaded through AUAudioUnit is wrapped in Apple's AUAudioUnitV2Bridge,
// whose parameter tree is kept up to date by an AUEventListener on a private dispatch queue
// ("AUAudioUnitV2Bridge.eventListener"): every parameter change (our render-thread events, the AU's
// own) is queued and applied to the tree a little later. The listener's block holds the bridge
// weakly and, for a parameter-value-change message, dereferences it without a nil check
// (AudioToolboxCore, macOS 27.0.1: `-[AUAudioUnitV2Bridge _createParameterTree]_block_invoke+120`
// reads an ivar at 0x331 through the nil weak self). So if the bridge's last reference goes away
// while messages are still queued, the listener crashes the process (SIGSEGV at 0x331) as soon as
// dealloc has started. Apple's code; what we control is when that last reference goes:
//   1. ~Impl first stops everything that queues messages: KVO, the host blocks and the render
//      resources (no render, no parameter events, no metering changes after this);
//   2. the unit itself is released on kReleaseQueue after kV2ReleaseGraceSeconds, by which time
//      the listener has drained (it takes ~1–3 ms under heavy load, see AUPluginTests DW-214).
// AUv3 units (in or out of process) have no bridge and are released at once, as before.
constexpr double kV2ReleaseGraceSeconds = 1.0;
std::atomic<uint32_t> gPendingV2Releases{0};

// DW-214. CoreAudio aborts (CAVerboseAbort in AudioUnitInitialize) when one V2 AU is initialized
// while another is being uninitialized on a different thread, which daw.compile (prepare) and
// daw.reclaim (an instance's destruction) can do at the same time. Every lifecycle step
// (allocate/deallocate render resources, the final release) runs under this one process-wide
// lock. Non-RT only; lock order: Impl::mutex, then this.
std::mutex gLifecycleMutex;

dispatch_queue_t releaseQueue() {
    static dispatch_queue_t queue =
        dispatch_queue_create("dev.emberstudio.au-release", dispatch_queue_attr_make_with_qos_class(
                                                                  DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    return queue;
}

// DW-204: a monotonic clock the audio thread may read: CLOCK_UPTIME_RAW comes from the commpage
// (mach_absolute_time), no syscall, no lock. Not annotated nonblocking by the SDK, hence the pragma.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
uint64_t uptimeNanos() DAW_RT { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
#pragma clang diagnostic pop

// True when `component` is a V2 Audio Unit, which AUAudioUnit wraps in the V2 bridge.
bool isV2(AudioComponent component) {
    AudioComponentDescription full{};
    return AudioComponentGetDescription(component, &full) == noErr &&
           (full.componentFlags & kAudioComponentFlag_IsV3AudioUnit) == 0;
}

} // namespace

// PLUG-013: what the KVO observer and its dispatched reports share with the instance.
struct AUInstance::LatencyState {
    std::atomic<uint32_t> samples{0};
    std::atomic<double> rate{0};
    std::mutex mutex;          // guards reporter
    LatencyReporter reporter;  // the node that uses the instance last

    // Non-RT, any thread.
    void update(double seconds) {
        const double r = rate.load(std::memory_order_acquire);
        if (r <= 0 || !(seconds >= 0)) return;
        const auto next = static_cast<uint32_t>(std::min(std::llround(seconds * r), static_cast<long long>(UINT32_MAX)));
        if (samples.exchange(next, std::memory_order_acq_rel) == next) return;
        LatencyReporter copy;
        {
            std::lock_guard lock(mutex);
            copy = reporter;
        }
        copy.changed();
    }
};

} // namespace daw

// KVO on AUAudioUnit.latency (PLUG-013). The callback may come on any thread, the render thread of
// a misbehaving AU included, so it only hops to a global queue, where LatencyState::update runs.
@interface DAWAULatencyObserver : NSObject {
@public
    std::shared_ptr<daw::AUInstance::LatencyState>* state;
}
@end

@implementation DAWAULatencyObserver
- (void)dealloc {
    delete state;
}
- (void)observeValueForKeyPath:(NSString*)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id>*)change
                       context:(void*)context {
    (void)keyPath;
    (void)object;
    (void)context;
    id value = change[NSKeyValueChangeNewKey];
    if (![value isKindOfClass:[NSNumber class]]) return;
    const double seconds = [(NSNumber*)value doubleValue];
    std::shared_ptr<daw::AUInstance::LatencyState> shared = *state;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        shared->update(seconds);
    });
}
@end

namespace daw {

// DW-204 (T-063): the plugin's own parameter edits (its editor's Touch/Value/Release automation
// events) and what keeps the model's echo from fighting them. Shared with the parameter observer
// block and the hold timers, which may outlive the instance.
//
// Echoes. Every value the host pushes (scheduleParam, audio thread) lands in `recent`; the V2
// bridge (DW-214) reports it back to observers a little later as a Value event outside a gesture,
// which matches one of them and is ignored. A Value outside a gesture that matches no recent push
// is the plugin's own (a menu, a preset) and goes to the model ungestured.
//
// Holds. While a gesture is open the node doesn't push the parameter (`gesture`): the model is a
// poll behind the knob, and pushing its older value would make the knob jump back. After a release
// (or an ungestured edit) `hold` keeps the plugin's value until the model's value matches it (that
// push is skipped: the plugin has it) or kHoldNanos pass. The deadline is checked when the node
// asks (no timer, which a loaded machine could delay indefinitely on a low-priority queue).
struct AUInstance::EditState {
    static constexpr uint32_t kRecent = 16;
    static constexpr uint64_t kHoldNanos = 300'000'000;  // 0.3 s

    std::mutex mutex;  // queue, slot, open, lastValue (observer side; never the audio thread)
    std::shared_ptr<PluginEditQueue> queue;
    NodeID slot = 0;
    std::unordered_map<uint64_t, uint32_t> indexOf;  // address → index
    std::vector<uint32_t> open;                       // Touch nesting per index
    std::vector<float> lastValue;
    std::vector<float> tolerance;                     // per index: what counts as the same value

    // Shared with the audio thread (atomics only, sized once).
    std::size_t count = 0;
    std::unique_ptr<std::atomic<bool>[]> gesture;
    std::unique_ptr<std::atomic<float>[]> hold;
    std::unique_ptr<std::atomic<uint64_t>[]> holdUntil;  // CLOCK_UPTIME_RAW nanoseconds
    std::unique_ptr<std::atomic<float>[]> recent;     // kRecent per index
    std::unique_ptr<std::atomic<uint32_t>[]> recentPos;

    void size(const std::vector<AUParamInfo>& params) {
        count = params.size();
        open.assign(count, 0);
        lastValue.assign(count, std::numeric_limits<float>::quiet_NaN());
        tolerance.resize(count);
        gesture = std::make_unique<std::atomic<bool>[]>(count);
        hold = std::make_unique<std::atomic<float>[]>(count);
        holdUntil = std::make_unique<std::atomic<uint64_t>[]>(count);
        recent = std::make_unique<std::atomic<float>[]>(count * kRecent);
        recentPos = std::make_unique<std::atomic<uint32_t>[]>(count);
        for (std::size_t i = 0; i < count; ++i) {
            indexOf.emplace(params[i].address, static_cast<uint32_t>(i));
            tolerance[i] = 1e-5f * std::fabs(params[i].max - params[i].min) + 1e-7f;
            gesture[i].store(false, std::memory_order_relaxed);
            hold[i].store(std::numeric_limits<float>::quiet_NaN(), std::memory_order_relaxed);
            holdUntil[i].store(0, std::memory_order_relaxed);
            recentPos[i].store(0, std::memory_order_relaxed);
        }
        for (std::size_t i = 0; i < count * kRecent; ++i)
            recent[i].store(std::numeric_limits<float>::quiet_NaN(), std::memory_order_relaxed);
    }

    // RT (scheduleParam).
    void pushed(uint32_t index, float value) DAW_RT {
        if (index >= count) return;
        const uint32_t at = recentPos[index].fetch_add(1, std::memory_order_relaxed) % kRecent;
        recent[std::size_t{index} * kRecent + at].store(value, std::memory_order_relaxed);
    }

    bool isEcho(uint32_t index, float value) const {
        for (uint32_t k = 0; k < kRecent; ++k) {
            const float r = recent[std::size_t{index} * kRecent + k].load(std::memory_order_relaxed);
            if (std::fabs(r - value) <= tolerance[index]) return true;
        }
        return false;
    }

    // Caller holds `mutex`.
    void push(uint32_t index, float value, PluginEditKind phase) {
        if (queue) queue->push(PluginParamEdit{slot, index, value, phase});
    }

    // The plugin holds `value` until the model echoes it or kHoldNanos pass.
    static void holdValue(const std::shared_ptr<EditState>& self, uint32_t index, float value) {
        self->holdUntil[index].store(uptimeNanos() + kHoldNanos, std::memory_order_relaxed);
        self->hold[index].store(value, std::memory_order_release);
    }

    // From the parameter tree's automation observer (an internal queue; non-RT).
    static void observe(const std::shared_ptr<EditState>& self, uint64_t address, float value,
                        AUParameterAutomationEventType type) {
        std::lock_guard lock(self->mutex);
        const auto it = self->indexOf.find(address);
        if (it == self->indexOf.end()) return;
        const uint32_t i = it->second;
        switch (type) {
        case AUParameterAutomationEventTypeTouch:
            if (self->open[i]++ == 0) {
                self->gesture[i].store(true, std::memory_order_release);
                self->push(i, value, PluginEditKind::begin);
            }
            break;
        case AUParameterAutomationEventTypeRelease:
            if (self->open[i] == 0 || --self->open[i] > 0) break;
            if (!std::isnan(self->lastValue[i])) holdValue(self, i, self->lastValue[i]);
            self->gesture[i].store(false, std::memory_order_release);
            self->push(i, value, PluginEditKind::end);
            break;
        default:  // Value
            if (self->open[i] == 0 && self->isEcho(i, value)) break;
            // A V2 bridge reports the plugin's own value back once more; while that value is held it
            // was reported already (re-holding it would keep the model from ever leading again).
            if (self->open[i] == 0 && std::fabs(self->hold[i].load(std::memory_order_acquire) - value) <= self->tolerance[i]) break;
            self->lastValue[i] = value;
            if (self->open[i] == 0) holdValue(self, i, value);
            self->push(i, value, PluginEditKind::value);
            break;
        }
    }

    // RT (AUPluginNode): whether the host may push `value` to parameter `index` now.
    AUInstance::PushDecision decide(uint32_t index, float value) DAW_RT {
        if (index >= count) return PushDecision::push;
        if (gesture[index].load(std::memory_order_acquire)) return PushDecision::defer;
        float held = hold[index].load(std::memory_order_acquire);
        if (held != held) return PushDecision::push;  // NaN: nothing held
        if (uptimeNanos() > holdUntil[index].load(std::memory_order_relaxed)) {
            // Held long enough without the model catching up: the model leads again.
            hold[index].compare_exchange_strong(held, std::numeric_limits<float>::quiet_NaN(), std::memory_order_acq_rel);
            return PushDecision::push;
        }
        if (std::fabs(held - value) > tolerance[index]) return PushDecision::defer;
        hold[index].compare_exchange_strong(held, std::numeric_limits<float>::quiet_NaN(), std::memory_order_acq_rel);
        return PushDecision::skip;  // the model caught up with the plugin, which has the value
    }
};

// What the host transport blocks report (written by setTransport on the audio thread, read by the
// AU from the same thread during render).
struct HostTransport {
    double tempo = 120.0;
    double beatPosition = 0;      // quarter notes from tick 0
    double downbeatPosition = 0;  // the bar's start, in quarter notes
    double timeSigNum = 4;
    NSInteger timeSigDen = 4;
    double samplePosition = 0;
    bool playing = false;
    bool moved = false;
};

struct AUInstance::Impl {
    AUAudioUnit* unit = nil;
    bool bridged = false;                          // a V2 AU behind AUAudioUnitV2Bridge (DW-214)
    DAWAULatencyObserver* observer = nil;          // registered on unit
    AURenderBlock renderBlock = nil;               // taken at prepare
    AUScheduleMIDIEventBlock midiBlock = nil;      // taken at prepare (nil: no MIDI)
    AUScheduleParameterBlock paramBlock = nil;     // taken at prepare
    AURenderPullInputBlock pullBlock = nil;        // made at prepare
    mutable std::mutex mutex;                      // non-RT calls

    // RT state.
    AudioBufferList* outList = nullptr;            // kMaxChannels buffers
    std::vector<float> outScratch;                 // kMaxChannels × maxBlock
    std::vector<float> inScratch;                  // kMaxInputBuses × kMaxChannels × maxBlock
    uint32_t maxBlock = 0;
    const AudioBufferView* curIn = nullptr;        // this render's inputs, for pullBlock
    const AudioBufferView* curSidechain = nullptr;
    double sampleTime = 0;
    HostTransport host;
    bool hadTransport = false;
    Tick lastEndTick = 0;
    std::vector<uint64_t> addresses;               // params_[i].address
    // DW-204: the automation observer and the tree it is on. A V2 bridge builds a new tree when
    // the AU reports a parameter-list change (setting its formats or state can), so the observer
    // moves to the unit's current tree after every non-RT step that may change it.
    AUParameterTree* editTree = nil;
    AUParameterObserverToken editToken = nullptr;
    std::weak_ptr<AUInstance::EditState> edits;

    void observeEdits() {
        AUParameterTree* tree = unit.parameterTree;
        if (tree == editTree) return;
        if (editTree != nil && editToken != nullptr) [editTree removeParameterObserver:editToken];
        editTree = tree;
        editToken = nullptr;
        if (tree == nil) return;
        std::weak_ptr<AUInstance::EditState> weak = edits;
        editToken = [tree tokenByAddingParameterAutomationObserver:^(NSInteger count,
                                                                     const AUParameterAutomationEvent* events) {
            auto state = weak.lock();
            if (!state) return;
            for (NSInteger e = 0; e < count; ++e)
                AUInstance::EditState::observe(state, events[e].address, events[e].value, events[e].eventType);
        }];
    }

    ~Impl() {
        if (unit != nil) {
            if (observer != nil) [unit removeObserver:observer forKeyPath:@"latency"];
            if (editTree != nil && editToken != nullptr) [editTree removeParameterObserver:editToken];  // DW-204
            std::lock_guard lifecycle(gLifecycleMutex);  // DW-214
            if (unit.renderResourcesAllocated) [unit deallocateRenderResources];
            // The host blocks point at this Impl, which is going away (the unit may outlive it).
            unit.musicalContextBlock = nil;
            unit.transportStateBlock = nil;
            if (bridged) {
                // DW-214: the bridge's last reference goes after its listener has drained.
                __block AUAudioUnit* held = unit;
                unit = nil;
                gPendingV2Releases.fetch_add(1, std::memory_order_relaxed);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(kV2ReleaseGraceSeconds * NSEC_PER_SEC)),
                               releaseQueue(), ^{
                                   std::lock_guard lifecycle(gLifecycleMutex);
                                   @autoreleasepool {
                                       held = nil;  // the last reference: the bridge deallocates here
                                   }
                                   gPendingV2Releases.fetch_sub(1, std::memory_order_relaxed);
                               });
            }
            unit = nil;  // an AUv3's release (dispose) happens here, under the lock too
        }
        std::free(outList);
    }

    // RT: copies `src` (or silence) into an input bus's buffers.
    void fillInput(uint32_t bus, const AudioBufferView* src, AUAudioFrameCount frames, AudioBufferList* data) DAW_RT {
        const uint32_t n = std::min<uint32_t>(data->mNumberBuffers, kMaxChannels);
        const std::size_t bytes = std::size_t{frames} * sizeof(float);
        for (uint32_t b = 0; b < n; ++b) {
            AudioBuffer& buffer = data->mBuffers[b];
            if (buffer.mData == nullptr)
                buffer.mData = inScratch.data() + (std::size_t{bus} * kMaxChannels + b) * maxBlock;
            buffer.mDataByteSize = static_cast<UInt32>(bytes);
            auto* dst = static_cast<float*>(buffer.mData);
            const bool has = src != nullptr && !src->empty() && src->numFrames >= frames;
            if (!has) {
                std::memset(dst, 0, bytes);
            } else if (n == 1 && src->numChannels >= 2) {
                // A mono bus gets the mid of a stereo source.
                const float* l = src->channels[0];
                const float* r = src->channels[1];
                for (uint32_t i = 0; i < frames; ++i) dst[i] = 0.5f * (l[i] + r[i]);
            } else {
                std::memcpy(dst, src->channels[std::min(b, src->numChannels - 1)], bytes);
            }
        }
        return;
    }
};

AUInstance::AUInstance(const AUComponentID& component)
    : component_(component), impl_(new Impl), latency_(std::make_shared<LatencyState>()),
      edits_(std::make_shared<EditState>()) {}

AUInstance::~AUInstance() {
    @autoreleasepool {
        delete impl_;
    }
}

Result<std::shared_ptr<AUInstance>> AUInstance::instantiate(const AUComponentID& component, double timeoutSeconds) {
    @autoreleasepool {
        AudioComponentDescription desc{component.type, component.subtype, component.manufacturer, 0, 0};
        AudioComponent found = AudioComponentFindNext(nullptr, &desc);
        if (found == nullptr)
            return makeError(ErrorCode::notFound, "no Audio Unit " + formatAUIdentifier(component) + " is installed");

        NSError* error = nil;
        AUAudioUnit* unit = [[AUAudioUnit alloc] initWithComponentDescription:desc
                                                                      options:kAudioComponentInstantiation_LoadInProcess
                                                                        error:&error];
        if (unit == nil) {
            // PLUG-010: an AUv3 app extension that can't load in-process runs out of process.
            AudioComponentDescription full{};
            AudioComponentGetDescription(found, &full);
            if ((full.componentFlags & kAudioComponentFlag_IsV3AudioUnit) == 0)
                return auError(ErrorCode::unsupported, "can't instantiate " + formatAUIdentifier(component), error);
            struct Pending {
                dispatch_semaphore_t done = dispatch_semaphore_create(0);
                std::mutex mutex;
                AUAudioUnit* unit = nil;
                bool abandoned = false;
            };
            auto pending = std::make_shared<Pending>();
            [AUAudioUnit instantiateWithComponentDescription:desc
                                                     options:kAudioComponentInstantiation_LoadOutOfProcess
                                           completionHandler:^(AUAudioUnit* made, NSError* e) {
                                               (void)e;
                                               std::lock_guard lock(pending->mutex);
                                               if (!pending->abandoned) pending->unit = made;
                                               dispatch_semaphore_signal(pending->done);
                                           }];
            const auto wait = dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(timeoutSeconds * NSEC_PER_SEC));
            const bool signalled = dispatch_semaphore_wait(pending->done, wait) == 0;
            std::lock_guard lock(pending->mutex);
            if (!signalled || pending->unit == nil) {
                pending->abandoned = true;
                return makeError(signalled ? ErrorCode::unsupported : ErrorCode::io,
                                 "can't instantiate " + formatAUIdentifier(component) +
                                     (signalled ? " out of process" : ": out-of-process instantiation timed out"));
            }
            unit = pending->unit;
            pending->unit = nil;
        }

        std::shared_ptr<AUInstance> instance(new AUInstance(component));
        Impl& impl = *instance->impl_;
        impl.unit = unit;
        impl.bridged = isV2(found);

        // PLUG-015: index i ↔ allParameters[i], fixed for the instance.
        for (AUParameter* p in unit.parameterTree.allParameters) {
            AUParamInfo info;
            info.address = p.address;
            info.identifier = str(p.identifier);
            info.name = str(p.displayName);
            info.unit = str(p.unitName);
            info.min = p.minValue;
            info.max = p.maxValue;
            info.value = p.value;
            info.canRamp = (p.flags & kAudioUnitParameterFlag_CanRamp) != 0;
            info.writable = (p.flags & kAudioUnitParameterFlag_IsWritable) != 0;
            instance->params_.push_back(std::move(info));
            impl.addresses.push_back(p.address);
        }

        // DW-204 (T-063): the plugin's own edits (its editor's gestures), from now on.
        instance->edits_->size(instance->params_);
        impl.edits = instance->edits_;
        impl.observeEdits();
        // PLUG-013: observe latency changes from now on.
        impl.observer = [[DAWAULatencyObserver alloc] init];
        impl.observer->state = new std::shared_ptr<LatencyState>(instance->latency_);
        [unit addObserver:impl.observer forKeyPath:@"latency" options:NSKeyValueObservingOptionNew context:nullptr];
        return instance;
    }
}

std::string AUInstance::name() const {
    @autoreleasepool {
        return str(impl_->unit.audioUnitName);
    }
}

bool AUInstance::hasAudioInput() const {
    @autoreleasepool {
        return impl_->unit.inputBusses.count > 0;
    }
}

bool AUInstance::acceptsMIDI() const {
    @autoreleasepool {
        return impl_->unit.scheduleMIDIEventBlock != nil;
    }
}

bool AUInstance::hasAuxInput() const {
    @autoreleasepool {
        return impl_->unit.inputBusses.count > 1;
    }
}

double AUInstance::tailSeconds() const {
    @autoreleasepool {
        return impl_->unit.tailTime;
    }
}

uint32_t AUInstance::pendingV2Releases() { return gPendingV2Releases.load(std::memory_order_relaxed); }

// DW-204 (T-063).
void AUInstance::setEditSink(std::shared_ptr<PluginEditQueue> queue, NodeID slot) {
    std::lock_guard lock(edits_->mutex);
    edits_->queue = std::move(queue);
    edits_->slot = slot;
}

// PLUG-017 (T-063): the unit, for its view controller (main thread).
void* AUInstance::audioUnit() const { return (__bridge void*)impl_->unit; }

uint32_t AUInstance::latencySamples() const { return latency_->samples.load(std::memory_order_acquire); }

void AUInstance::setLatencyReporter(LatencyReporter reporter) {
    std::lock_guard lock(latency_->mutex);
    latency_->reporter = std::move(reporter);
}

namespace {

// Sets `bus` to stereo at `rate`, or else to its own channel count (1 or 2). Returns the channels.
uint32_t setBusFormat(AUAudioUnitBus* bus, double rate) {
    for (AVAudioChannelCount channels : {AVAudioChannelCount(2), bus.format.channelCount, AVAudioChannelCount(1)}) {
        if (channels == 0 || channels > kMaxChannels) continue;
        AVAudioFormat* format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:channels];
        if (format != nil && [bus setFormat:format error:nil]) return channels;
    }
    return 0;
}

} // namespace

Result<void> AUInstance::prepare(double sampleRate, uint32_t maxBlock) {
    @autoreleasepool {
        Impl& impl = *impl_;
        std::lock_guard lock(impl.mutex);
        if (prepared_.load(std::memory_order_acquire) && rate_ == sampleRate && maxBlock_ == maxBlock) return {};
        std::lock_guard lifecycle(gLifecycleMutex);  // DW-214: (de)initialize one AU at a time
        AUAudioUnit* unit = impl.unit;
        prepared_.store(false, std::memory_order_release);
        if (unit.renderResourcesAllocated) [unit deallocateRenderResources];

        if (unit.outputBusses.count == 0)
            return makeError(ErrorCode::unsupported, identifier() + " has no output bus");
        const uint32_t out = setBusFormat(unit.outputBusses[0], sampleRate);
        if (out == 0) return makeError(ErrorCode::unsupported, identifier() + ": no mono or stereo output format");
        uint32_t in = 0, side = 0;
        if (unit.inputBusses.count > 0) {
            in = setBusFormat(unit.inputBusses[0], sampleRate);
            if (in == 0) return makeError(ErrorCode::unsupported, identifier() + ": no mono or stereo input format");
            // An input bus must be enabled, or the AU never pulls it (render fails with
            // kAudioUnitErr_NoConnection).
            unit.inputBusses[0].enabled = YES;
        }
        if (unit.inputBusses.count > 1) {
            // PLUG-014: the aux bus is the sidechain; an AU that refuses a format runs without one.
            side = setBusFormat(unit.inputBusses[1], sampleRate);
            unit.inputBusses[1].enabled = side > 0;
        }
        for (NSUInteger b = 1; b < unit.outputBusses.count; ++b) unit.outputBusses[b].enabled = NO;
        unit.maximumFramesToRender = maxBlock;

        // Host transport (read by tempo-synced plugins during render; same thread as setTransport).
        Impl* self = &impl;
        unit.musicalContextBlock = ^BOOL(double* tempo, double* num, NSInteger* den, double* beat,
                                         NSInteger* toNextBeat, double* downbeat) __attribute__((nonblocking)) {
            const HostTransport& h = self->host;
            if (tempo) *tempo = h.tempo;
            if (num) *num = h.timeSigNum;
            if (den) *den = h.timeSigDen;
            if (beat) *beat = h.beatPosition;
            if (toNextBeat) *toNextBeat = 0;
            if (downbeat) *downbeat = h.downbeatPosition;
            return YES;
        };
        unit.transportStateBlock = ^BOOL(AUHostTransportStateFlags* flags, double* position, double* cycleStart,
                                         double* cycleEnd) __attribute__((nonblocking)) {
            const HostTransport& h = self->host;
            if (flags) {
                AUHostTransportStateFlags f = 0;
                if (h.playing) f |= AUHostTransportStateMoving;
                if (h.moved) f |= AUHostTransportStateChanged;
                *flags = f;
            }
            if (position) *position = h.samplePosition;
            if (cycleStart) *cycleStart = 0;
            if (cycleEnd) *cycleEnd = 0;
            return YES;
        };

        NSError* error = nil;
        if (![unit allocateRenderResourcesAndReturnError:&error])
            return auError(ErrorCode::unsupported, "can't allocate render resources for " + identifier(), error);

        // Everything the render path touches, made now.
        impl.renderBlock = unit.renderBlock;
        impl.midiBlock = unit.scheduleMIDIEventBlock;
        impl.paramBlock = unit.scheduleParameterBlock;
        impl.pullBlock = ^AUAudioUnitStatus(AudioUnitRenderActionFlags* flags, const AudioTimeStamp* timestamp,
                                             AUAudioFrameCount frames, NSInteger bus, AudioBufferList* data) __attribute__((nonblocking)) {
            (void)flags;
            (void)timestamp;
            if (bus < 0 || bus >= static_cast<NSInteger>(kMaxInputBuses) || frames > self->maxBlock) return kAudioUnitErr_InvalidElement;
            self->fillInput(static_cast<uint32_t>(bus), bus == 0 ? self->curIn : self->curSidechain, frames, data);
            return noErr;
        };
        impl.maxBlock = maxBlock;
        impl.outScratch.assign(std::size_t{kMaxChannels} * maxBlock, 0.0f);
        impl.inScratch.assign(std::size_t{kMaxInputBuses} * kMaxChannels * maxBlock, 0.0f);
        if (impl.outList == nullptr)
            impl.outList = static_cast<AudioBufferList*>(
                std::calloc(1, offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * kMaxChannels));

        rate_ = sampleRate;
        maxBlock_ = maxBlock;
        inChannels_ = in;
        outChannels_ = out;
        sidechainChannels_ = side;
        latency_->rate.store(sampleRate, std::memory_order_release);
        latency_->samples.store(
            static_cast<uint32_t>(std::max(0.0, std::round(unit.latency * sampleRate))), std::memory_order_release);
        impl.observeEdits();  // DW-204: the formats may have rebuilt a V2 bridge's tree
        prepared_.store(true, std::memory_order_release);
        return {};
    }
}

std::vector<AUParamInfo> AUInstance::params(bool current) const {
    if (!current) return params_;
    @autoreleasepool {
        std::lock_guard lock(impl_->mutex);
        std::vector<AUParamInfo> out = params_;
        AUParameterTree* tree = impl_->unit.parameterTree;
        for (AUParamInfo& p : out)
            if (AUParameter* live = [tree parameterWithAddress:p.address]) p.value = live.value;
        return out;
    }
}

Result<std::vector<uint8_t>> AUInstance::fullState() const {
    @autoreleasepool {
        std::lock_guard lock(impl_->mutex);
        NSDictionary* state = impl_->unit.fullState;
        if (state == nil) return std::vector<uint8_t>{};
        NSError* error = nil;
        NSData* data = [NSPropertyListSerialization dataWithPropertyList:state
                                                                  format:NSPropertyListBinaryFormat_v1_0
                                                                 options:0
                                                                   error:&error];
        if (data == nil) return auError(ErrorCode::internal, identifier() + ": fullState isn't a plist", error);
        const auto* p = static_cast<const uint8_t*>(data.bytes);
        return std::vector<uint8_t>(p, p + data.length);
    }
}

Result<void> AUInstance::setFullState(const std::vector<uint8_t>& state) {
    @autoreleasepool {
        std::lock_guard lock(impl_->mutex);
        NSData* data = [NSData dataWithBytes:state.data() length:state.size()];
        NSError* error = nil;
        id plist = [NSPropertyListSerialization propertyListWithData:data
                                                             options:NSPropertyListImmutable
                                                              format:nullptr
                                                               error:&error];
        if (![plist isKindOfClass:[NSDictionary class]])
            return auError(ErrorCode::invalidArgument, identifier() + ": state isn't a plist dictionary", error);
        impl_->unit.fullState = plist;
        impl_->observeEdits();  // DW-204
        return {};
    }
}

// MARK: RT

void AUInstance::scheduleParam(uint32_t index, float value, uint32_t rampFrames) DAW_RT {
    Impl& impl = *impl_;
    if (impl.paramBlock == nil || index >= impl.addresses.size()) return;
    edits_->pushed(index, value);  // DW-204: its echo isn't a plugin edit
    impl.paramBlock(AUEventSampleTimeImmediate, rampFrames, impl.addresses[index], value);
}

AUInstance::PushDecision AUInstance::pushDecision(uint32_t index, float value) DAW_RT {
    return edits_->decide(index, value);
}

void AUInstance::scheduleMIDI(const MidiEvent& event, uint32_t numFrames) DAW_RT {
    Impl& impl = *impl_;
    if (impl.midiBlock == nil || event.size == 0 || numFrames == 0) return;
    // PLUG-010: frame offsets relative to the next render.
    const uint32_t offset = std::min(event.frameOffset, numFrames - 1);
    impl.midiBlock(AUEventSampleTimeImmediate + offset, 0, event.size, event.data);
}

void AUInstance::setTransport(const TransportBlock& transport) DAW_RT {
    HostTransport& h = impl_->host;
    h.playing = transport.playing;
    if (transport.numSegments == 0 || transport.tempo == nullptr) {
        h.moved = false;
        return;
    }
    const TransportSegment& seg = transport.seg[0];
    const TempoMap& map = *transport.tempo;
    h.moved = !impl_->hadTransport || seg.startTick != impl_->lastEndTick;
    impl_->hadTransport = true;
    impl_->lastEndTick = transport.seg[transport.numSegments - 1].endTick;
    h.tempo = map.bpmAt(seg.startTick);
    h.beatPosition = static_cast<double>(seg.startTick) / kPPQ;
    h.samplePosition = static_cast<double>(seg.startSample);
    const BBT bbt = map.tickToBBT(seg.startTick);
    h.downbeatPosition = static_cast<double>(map.bbtToTick(BBT{bbt.bar, 1, 0})) / kPPQ;
    // The signature in force: the last event at or before the tick (bounded by the map's events).
    const size_t n = map.timeSigEventCount();
    for (size_t i = 0; i < n; ++i) {
        const TimeSigEvent e = map.timeSigEvent(i);
        if (e.tick > seg.startTick) break;
        h.timeSigNum = e.num;
        h.timeSigDen = e.den;
    }
}

bool AUInstance::render(const NodeIO& io, uint32_t numFrames) DAW_RT {
    Impl& impl = *impl_;
    if (impl.renderBlock == nil || numFrames == 0 || numFrames > impl.maxBlock) return false;
    impl.curIn = &io.audioIn;
    impl.curSidechain = &io.sidechain;

    AudioBufferList* list = impl.outList;
    list->mNumberBuffers = outChannels_;
    const UInt32 bytes = numFrames * sizeof(float);
    for (uint32_t c = 0; c < outChannels_; ++c)
        list->mBuffers[c] = AudioBuffer{1, bytes, impl.outScratch.data() + std::size_t{c} * impl.maxBlock};

    AudioTimeStamp timestamp{};
    timestamp.mSampleTime = impl.sampleTime;
    timestamp.mFlags = kAudioTimeStampSampleTimeValid;
    AudioUnitRenderActionFlags flags = 0;
    const AUAudioUnitStatus status = impl.renderBlock(&flags, &timestamp, numFrames, 0, list,
                                                      inChannels_ + sidechainChannels_ > 0 ? impl.pullBlock : (AURenderPullInputBlock)nil);
    impl.sampleTime += numFrames;
    impl.curIn = nullptr;
    impl.curSidechain = nullptr;
    if (status != noErr) {
        renderErrors_.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    // The AU may have rendered into buffers of its own (mData replaced): read whatever it left.
    for (uint32_t c = 0; c < io.audioOut.numChannels; ++c) {
        const uint32_t from = std::min(c, outChannels_ - 1);
        const auto* src = static_cast<const float*>(list->mBuffers[from].mData);
        if (src == nullptr) std::memset(io.audioOut.channels[c], 0, bytes);
        else std::memcpy(io.audioOut.channels[c], src, bytes);
    }
    return true;
}

} // namespace daw
