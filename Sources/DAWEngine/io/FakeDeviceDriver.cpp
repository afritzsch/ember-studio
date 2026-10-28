#include "io/FakeDeviceDriver.h"

#include <pthread.h>
#include <pthread/qos.h>

#include <algorithm>
#include <atomic>
#include <bit>
#include <cstring>
#include <mutex>
#include <thread>

#include "core/Engine.h"
#include "core/Node.h"
#include "core/RtTrap.h"
#include "core/SpscQueue.h"
#include "io/DeviceRenderer.h"

namespace daw {

namespace {

// Like AUHAL's maximum slice (CoreAudioDriver): a cycle is at most this many frames.
constexpr uint32_t kMaxCycleFrames = kMaxBlock;

// What events change about a device; read by any thread.
struct DeviceRuntime {
    std::atomic<bool> alive{true};
    std::atomic<double> nominalRate{0};
};

// Non-interleaved float channels, allocated before the render thread starts.
class ChannelBuffers {
public:
    void allocate(uint32_t channels, uint64_t frames) {
        storage_.assign(std::size_t{channels} * frames, 0.0f);
        pointers_.resize(channels);
        for (uint32_t c = 0; c < channels; ++c) pointers_[c] = storage_.data() + c * frames;
    }
    float* const* channels() const DAW_RT { return pointers_.data(); }
    float* channel(uint32_t c) const DAW_RT { return pointers_[c]; }

private:
    std::vector<float> storage_;
    std::vector<float*> pointers_;
};

bool knownDevice(const FakeDeviceSpec& spec, AudioDeviceRef id) {
    return std::any_of(spec.devices.begin(), spec.devices.end(), [id](const FakeDevice& d) { return d.id == id; });
}

Result<void> validate(const FakeDeviceSpec& spec) {
    if (spec.devices.empty()) return makeError(ErrorCode::invalidArgument, "fake device spec: no devices");
    for (std::size_t i = 0; i < spec.devices.size(); ++i) {
        const AudioDeviceRef id = spec.devices[i].id;
        if (id == 0) return makeError(ErrorCode::invalidArgument, "fake device spec: device ID 0");
        for (std::size_t j = 0; j < i; ++j)
            if (spec.devices[j].id == id)
                return makeError(ErrorCode::invalidArgument, "fake device spec: duplicate device ID");
    }
    if (spec.defaultOutput != 0 && !knownDevice(spec, spec.defaultOutput))
        return makeError(ErrorCode::invalidArgument, "fake device spec: unknown default output");
    for (uint32_t frames : spec.cycleFrames)
        if (frames == 0 || frames > kMaxCycleFrames)
            return makeError(ErrorCode::invalidArgument, "fake device spec: cycle frames outside 1…kMaxBlock");
    for (std::size_t i = 0; i < spec.script.size(); ++i) {
        const FakeDeviceEvent& event = spec.script[i];
        if (i > 0 && event.atFrame < spec.script[i - 1].atFrame)
            return makeError(ErrorCode::invalidArgument, "fake device spec: script not in atFrame order");
        if (event.device != 0 && !knownDevice(spec, event.device))
            return makeError(ErrorCode::invalidArgument, "fake device spec: script names an unknown device");
        if (event.type == FakeDeviceEventType::sampleRateChanged && !isSessionRate(event.sampleRate))
            return makeError(ErrorCode::invalidArgument, "fake device spec: script changes to a non-session rate");
    }
    return {};
}

uint32_t saturatingAdd(uint32_t a, uint32_t b) {
    const uint64_t sum = uint64_t{a} + b;
    return sum < UINT32_MAX ? static_cast<uint32_t>(sum) : UINT32_MAX;
}

} // namespace

struct FakeDeviceDriver::Impl {
    Impl(Engine& e, FakeDeviceSpec s)
        : engine(e), spec(std::move(s)), renderer(e),
          state(std::make_unique<DeviceRuntime[]>(spec.devices.size())), limit(spec.cycleLimit) {
        for (std::size_t i = 0; i < spec.devices.size(); ++i)
            state[i].nominalRate.store(spec.devices[i].output.nominalRate, std::memory_order_relaxed);
        defaultOutput.store(spec.defaultOutput != 0 ? spec.defaultOutput
                                                    : (spec.devices.empty() ? 0 : spec.devices[0].id));
    }

    Engine& engine;
    const FakeDeviceSpec spec;
    DeviceRenderer renderer;
    std::unique_ptr<DeviceRuntime[]> state;  // one per spec.devices entry
    std::atomic<AudioDeviceRef> defaultOutput{0};

    // Control side. The render thread never takes the mutex.
    mutable std::mutex control;  // start, stop, inject
    std::atomic<bool> running{false};
    RunningConfig config;
    DeviceLatency latency;
    std::thread thread;

    // The run: set up by start() before the thread starts, then used by the render thread only.
    std::size_t deviceIndex = 0;
    ChannelBuffers output, input, ring;
    uint32_t ringChannels = 0;  // loopback channels (0: no loopback)
    uint64_t ringMask = 0;
    uint32_t loopbackDelay = 0;
    uint64_t runFrames = 0;     // frames of this run (loopback positions)
    std::size_t scriptNext = 0; // render thread only; carries over between runs

    // Render thread wake-ups: every control call that may give it work bumps `wake`.
    std::atomic<bool> stopRequested{false};
    std::atomic<uint32_t> wake{0};
    std::atomic<uint64_t> limit;
    // Parked with nothing to do, under `parkedLimit` (waitUntilIdle compares it with `limit`).
    std::atomic<bool> parked{false};
    std::atomic<uint64_t> parkedLimit{0};
    std::atomic<uint64_t> violations{0};

    // inject() → render thread (pushed under `control`), and the IO-020 seam out.
    SpscQueue<FakeDeviceEvent, 64> commands;
    uint64_t commandsPushed = 0;  // under `control`
    std::atomic<uint64_t> commandsApplied{0};
    SpscQueue<DeviceNotification, kNotificationCapacity> notifications;
    std::atomic<uint64_t> dropped{0};

    int indexOf(AudioDeviceRef id) const {
        for (std::size_t i = 0; i < spec.devices.size(); ++i)
            if (spec.devices[i].id == id) return static_cast<int>(i);
        return -1;
    }

    // `running`: the device the driver runs on, 0 while stopped. Off the RT scope, but allocation-
    // and lock-free all the same: the render thread calls it between cycles.
    AudioDeviceRef target(const FakeDeviceEvent& event, AudioDeviceRef runningDevice) const {
        if (event.device != 0) return event.device;
        return runningDevice != 0 ? runningDevice : defaultOutput.load(std::memory_order_acquire);
    }

    void notify(DeviceNotificationType type, AudioDeviceRef device, bool alive = false, double rate = 0) {
        DeviceNotification n;
        n.type = type;
        n.device = device;
        n.alive = alive;
        n.sampleRate = rate;
        n.frame = renderer.frames();
        if (!notifications.push(n)) dropped.fetch_add(1, std::memory_order_relaxed);
    }

    // On the render thread while running, else on the control thread (under `control`), so the
    // notification queue has one producer at a time.
    void apply(const FakeDeviceEvent& event, AudioDeviceRef runningDevice) {
        const AudioDeviceRef id = target(event, runningDevice);
        const int index = indexOf(id);
        if (index < 0) return;
        DeviceRuntime& device = state[index];
        switch (event.type) {
            case FakeDeviceEventType::deviceLost: {
                if (!device.alive.exchange(false, std::memory_order_acq_rel)) return;
                notify(DeviceNotificationType::aliveChanged, id, false);
                notify(DeviceNotificationType::devicesChanged, id);
                if (defaultOutput.load(std::memory_order_acquire) == id) {
                    AudioDeviceRef next = 0;
                    for (std::size_t i = 0; i < spec.devices.size() && next == 0; ++i)
                        if (state[i].alive.load(std::memory_order_acquire)) next = spec.devices[i].id;
                    defaultOutput.store(next, std::memory_order_release);
                    notify(DeviceNotificationType::defaultOutputChanged, next);
                }
                break;
            }
            case FakeDeviceEventType::deviceRestored: {
                if (device.alive.exchange(true, std::memory_order_acq_rel)) return;
                notify(DeviceNotificationType::aliveChanged, id, true);
                notify(DeviceNotificationType::devicesChanged, id);
                if (defaultOutput.load(std::memory_order_acquire) == 0) {
                    defaultOutput.store(id, std::memory_order_release);
                    notify(DeviceNotificationType::defaultOutputChanged, id);
                }
                break;
            }
            case FakeDeviceEventType::sampleRateChanged: {
                if (!supportsRate(spec.devices[index].output, event.sampleRate)) return;
                if (device.nominalRate.exchange(event.sampleRate, std::memory_order_acq_rel) == event.sampleRate) return;
                notify(DeviceNotificationType::nominalRateChanged, id, false, event.sampleRate);
                break;
            }
            case FakeDeviceEventType::processorOverload:
                engine.telemetry().countXrun();  // IO-023, DW-049: as CoreAudioDriver counts them
                notify(DeviceNotificationType::processorOverload, id);
                break;
        }
    }

    void wakeThread() {
        wake.fetch_add(1, std::memory_order_acq_rel);
        wake.notify_all();
    }

    uint32_t cycleLength() const {
        if (spec.cycleFrames.empty()) return config.bufferFrames;
        return spec.cycleFrames[renderer.cycles() % spec.cycleFrames.size()];
    }

    // IO-001: one IO cycle, like CoreAudioDriver's render callback: the device input (here the
    // loopback), Engine::render through the DeviceRenderer, then the output goes to the device
    // (into the loopback). All of it inside one RtScope (CONV §5.3).
    void runCycle(uint32_t numFrames, uint64_t startFrame) DAW_RT {
        RtScope scope;
        const uint32_t inChannels = config.inputChannels;
        const uint32_t outChannels = config.outputChannels;
        for (uint32_t c = 0; c < inChannels; ++c) {
            float* dest = input.channel(c);
            if (c >= ringChannels) {
                std::memset(dest, 0, std::size_t{numFrames} * sizeof(float));
                continue;
            }
            const float* past = ring.channel(c);
            for (uint32_t f = 0; f < numFrames; ++f) {
                const uint64_t position = runFrames + f;
                dest[f] = position >= loopbackDelay ? past[(position - loopbackDelay) & ringMask] : 0.0f;
            }
        }

        renderer.renderCycle(output.channels(), outChannels, input.channels(), inChannels, numFrames);

        for (uint32_t c = 0; c < ringChannels; ++c) {
            const float* src = output.channel(c);
            float* dest = ring.channel(c);
            for (uint32_t f = 0; f < numFrames; ++f) dest[(runFrames + f) & ringMask] = src[f];
        }
        runFrames += numFrames;

        if (spec.tap != nullptr) {
            FakeCycle cycle;
            cycle.input = input.channels();
            cycle.inputChannels = inChannels;
            cycle.output = output.channels();
            cycle.outputChannels = outChannels;
            cycle.numFrames = numFrames;
            cycle.startFrame = startFrame;
            spec.tap(spec.tapContext, cycle);
        }
        violations.fetch_add(scope.violations(), std::memory_order_relaxed);
    }

    void threadMain() {
        pthread_setname_np("daw.audio");  // CONV §3
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        using Clock = std::chrono::steady_clock;
        const AudioDeviceRef device = config.outputDevice;
        const DeviceRuntime& runtime = state[deviceIndex];
        Clock::time_point deadline{};
        bool resync = true;
        for (;;) {
            const uint32_t seen = wake.load(std::memory_order_acquire);
            // Events first, so one injected just before stop() is still applied. Bounded by the
            // queue's capacity and the script's length.
            FakeDeviceEvent event;
            while (commands.pop(event)) {
                apply(event, device);
                commandsApplied.fetch_add(1, std::memory_order_acq_rel);
            }
            while (scriptNext < spec.script.size() && spec.script[scriptNext].atFrame <= renderer.frames())
                apply(spec.script[scriptNext++], device);
            if (stopRequested.load(std::memory_order_acquire)) break;

            const uint64_t cycleLimit = limit.load(std::memory_order_acquire);
            if (!runtime.alive.load(std::memory_order_acquire) || renderer.cycles() >= cycleLimit) {
                // A dead device doesn't call back; at the limit the test hasn't asked for more.
                parkedLimit.store(cycleLimit, std::memory_order_relaxed);
                parked.store(true, std::memory_order_release);
                wake.wait(seen, std::memory_order_acquire);
                parked.store(false, std::memory_order_release);
                resync = true;
                continue;
            }

            const uint32_t numFrames = cycleLength();
            if (spec.pacing == FakePacing::realtime) {
                // The device clock: one cycle's frames at its current nominal rate. A cycle late
                // by more than a whole cycle (or the first after parking) restarts the clock
                // instead of rendering a burst to catch up.
                const auto period = std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(
                    numFrames / runtime.nominalRate.load(std::memory_order_acquire)));
                const auto now = Clock::now();
                if (resync || now > deadline + period) deadline = now;
                resync = false;
                std::this_thread::sleep_until(deadline);
                deadline += period;
                if (stopRequested.load(std::memory_order_acquire)) continue;  // drains, then exits
            }
            runCycle(numFrames, renderer.frames());
        }
    }
};

FakeDeviceDriver::FakeDeviceDriver(Engine& engine, FakeDeviceSpec spec)
    : impl_(std::make_unique<Impl>(engine, std::move(spec))) {}

FakeDeviceDriver::~FakeDeviceDriver() { stop(); }

Result<void> FakeDeviceDriver::start(const DriverConfig& request) {
    Impl& s = *impl_;
    std::lock_guard lock(s.control);
    if (s.running.load(std::memory_order_acquire))
        return makeError(ErrorCode::invalidArgument, "the driver is already running");
    if (auto ok = validate(s.spec); !ok) return ok;

    // IO-003: the output device and what it can do now.
    const AudioDeviceRef outID =
        request.outputDevice != 0 ? request.outputDevice : s.defaultOutput.load(std::memory_order_acquire);
    if (outID == 0) return makeError(ErrorCode::notFound, "no default output device");
    const int index = s.indexOf(outID);
    if (index < 0) return makeError(ErrorCode::notFound, "no such output device");
    if (!s.state[index].alive.load(std::memory_order_acquire))
        return makeError(ErrorCode::notFound, "the output device is gone");
    const FakeDevice& device = s.spec.devices[index];
    const double nominal = s.state[index].nominalRate.load(std::memory_order_acquire);
    DeviceCaps outCaps = device.output;
    outCaps.nominalRate = nominal;
    auto resolved = resolveConfig(request.sampleRate, request.bufferFrames, request.outputChannels, outCaps);
    if (!resolved) return resolved.error();

    // IO-004: fake devices share no clock, so input (only when enabled, IO-001) always comes from
    // the output device; an output-only device means no input.
    ResolvedConfig inResolved;
    const bool hasInput = request.inputEnabled && device.input.channels > 0;
    if (hasInput) {
        DeviceCaps inCaps = device.input;
        inCaps.nominalRate = nominal;
        auto r = resolveConfig(resolved->sampleRate, resolved->bufferFrames, request.inputChannels, inCaps);
        if (!r) return r.error();
        inResolved = *r;
    }

    // IO-005: the configured components plus the resolved buffer.
    LatencyComponents outComponents = device.outputLatency;
    outComponents.bufferFrames = resolved->bufferFrames;
    LatencyComponents inComponents = device.inputLatency;
    inComponents.bufferFrames = resolved->bufferFrames;
    DeviceLatency latency;
    latency.output = totalLatency(outComponents);
    latency.input = hasInput ? totalLatency(inComponents) : 0;

    // Loopback: a frame can only come back once it has been rendered.
    const uint32_t longestCycle =
        s.spec.cycleFrames.empty() ? resolved->bufferFrames
                                   : *std::max_element(s.spec.cycleFrames.begin(), s.spec.cycleFrames.end());
    const bool loopback = hasInput && s.spec.loopback;
    const uint32_t delay = s.spec.loopbackDelay.value_or(saturatingAdd(latency.input, latency.output));
    if (loopback && (delay < longestCycle || delay > FakeDeviceSpec::kMaxLoopbackDelay))
        return makeError(ErrorCode::invalidArgument, "loopback delay shorter than a cycle or too long");

    // Everything the render thread touches, before it starts.
    s.deviceIndex = static_cast<std::size_t>(index);
    s.output.allocate(resolved->channels, kMaxCycleFrames);
    s.input.allocate(hasInput ? inResolved.channels : 0, kMaxCycleFrames);
    s.ringChannels = loopback ? std::min(inResolved.channels, resolved->channels) : 0;
    const uint64_t ringFrames = loopback ? std::bit_ceil(uint64_t{delay} + kMaxCycleFrames) : 0;
    s.ring.allocate(s.ringChannels, ringFrames);
    s.ringMask = ringFrames != 0 ? ringFrames - 1 : 0;
    s.loopbackDelay = delay;
    s.runFrames = 0;
    // IO-023: overruns are judged against the device clock, which only real-time pacing has.
    s.renderer.configure(resolved->bufferFrames,
                         s.spec.pacing == FakePacing::realtime ? resolved->sampleRate : 0.0);

    s.config = {};
    s.config.outputDevice = outID;
    s.config.inputDevice = hasInput ? outID : 0;
    s.config.separateInput = false;
    s.config.sampleRate = resolved->sampleRate;
    s.config.bufferFrames = resolved->bufferFrames;
    s.config.outputChannels = resolved->channels;
    s.config.inputChannels = hasInput ? inResolved.channels : 0;
    s.latency = latency;
    publishDeviceLatency(s.engine, latency);  // IO-005, DW-049, DW-059

    s.stopRequested.store(false, std::memory_order_release);
    s.parked.store(false, std::memory_order_release);
    s.running.store(true, std::memory_order_release);
    s.thread = std::thread([&s] { s.threadMain(); });
    return {};
}

void FakeDeviceDriver::stop() {
    Impl& s = *impl_;
    std::lock_guard lock(s.control);
    if (!s.running.load(std::memory_order_acquire)) return;
    s.stopRequested.store(true, std::memory_order_release);
    s.wakeThread();
    s.thread.join();  // Engine::render is no longer called once it returns
    s.parked.store(false, std::memory_order_release);
    s.running.store(false, std::memory_order_release);
    s.config = {};
    s.latency = {};
}

DeviceLatency FakeDeviceDriver::latency() const {
    std::lock_guard lock(impl_->control);
    return impl_->latency;
}

bool FakeDeviceDriver::running() const { return impl_->running.load(std::memory_order_acquire); }
const RunningConfig& FakeDeviceDriver::current() const { return impl_->config; }
const DeviceRenderer& FakeDeviceDriver::renderer() const { return impl_->renderer; }

void FakeDeviceDriver::setCycleLimit(uint64_t totalCycles) {
    impl_->limit.store(totalCycles, std::memory_order_release);
    impl_->wakeThread();
}

uint64_t FakeDeviceDriver::cycleLimit() const { return impl_->limit.load(std::memory_order_acquire); }

bool FakeDeviceDriver::waitUntilIdle(std::chrono::milliseconds timeout) const {
    const Impl& s = *impl_;
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    for (;;) {
        if (!s.running.load(std::memory_order_acquire)) return true;
        if (s.parked.load(std::memory_order_acquire) &&
            s.parkedLimit.load(std::memory_order_relaxed) == s.limit.load(std::memory_order_acquire))
            return true;
        if (std::chrono::steady_clock::now() > deadline) return false;
        std::this_thread::sleep_for(std::chrono::microseconds(100));
    }
}

uint64_t FakeDeviceDriver::cycles() const { return impl_->renderer.cycles(); }
uint64_t FakeDeviceDriver::frames() const { return impl_->renderer.frames(); }
uint64_t FakeDeviceDriver::rtViolations() const { return impl_->violations.load(std::memory_order_relaxed); }

Result<void> FakeDeviceDriver::inject(const FakeDeviceEvent& event) {
    Impl& s = *impl_;
    std::lock_guard lock(s.control);
    const bool running = s.running.load(std::memory_order_acquire);
    const AudioDeviceRef id = s.target(event, running ? s.config.outputDevice : 0);
    const int index = s.indexOf(id);
    if (index < 0) return makeError(ErrorCode::invalidArgument, "no such fake device");
    if (event.type == FakeDeviceEventType::sampleRateChanged &&
        !supportsRate(s.spec.devices[index].output, event.sampleRate))
        return makeError(ErrorCode::invalidArgument, "the fake device doesn't support that rate");
    FakeDeviceEvent resolved = event;
    resolved.device = id;
    if (!running) {
        s.apply(resolved, 0);
        return {};
    }
    // One inject at a time (under `control`) and each waits for its own, so the queue has room.
    s.commands.push(resolved);
    const uint64_t ticket = ++s.commandsPushed;
    s.wakeThread();
    while (s.commandsApplied.load(std::memory_order_acquire) < ticket)
        std::this_thread::sleep_for(std::chrono::microseconds(50));
    return {};
}

std::size_t FakeDeviceDriver::pollNotifications(DeviceNotification* out, std::size_t max) {
    return impl_->notifications.pop(std::span<DeviceNotification>(out, max));
}

uint64_t FakeDeviceDriver::droppedNotifications() const { return impl_->dropped.load(std::memory_order_relaxed); }

std::vector<FakeDeviceState> FakeDeviceDriver::devices() const {
    std::vector<FakeDeviceState> out;
    out.reserve(impl_->spec.devices.size());
    for (std::size_t i = 0; i < impl_->spec.devices.size(); ++i) {
        const FakeDevice& device = impl_->spec.devices[i];
        FakeDeviceState state;
        state.id = device.id;
        state.name = device.name;
        state.inputChannels = device.input.channels;
        state.outputChannels = device.output.channels;
        state.nominalRate = impl_->state[i].nominalRate.load(std::memory_order_acquire);
        state.alive = impl_->state[i].alive.load(std::memory_order_acquire);
        out.push_back(std::move(state));
    }
    return out;
}

AudioDeviceRef FakeDeviceDriver::defaultOutput() const {
    return impl_->defaultOutput.load(std::memory_order_acquire);
}

} // namespace daw
