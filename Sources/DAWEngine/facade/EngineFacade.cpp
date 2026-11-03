// 08-bridge-facade (BRIDGE-001..008): the facade over Engine, GraphCompiler, the transport,
// AudioFileLoader, OfflineDriver and (later) a device driver.
//
// Locking. One facade mutex guards the facade's own state (versions, jobs, events, deferred
// param frees, the driver and export flags). It is taken by API calls, by the loader's
// completions (daw.loader) and by the export thread. Under it the facade may call into the
// GraphCompiler and the driver adapter, which never call back into the facade, so there is no
// lock cycle. The audio thread never takes it (CONV-RT-02).
//
// Devices (T-051, IO-020..022). In realtime mode a DeviceMonitor reacts to the driver's device
// notifications on daw.device, under the facade mutex; DeviceHost is its host, so the whole
// hot-swap sequence runs with the facade's state held still. A session-rate change (IO-021 (5),
// DW-079) replaces the GraphCompiler, whose rate is fixed. waitForGraph and exports wait on the
// compiler outside the facade mutex, on a shared_ptr they copied under it; the swap first lets
// every submitted build finish (so their waits return) and then waits for the old compiler to be
// gone before it makes the new one. Versions stay the facade's; the new compiler's tickets count
// from `ticketBase`.

#include "daw/EngineFacade.h"

#include <pthread.h>
#include <pthread/qos.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <span>
#include <thread>
#include <unordered_map>
#include <utility>

#include "core/Engine.h"
#include "core/RenderTarget.h"
#include "facade/AssetReloader.h"
#include "facade/AssetTable.h"
#include "facade/DriverAdapter.h"
#include "facade/FacadeErrors.h"
#include "facade/FacadeOptions.h"
#include "graph/GraphCompiler.h"
#include "graph/NodeRegistry.h"
#include "io/AudioFileLoader.h"
#include "io/DeviceMonitor.h"
#include "io/DriverConfig.h"
#include "io/ExportSpec.h"
#include "io/OfflineDriver.h"
#include "io/PeakMipmap.h"
#include "nodes/BuiltinNodes.h"
#include "nodes/ChannelStrip.h"
#include "nodes/Compressor.h"
#include "nodes/Delay.h"
#include "nodes/GainNode.h"
#include "nodes/Metronome.h"
#include "nodes/MidiClipPlayer.h"
#include "nodes/Reverb.h"
#include "time/TempoMap.h"


namespace daw {

namespace {

constexpr std::size_t kMaxEvents = 1024;      // BRIDGE-004: polled at 60 Hz; overflow drops oldest
constexpr std::size_t kMaxFinishedJobs = 1024;
constexpr auto kExportGraphWait = std::chrono::seconds(30);
constexpr auto kRateRebuildWait = std::chrono::seconds(10);  // IO-021 (5): the rebuild at the new rate
constexpr auto kDevicePoll = std::chrono::milliseconds(10);  // daw.device: how often it looks
constexpr std::size_t kNotificationBatch = 64;
constexpr auto kReloadWait = std::chrono::seconds(600);  // IO-033: an export waits this long for a re-conversion

// DW-067: graphs must be prepared for the device's whole buffer, or its blocks render silence.
// GraphCompiler prepares for kMaxBlock, above any buffer a driver accepts (IO-003).
static_assert(kMaxBlock >= kMaxDeviceBuffer);
static_assert(kPeakLevelCount == PeakMipmap::kBlockSizes.size());

// BRIDGE-001 diagnostics: the facades alive in this process.
std::mutex liveMutex;
std::set<uint64_t> liveFacades;
uint64_t nextInstanceID = 1;

bool isFinished(JobState state) { return state == JobState::succeeded || state == JobState::failed; }

AudioFileType toFileType(ExportFileType type) {
    switch (type) {
    case ExportFileType::caf: return AudioFileType::caf;
    case ExportFileType::wav: return AudioFileType::wav;
    case ExportFileType::aiff: return AudioFileType::aiff;
    }
    return AudioFileType::wav;
}

AudioSampleFormat toSampleFormat(ExportSampleFormat format) {
    switch (format) {
    case ExportSampleFormat::int16: return AudioSampleFormat::int16;
    case ExportSampleFormat::int24: return AudioSampleFormat::int24;
    case ExportSampleFormat::float32: return AudioSampleFormat::float32;
    }
    return AudioSampleFormat::float32;
}

Result<TempoMap> makeTempoMap(const TempoMapDesc& desc, double sampleRate) {
    TempoEventList tempos;
    TimeSigEventList sigs;
    for (const TempoPointDesc& t : desc.tempos) tempos.push_back(TempoEvent{t.tick, t.bpm});
    for (const TimeSigDesc& s : desc.timeSigs) sigs.push_back(TimeSigEvent{s.tick, s.num, s.den});
    return TempoMap::make(tempos, sigs, sampleRate);
}

OfflineResultPOD toResult(const OfflineRenderStats& stats, double sampleRate) {
    OfflineResultPOD r;
    r.sampleRate = sampleRate;
    r.rangeFrames = stats.rangeFrames;
    r.tailFrames = stats.tailFrames;
    r.framesWritten = stats.framesWritten;
    r.blocks = stats.blocks;
    r.rtViolations = stats.rtViolations;
    r.clippedSamples = stats.clippedSamples;
    r.renderSeconds = stats.renderSeconds;
    return r;
}

// DW-071: which MeterID each metering node writes. GraphBuilder hands the ID to the node's
// factory (NodeCreateInfo::meter, stable per NodeID across builds); the facade records it there,
// on daw.compile, and drops nodes that leave the published graph, whose IDs get reused.
class MeterMap {
public:
    void record(NodeID node, MeterID meter) {
        std::lock_guard lock(mutex_);
        meters_[node] = meter;
    }
    std::optional<MeterID> find(NodeID node) const {
        std::lock_guard lock(mutex_);
        auto it = meters_.find(node);
        return it == meters_.end() ? std::nullopt : std::optional<MeterID>(it->second);
    }
    // Keeps only `nodes` (sorted).
    void retain(const std::vector<NodeID>& nodes) {
        std::lock_guard lock(mutex_);
        std::erase_if(meters_, [&](const auto& entry) {
            return !std::binary_search(nodes.begin(), nodes.end(), entry.first);
        });
    }

private:
    mutable std::mutex mutex_;
    std::map<NodeID, MeterID> meters_;
};

// The registry every facade builds graphs with: the engine's kinds, the built-in nodes reading
// this facade's assets and metering into its telemetry, then whatever the creator adds. Metering
// kinds are wrapped so their MeterIDs land in `meters`.
Result<NodeRegistry> makeRegistry(AssetTable& assets, Telemetry& telemetry, MeterMap& meters,
                                  const FacadeOptions& options) {
    NodeRegistry registry = NodeRegistry::withBuiltins();
    // DW-041: clip players resolve assetIDs here when daw.compile creates them. DW-048: channel
    // strips write their meters into the engine's telemetry.
    auto builtins = registerBuiltinNodes(
        registry, [&assets](uint64_t assetID) { return assets.find(assetID); }, &telemetry);
    if (!builtins) return builtins.error();
    if (options.registerNodes) {
        auto registered = options.registerNodes(registry);
        if (!registered) return registered.error();
    }
    for (uint16_t k = 0; k <= static_cast<uint16_t>(NodeKind::bus); ++k) {
        const NodeKind kind = static_cast<NodeKind>(k);
        const NodeKindInfo* info = registry.find(kind);
        if (!info || !info->meters) continue;
        NodeKindInfo wrapped = *info;
        wrapped.create = [create = info->create, &meters](const NodeCreateInfo& create_info) {
            if (create_info.meter != kNoMeter) meters.record(create_info.desc.id, create_info.meter);
            return create(create_info);
        };
        if (auto set = registry.set(kind, std::move(wrapped)); !set) return set.error();
    }
    return registry;
}

} // namespace

// MARK: Impl

struct EngineFacade::Impl {
    Impl(EngineMode mode, const DriverConfigPOD& config, FacadeOptions options);
    ~Impl();

    // Everything below runs with `mutex` held.
    void pump();
    void pushEvent(EngineEventPOD event);
    // What the driver is started with: the requested config, input while anything is armed.
    DriverConfig driverConfig() const;
    Result<void> restartDriver();
    bool rendererActive() const { return exportRunning || (driver && driver->running()); }
    void applyTransportCommands();
    JobID addJob(JobKind kind, JobState state);
    void finishJob(JobStatus& job, FacadeError error);
    void pruneJobs();
    GraphStatusPOD graphStatusLocked() const;

    void exportLoop();
    void runExport(JobID job, Tick from, Tick to, const ExportSpecPOD& spec);

    // GraphCompiler status and waits in facade versions (see ticketBase).
    GraphCompiler::Status compilerStatus() const;
    uint64_t ticketOf(uint64_t version) const { return version > ticketBase ? version - ticketBase : 0; }
    // T-051. With `mutex` held, except deviceLoop (daw.device), which takes it.
    struct DeviceHost;
    void deviceLoop();
    void processDeviceNotifications();
    void pushDeviceChanged(const DeviceChangePOD& change, FacadeError error);
    void pushStartFailed(const Error& error);
    // IO-021 (1)..(3): stops the transport (applied right away), finalizes recordings, stops the driver.
    void stopForDeviceChange();
    // IO-021 (5), DW-079: with the driver stopped, rebuilds everything at `rate`.
    Result<void> changeSessionRate(double rate);
    // IO-033 (T-056). replaceCompiler: a new GraphCompiler at `rate` builds the latest description
    // from scratch, so every node is created (and prepared) again. The reload functions run the
    // re-conversion pass (AssetReloader) and its assetsReloaded events.
    Result<void> replaceCompiler(double rate);
    JobID submitLoad(uint64_t assetID, const std::string& path, const std::string& peakCacheDir);
    void startAssetReload(double previousRate);
    void submitReload(AssetReloader::Request request);
    void reloadCompleted(const AssetReloader::Request& request, AssetReloader::Staged staged, FacadeError error);
    void finishAssetReload();
    void pushReload(AssetsReloadPhase phase, uint64_t assetID, FacadeError error);
    bool exportBusy() const { return exportRunning || exportActive || !exportQueue.empty(); }

    std::atomic<uint32_t> refs{1};  // BRIDGE-001
    uint64_t instanceID = 0;
    const EngineMode mode;
    // Kept to rebuild the registry when the session rate changes.
    std::function<Result<void>(NodeRegistry&)> registerNodes;
    // UI-021 (T-043): preview notes for the tracks' MidiClipPlayers. Declared before `engine`, so
    // it outlives every node that reads it.
    MidiPreviewInbox previewInbox;

    // Declaration order is destruction order in reverse: the loader and compiler threads stop
    // before the state their callbacks touch, and the engine outlives everything rendering
    // into it. ~Impl stops the driver and the export thread first.
    mutable std::mutex mutex;
    DriverConfigPOD config;
    std::set<NodeID> armedTracks;  // DW-067: input runs while this isn't empty
    double sampleRate = 0;

    // Graphs (DW-047, DW-053). applyGraph is the compiler's only submitter, so its tickets are
    // the versions applyGraph stamps (1, 2, …).
    uint64_t submitted = 0;
    uint64_t lastSeenCompleted = 0;  // graphRejected events up to here
    // The compiler's ticket t is facade version ticketBase + t (0 until a session-rate change).
    uint64_t ticketBase = 0;
    std::optional<GraphDescription> lastDesc;  // the latest applyGraph, rebuilt at a new rate
    // The published version and every later one: their tempo maps (DW-064) and node IDs, sorted
    // (DW-071, to prune the meter map).
    struct VersionInfo {
        TempoMapDesc tempo;
        std::vector<NodeID> nodes;
    };
    std::map<uint64_t, VersionInfo> versions;
    uint64_t prunedForVersion = 0;

    // DW-029: freed ranges whose slots an older graph may still read.
    struct PendingFree {
        ParamID first;
        uint32_t count;
        uint64_t afterVersion;   // applyGraph versions up to this one may reference the range
        bool replaced = false;   // a later version is published
        uint64_t blocksAtReplace = 0;
    };
    std::vector<PendingFree> pendingFrees;

    std::map<JobID, JobStatus> jobs;
    JobID nextJob = 1;
    std::deque<EngineEventPOD> events;
    uint64_t eventsDropped = 0;
    uint64_t lastXruns = 0;

    bool exportRunning = false;  // an OfflineDriver render is using the engine
    bool exportActive = false;   // daw.export has taken a request and not finished it
    struct ExportRequest {
        JobID job;
        Tick from, to;
        ExportSpecPOD spec;
    };
    std::deque<ExportRequest> exportQueue;
    bool stopping = false;
    std::condition_variable exportWake;
    std::condition_variable deviceWake;  // daw.device: stopping

    Engine engine;
    AssetTable assets;
    // IO-034 / UI-011: each loaded asset's peaks (computed on daw.loader), read by `peaks`.
    std::unordered_map<uint64_t, std::shared_ptr<const PeakMipmap>> peaks;
    // IO-033, DW-118 (T-056): where each asset came from, and the re-conversion pass (before
    // `loader`, whose completions use it). reloadDone wakes an export waiting for a pass.
    AssetReloader reloader;
    std::condition_variable reloadDone;
    MeterMap meters;
    // Waiters outside `mutex` copy it first; replaced only by changeSessionRate.
    std::shared_ptr<GraphCompiler> compiler;
    AudioFileLoader loader;
    std::unique_ptr<DriverAdapter> driver;
    bool driverStarted = false;  // the device should be running (export pauses it)
    std::unique_ptr<DeviceMonitorHost> deviceHost;  // realtime mode with a driver (T-051)
    std::unique_ptr<DeviceMonitor> monitor;
    std::thread exportThread;    // last: started once everything above exists
    std::thread deviceThread;
};

namespace {

DeviceChangeReason toReason(DeviceSwapReason reason) {
    switch (reason) {
    case DeviceSwapReason::deviceLost: return DeviceChangeReason::deviceLost;
    case DeviceSwapReason::sampleRateChanged: return DeviceChangeReason::sampleRateChanged;
    case DeviceSwapReason::defaultOutputChanged: return DeviceChangeReason::defaultOutputChanged;
    case DeviceSwapReason::deviceAvailable: return DeviceChangeReason::deviceAvailable;
    }
    return DeviceChangeReason::deviceLost;
}

FakeDeviceEventType toFakeEvent(DeviceEventKind kind) {
    switch (kind) {
    case DeviceEventKind::deviceLost: return FakeDeviceEventType::deviceLost;
    case DeviceEventKind::deviceRestored: return FakeDeviceEventType::deviceRestored;
    case DeviceEventKind::sampleRateChanged: return FakeDeviceEventType::sampleRateChanged;
    case DeviceEventKind::processorOverload: return FakeDeviceEventType::processorOverload;
    }
    return FakeDeviceEventType::deviceLost;
}

} // namespace

// IO-021 for DeviceMonitor: the facade's engine, driver and session. Every call comes from
// DeviceMonitor::handle with the facade mutex held (processDeviceNotifications).
struct EngineFacade::Impl::DeviceHost final : public DeviceMonitorHost {
    explicit DeviceHost(Impl& impl) : impl_(impl) {}

    // An export pauses the device and restarts it itself.
    bool deviceWanted() const override { return impl_.driver && !impl_.exportRunning && !impl_.stopping; }
    DriverConfig requestedConfig() const override { return impl_.driverConfig(); }
    RunningConfig runningConfig() const override {
        return impl_.driver->running() ? impl_.driver->current() : RunningConfig{};
    }
    double sessionRate() const override { return impl_.sampleRate; }
    bool recording() const override { return impl_.engine.transport().playhead().recording; }

    bool deviceAlive(AudioDeviceRef device) const override { return impl_.driver->deviceAlive(device); }
    AudioDeviceRef defaultOutputDevice() const override { return impl_.driver->defaultOutputDevice(); }
    Result<DeviceCaps> outputCaps(AudioDeviceRef device) const override { return impl_.driver->outputCaps(device); }

    // (1)..(3) together: stopForDeviceChange applies the transport commands once the driver is
    // stopped, so the readout shows "stopped" even when no device comes back.
    void stopTransport() override { (void)impl_.engine.transport().stop(); }
    void finalizeRecordings() override { (void)impl_.engine.transport().setRecording(false); }  // 09: finalize takes
    void stopDriver() override {
        impl_.driver->stop();
        impl_.driverStarted = false;
        impl_.applyTransportCommands();
    }
    Result<void> changeSessionRate(double rate) override { return impl_.changeSessionRate(rate); }
    Result<void> startDriver(const DriverConfig& config) override {
        impl_.config.outputDevice = config.outputDevice;
        impl_.config.inputDevice = config.inputDevice;
        impl_.config.sampleRate = config.sampleRate;
        auto started = impl_.driver->start(impl_.engine, impl_.driverConfig());
        impl_.driverStarted = started.ok();
        return started;
    }
    void deviceChanged(const DeviceSwap& swap) override {
        DeviceChangePOD change;
        change.reason = toReason(swap.reason);
        change.previousDeviceID = swap.previousDevice;
        change.deviceID = swap.device;
        change.previousSampleRate = swap.previousSessionRate;
        change.sampleRate = swap.sessionRate;
        impl_.pushDeviceChanged(change, swap.error ? toFacadeError(*swap.error) : FacadeError{});
    }

private:
    Impl& impl_;
};

EngineFacade::Impl::Impl(EngineMode m, const DriverConfigPOD& cfg, FacadeOptions options)
    : mode(m), registerNodes(options.registerNodes), config(cfg) {
    sampleRate = cfg.sampleRate;
    if (mode == EngineMode::realtime) {
        driver = std::move(options.driver);
        if (driver) {
            auto started = driver->start(engine, driverConfig());
            if (started) {
                driverStarted = true;
                sampleRate = driver->sampleRate();
            } else {
                pushStartFailed(started.error());
            }
        }
    }
    if (!(sampleRate >= kMinSampleRate && sampleRate <= kMaxSampleRate)) sampleRate = 48000.0;

    // UI-021 (T-043): MIDI players read preview notes from previewInbox. Registered before the
    // creator's hook, which may still replace the kind; kept in registerNodes for rate changes.
    registerNodes = [hook = std::move(registerNodes), inbox = &previewInbox](NodeRegistry& r) -> Result<void> {
        if (auto set = r.set(NodeKind::midiClipPlayer, MidiClipPlayer::kindInfo(inbox)); !set) return set;
        return hook ? hook(r) : Result<void>{};
    };
    options.registerNodes = registerNodes;

    auto registry = makeRegistry(assets, engine.telemetry(), meters, options);
    if (!registry) {
        // A registration hook failed: build graphs of the engine's kinds only, and say why.
        EngineEventPOD event;
        event.type = EngineEventType::graphRejected;
        event.error = toFacadeError(registry.error());
        pushEvent(std::move(event));
    }
    compiler = std::make_shared<GraphCompiler>(
        engine, registry ? std::move(registry).value() : NodeRegistry::withBuiltins(), sampleRate);
    exportThread = std::thread([this] { exportLoop(); });
    if (driver) {
        deviceHost = std::make_unique<DeviceHost>(*this);
        monitor = std::make_unique<DeviceMonitor>(*deviceHost);
        deviceThread = std::thread([this] { deviceLoop(); });
    }
}

EngineFacade::Impl::~Impl() {
    {
        std::lock_guard lock(mutex);
        stopping = true;
        if (driver) driver->stop();
    }
    exportWake.notify_all();
    deviceWake.notify_all();
    exportThread.join();
    if (deviceThread.joinable()) deviceThread.join();
    // The loader and compiler join in their destructors, then the engine frees what's left.
}

DriverConfig EngineFacade::Impl::driverConfig() const {
    DriverConfig out;
    out.outputDevice = config.outputDevice;
    out.inputDevice = config.inputDevice;
    out.inputEnabled = !armedTracks.empty();
    out.sampleRate = config.sampleRate;
    out.bufferFrames = config.bufferFrames;
    out.outputChannels = config.outputChannels;
    out.inputChannels = config.inputChannels;
    return out;
}

// Stops and starts the device with driverConfig(); an export restarts it itself when it ends.
Result<void> EngineFacade::Impl::restartDriver() {
    if (!driver || exportRunning) return {};
    driver->stop();
    auto started = driver->start(engine, driverConfig());
    driverStarted = started.ok();
    return started;
}

void EngineFacade::Impl::pushEvent(EngineEventPOD event) {
    if (events.size() >= kMaxEvents) {
        events.pop_front();
        ++eventsDropped;
    }
    events.push_back(std::move(event));
}

// MARK: Devices (T-051, IO-020..022)

// daw.device: polls the driver's notifications and lets the monitor react, all under the facade
// mutex. 10 ms is quick enough for a device change and costs nothing.
void EngineFacade::Impl::deviceLoop() {
    pthread_setname_np("daw.device");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    std::unique_lock lock(mutex);
    while (!stopping) {
        deviceWake.wait_for(lock, kDevicePoll, [this] { return stopping; });
        if (stopping) return;
        processDeviceNotifications();
    }
}

void EngineFacade::Impl::processDeviceNotifications() {
    if (!driver || !monitor) return;
    DeviceNotification batch[kNotificationBatch];
    // Bounded: a few batches per call; whatever is left waits for the next poll.
    for (int round = 0; round < 4; ++round) {
        const std::size_t n = driver->pollNotifications(batch, kNotificationBatch);
        for (std::size_t i = 0; i < n; ++i) (void)monitor->handle(batch[i]);
        if (n < kNotificationBatch) return;
    }
}

void EngineFacade::Impl::pushDeviceChanged(const DeviceChangePOD& change, FacadeError error) {
    EngineEventPOD event;
    event.type = EngineEventType::deviceChanged;
    event.device = change;
    event.error = std::move(error);
    pushEvent(std::move(event));
}

void EngineFacade::Impl::pushStartFailed(const Error& error) {
    DeviceChangePOD change;
    change.reason = DeviceChangeReason::startFailed;
    change.previousSampleRate = sampleRate;
    change.sampleRate = sampleRate;
    pushDeviceChanged(change, toFacadeError(error));
}

void EngineFacade::Impl::stopForDeviceChange() {
    (void)engine.transport().stop();
    if (engine.transport().playhead().recording) (void)engine.transport().setRecording(false);  // 09
    if (driver) driver->stop();
    driverStarted = false;
    applyTransportCommands();  // nothing renders now, so apply them here
}

Result<void> EngineFacade::Impl::changeSessionRate(double rate) {
    if (rate == sampleRate) return {};
    if (!(rate >= kMinSampleRate && rate <= kMaxSampleRate))
        return makeError(ErrorCode::invalidArgument, "session rate out of range");
    if (exportBusy()) return makeError(ErrorCode::unsupported, "can't change the session rate during an export");
    const double previous = sampleRate;
    auto rebuilt = replaceCompiler(rate);
    // IO-033 (T-056): re-convert every asset from its file at the new rate, also when the rebuild
    // failed (the rate has changed either way, and the next applyGraph builds at it).
    if (sampleRate != previous) startAssetReload(previous);
    return rebuilt;
}

Result<void> EngineFacade::Impl::replaceCompiler(double rate) {
    // Finish what was submitted, so no wait on the old compiler is left hanging, then let any
    // waiter that still holds it go before the new one publishes anything.
    if (const uint64_t last = ticketOf(submitted); last != 0 && !compiler->wait(last, kRateRebuildWait))
        return makeError(ErrorCode::internal, "session rate change: a graph build timed out");
    pump();
    // Stopped: the playhead is the position; keep its tick across the change (TIME-001).
    const Tick position = engine.transport().playhead().tick;
    {
        std::weak_ptr<GraphCompiler> old = compiler;
        compiler.reset();
        const auto deadline = std::chrono::steady_clock::now() + kRateRebuildWait;
        while (!old.expired() && std::chrono::steady_clock::now() < deadline)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    FacadeOptions options;
    options.registerNodes = registerNodes;
    auto registry = makeRegistry(assets, engine.telemetry(), meters, options);
    if (!registry) {
        EngineEventPOD event;
        event.type = EngineEventType::graphRejected;
        event.error = toFacadeError(registry.error());
        pushEvent(std::move(event));
    }
    sampleRate = rate;
    compiler = std::make_shared<GraphCompiler>(
        engine, registry ? std::move(registry).value() : NodeRegistry::withBuiltins(), sampleRate);
    ticketBase = submitted;

    // IO-021 (5): every node re-prepared at the new rate — the new compiler creates them all.
    if (lastDesc) {
        GraphDescription copy = *lastDesc;
        copy.version = ++submitted;
        VersionInfo& info = versions[copy.version];
        info.tempo = copy.tempo;
        for (const NodeDesc& node : copy.nodes) info.nodes.push_back(node.id);
        std::sort(info.nodes.begin(), info.nodes.end());
        lastDesc = copy;
        (void)compiler->submit(std::move(copy));
        if (!compiler->wait(1, kRateRebuildWait))
            return makeError(ErrorCode::internal, "session rate change: the rebuild timed out");
        pump();
        if (const auto status = compilerStatus(); status.lastError) return *status.lastError;
    }
    (void)engine.transport().locate(position);
    applyTransportCommands();
    return {};
}

// MARK: Session-rate re-conversion (IO-033, T-056)

void EngineFacade::Impl::pushReload(AssetsReloadPhase phase, uint64_t assetID, FacadeError error) {
    const AssetReloader::Progress& p = reloader.progress();
    EngineEventPOD event;
    event.type = EngineEventType::assetsReloaded;
    event.subject = assetID;
    event.count = p.done;
    event.reload.phase = phase;
    event.reload.previousSampleRate = p.previousRate;
    event.reload.sampleRate = p.rate;
    event.reload.done = p.done;
    event.reload.total = p.total;
    event.reload.failed = p.failed;
    event.reload.assetID = assetID;
    event.error = std::move(error);
    pushEvent(std::move(event));
}

// IO-033: every asset loaded so far is decoded again from its original file (D-27), in the
// background on daw.loader. A pass still running is abandoned; its late results are ignored.
void EngineFacade::Impl::startAssetReload(double previousRate) {
    std::vector<AssetReloader::Request> requests = reloader.beginPass(previousRate, sampleRate);
    pushReload(AssetsReloadPhase::started, 0, {});
    if (requests.empty()) {
        pushReload(AssetsReloadPhase::finished, 0, {});
        reloadDone.notify_all();
        return;
    }
    for (AssetReloader::Request& request : requests) submitReload(std::move(request));
}

// Only enqueues (the loader never takes the facade mutex itself), so it's fine under it.
void EngineFacade::Impl::submitReload(AssetReloader::Request request) {
    AudioLoadRequest load;
    load.assetID = request.assetID;
    load.file = request.source.path;
    load.sessionRate = sampleRate;
    load.peakCacheDir = request.source.peakCacheDir;  // IO-034: the cache sees the stale rate and rewrites
    Impl* impl = this;
    loader.submit(std::move(load), [impl, request = std::move(request)](Result<LoadedAudio> loaded) {
        AssetReloader::Staged staged;
        FacadeError error;
        if (loaded) {
            // IO-034 / UI-011: the peaks of the new asset, here on daw.loader like a first load.
            staged.peaks = loaded->peaks ? loaded->peaks
                                         : std::make_shared<const PeakMipmap>(PeakMipmap::compute(*loaded->asset));
            staged.asset = std::move(loaded->asset);
        } else {
            error = toFacadeError(loaded.error());
        }
        std::lock_guard lock(impl->mutex);
        if (impl->stopping) return;
        impl->reloadCompleted(request, std::move(staged), std::move(error));
    });
}

void EngineFacade::Impl::reloadCompleted(const AssetReloader::Request& request, AssetReloader::Staged staged,
                                         FacadeError error) {
    const uint32_t failedBefore = reloader.progress().failed;
    const AssetReloader::Outcome outcome = reloader.complete(request, std::move(staged));
    if (outcome == AssetReloader::Outcome::stale) return;
    // A superseded asset (loaded again since the pass began) isn't counted as failed: its newer
    // load stands.
    const bool failed = reloader.progress().failed > failedBefore;
    if (failed) {
        // Like a failed first load: the asset is dropped at the swap and its clips are silent.
        EngineEventPOD event;
        event.type = EngineEventType::assetLoadFailed;
        event.subject = request.assetID;
        event.error = error;
        pushEvent(std::move(event));
    }
    pushReload(AssetsReloadPhase::progress, request.assetID, failed ? std::move(error) : FacadeError{});
    if (outcome == AssetReloader::Outcome::finished) finishAssetReload();
}

// The last asset of the pass is done: swap them all in, then rebuild. Clip players and samplers
// resolve their assets when they're created (DW-051), so a new compiler creates every node again
// and the new assets go live in one new snapshot.
void EngineFacade::Impl::finishAssetReload() {
    const AssetReloader::Progress progress = reloader.progress();
    for (AssetReloader::Staged& staged : reloader.takeStaged()) {
        if (staged.asset) {
            assets.put(staged.assetID, std::move(staged.asset));
            peaks[staged.assetID] = std::move(staged.peaks);
        } else {
            assets.remove(staged.assetID);
            peaks.erase(staged.assetID);
        }
    }
    FacadeError error;
    if (auto rebuilt = replaceCompiler(sampleRate); !rebuilt) {
        error = toFacadeError(rebuilt.error());
    } else if (progress.failed > 0) {
        error = facadeError(FacadeErrorCode::io, std::to_string(progress.failed) + " of " +
                                                     std::to_string(progress.total) +
                                                     " assets could not be re-converted (IO-033)");
    }
    pushReload(AssetsReloadPhase::finished, 0, std::move(error));
    reloadDone.notify_all();
}

GraphCompiler::Status EngineFacade::Impl::compilerStatus() const {
    GraphCompiler::Status status = compiler->status();
    status.completed += ticketBase;  // every version up to ticketBase finished on an older compiler
    return status;
}

GraphStatusPOD EngineFacade::Impl::graphStatusLocked() const {
    const GraphCompiler::Status status = compilerStatus();
    GraphStatusPOD out;
    out.submittedVersion = submitted;
    out.completedVersion = status.completed;
    out.publishedVersion = status.publishedVersion;
    if (status.lastError) out.lastError = toFacadeError(*status.lastError);
    return out;
}

// Turns what changed since the last call into events and finishes deferred param frees.
void EngineFacade::Impl::pump() {
    const GraphCompiler::Status status = compilerStatus();

    // A failed build. Several builds may complete between two pumps; only the latest one's
    // error is kept (GraphCompiler::Status), and graphStatus()/waitForGraph report it too.
    if (status.completed > lastSeenCompleted) {
        lastSeenCompleted = status.completed;
        if (status.lastError) {
            EngineEventPOD event;
            event.type = EngineEventType::graphRejected;
            event.subject = status.completed;
            event.error = toFacadeError(*status.lastError);
            pushEvent(std::move(event));
        }
    }

    // DW-064: keep the published version and everything newer.
    versions.erase(versions.begin(), versions.lower_bound(status.publishedVersion));
    // DW-071: meters of nodes the published graph no longer has. (A newer graph still compiling
    // may re-record a node it brings back; its factory runs again only if it's new.)
    if (status.publishedVersion > prunedForVersion) {
        prunedForVersion = status.publishedVersion;
        if (auto it = versions.find(status.publishedVersion); it != versions.end()) {
            std::vector<NodeID> keep = it->second.nodes;
            for (auto later = std::next(it); later != versions.end(); ++later)
                keep.insert(keep.end(), later->second.nodes.begin(), later->second.nodes.end());
            std::sort(keep.begin(), keep.end());
            meters.retain(keep);
        }
    }

    // IO-023: the driver counts xruns into telemetry; surface them as events.
    const uint64_t xruns = engine.telemetry().snapshot().xruns;
    if (xruns > lastXruns) {
        lastXruns = xruns;
        EngineEventPOD event;
        event.type = EngineEventType::overload;
        event.count = xruns;
        pushEvent(std::move(event));
    }

    // DW-029. A range freed after version v may be read by any graph built from v or earlier.
    // Once a later version is published those graphs are all retired (the compiler builds in
    // order), but a block that started before the swap may still be rendering the old one, so
    // the slots are reused only after one more block completes, or right away if nothing is
    // rendering (no block can be in flight then).
    const uint64_t blocks = engine.blocksRendered();
    const bool rendering = rendererActive();
    for (std::size_t i = 0; i < pendingFrees.size();) {
        PendingFree& p = pendingFrees[i];
        if (!p.replaced && status.publishedVersion > p.afterVersion) {
            p.replaced = true;
            p.blocksAtReplace = blocks;
        }
        if (p.replaced && (!rendering || blocks > p.blocksAtReplace)) {
            (void)engine.params().free(p.first, p.count);
            pendingFrees[i] = pendingFrees.back();
            pendingFrees.pop_back();
        } else {
            ++i;
        }
    }
}

// TIME-004: commands apply at the start of a block. With nothing rendering (offline mode, or no
// device yet), a 0-frame block (ENG-004) applies them now, so transport() reads back what was
// just asked for. It needs a published graph; until there is one, they stay queued.
void EngineFacade::Impl::applyTransportCommands() {
    if (rendererActive()) return;
    RenderTarget target{};
    engine.render(target, 0);
}

JobID EngineFacade::Impl::addJob(JobKind kind, JobState state) {
    pruneJobs();
    JobStatus job;
    job.job = nextJob++;
    job.kind = kind;
    job.state = state;
    jobs.emplace(job.job, job);
    return job.job;
}

void EngineFacade::Impl::finishJob(JobStatus& job, FacadeError error) {
    job.state = error.ok() ? JobState::succeeded : JobState::failed;
    if (job.state == JobState::succeeded) job.progress = 1.0;
    job.error = error;
    EngineEventPOD event;
    event.type = EngineEventType::jobFinished;
    event.subject = static_cast<uint64_t>(job.kind);
    event.job = job.job;
    event.error = std::move(error);
    pushEvent(std::move(event));
}

// Finished jobs are kept for polling, the oldest dropped beyond kMaxFinishedJobs.
void EngineFacade::Impl::pruneJobs() {
    std::size_t finished = 0;
    for (const auto& [id, job] : jobs) finished += isFinished(job.state);
    for (auto it = jobs.begin(); finished > kMaxFinishedJobs && it != jobs.end();) {
        if (isFinished(it->second.state)) {
            it = jobs.erase(it);
            --finished;
        } else {
            ++it;
        }
    }
}

// MARK: Offline export (DW-057, DW-064, DW-056)

void EngineFacade::Impl::exportLoop() {
    pthread_setname_np("daw.export");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    for (;;) {
        ExportRequest request;
        {
            std::unique_lock lock(mutex);
            exportWake.wait(lock, [this] { return stopping || !exportQueue.empty(); });
            if (stopping) return;
            request = std::move(exportQueue.front());
            exportQueue.pop_front();
            exportActive = true;  // no session-rate change until it's done
        }
        runExport(request.job, request.from, request.to, request.spec);
        std::lock_guard lock(mutex);
        exportActive = false;
    }
}

void EngineFacade::Impl::runExport(JobID jobID, Tick from, Tick to, const ExportSpecPOD& pod) {
    uint64_t latest;
    std::shared_ptr<GraphCompiler> builder;
    {
        // IO-033 (T-056): an export renders the assets at the session rate, so it waits for a
        // re-conversion to finish (exportActive keeps another rate change out meanwhile).
        std::unique_lock lock(mutex);
        reloadDone.wait_for(lock, kReloadWait, [this] { return stopping || !reloader.active(); });
        latest = ticketOf(submitted);
        builder = compiler;  // exportActive also keeps session-rate changes out meanwhile
        if (auto it = jobs.find(jobID); it != jobs.end()) it->second.state = JobState::running;
    }
    // Render what was applied last: wait until every submitted description has been built.
    const bool built = latest == 0 || builder->wait(latest, kExportGraphWait);
    builder.reset();

    ExportSpec spec;
    spec.file = pod.path;
    spec.fileType = toFileType(pod.fileType);
    spec.sampleFormat = toSampleFormat(pod.sampleFormat);
    spec.dither = pod.dither;
    spec.ditherSeed = pod.ditherSeed;
    spec.numChannels = pod.numChannels;
    spec.blockSize = pod.blockSize;
    spec.tail = TailSpec{pod.tailEnabled, pod.tailThresholdDb, pod.tailQuietSeconds, pod.tailMaxSeconds};
    spec.followLoop = pod.followLoop;  // T-036

    FacadeError error;
    bool render = false;
    {
        std::lock_guard lock(mutex);
        pump();
        const GraphCompiler::Status status = compilerStatus();
        auto tempo = versions.find(status.publishedVersion);
        if (!built) {
            error = facadeError(FacadeErrorCode::internal, "offline render: graph build timed out");
        } else if (reloader.active()) {
            error = facadeError(FacadeErrorCode::internal, "offline render: assets are still being re-converted (IO-033)");
        } else if (status.publishedVersion == 0 || tempo == versions.end()) {
            error = facadeError(FacadeErrorCode::invalidArgument, "offline render: no graph applied");
        } else if (auto map = makeTempoMap(tempo->second.tempo, sampleRate); !map) {
            error = toFacadeError(map.error());
        } else {
            // DW-064: the map the rendering graph was built from (GraphBuilder builds the same
            // one from the same desc at the same rate).
            spec.tempo = std::move(map).value();
            // DW-057: one render thread at a time (02), so the device pauses meanwhile.
            if (driver && driver->running()) driver->stop();
            exportRunning = true;
            render = true;
        }
    }

    OfflineRenderStats stats;
    if (render) {
        // DW-064: the driver doesn't touch the recording flag, and an export never records.
        (void)engine.transport().setRecording(false);
        OfflineDriver offline;
        auto progress = [this, jobID](const OfflineProgress& p) {
            std::lock_guard lock(mutex);
            if (auto it = jobs.find(jobID); it != jobs.end() && p.maxFrames > 0)
                it->second.progress = double(p.framesRendered) / double(p.maxFrames);
        };
        auto rendered = offline.render(engine, from, to, spec, progress);
        stats = offline.lastRender();
        if (!rendered) error = toFacadeError(rendered.error());
    }

    std::lock_guard lock(mutex);
    if (render) {
        exportRunning = false;
        if (driverStarted && driver && !stopping) {
            auto restarted = driver->start(engine, driverConfig());
            if (!restarted) {
                driverStarted = false;
                pushStartFailed(restarted.error());
            }
        }
    }
    if (auto it = jobs.find(jobID); it != jobs.end()) {
        it->second.render = toResult(stats, spec.tempo.sampleRate());
        finishJob(it->second, std::move(error));
    }
}

// MARK: Construction

EngineFacade::EngineFacade(Impl* impl) : impl_(impl) {
    std::lock_guard lock(liveMutex);
    impl_->instanceID = nextInstanceID++;
    liveFacades.insert(impl_->instanceID);
}

EngineFacade::~EngineFacade() {
    const uint64_t id = impl_->instanceID;
    delete impl_;
    std::lock_guard lock(liveMutex);
    liveFacades.erase(id);
}

uint64_t EngineFacade::instanceID() const { return impl_->instanceID; }

bool EngineFacade::isLive(uint64_t instanceID) {
    std::lock_guard lock(liveMutex);
    return liveFacades.count(instanceID) != 0;
}

EngineFacade* EngineFacade::create(EngineMode mode, const DriverConfigPOD& config) {
    FacadeOptions options;
    if (mode == EngineMode::realtime)
        options.driver = config.driver == DeviceDriverKind::fake  // DW-089
                             ? std::make_unique<FakeDeviceDriverAdapter>(defaultFakeDeviceSpec())
                             : makeDefaultDriverAdapter();
    return EngineFacadeAccess::create(mode, config, std::move(options));
}

EngineFacade* EngineFacadeAccess::create(EngineMode mode, const DriverConfigPOD& config, FacadeOptions options) {
    // BRIDGE-008: offline mode renders at the configured session rate.
    if (mode == EngineMode::offline &&
        !(config.sampleRate >= kMinSampleRate && config.sampleRate <= kMaxSampleRate))
        return nullptr;
    return new EngineFacade(new EngineFacade::Impl(mode, config, std::move(options)));
}

EngineMode EngineFacade::mode() const { return impl_->mode; }

// MARK: Graph & params

uint64_t EngineFacade::applyGraph(const GraphDescription& desc) {
    std::lock_guard lock(impl_->mutex);
    GraphDescription copy = desc;
    copy.version = ++impl_->submitted;
    Impl::VersionInfo& info = impl_->versions[copy.version];
    info.tempo = copy.tempo;
    for (const NodeDesc& node : copy.nodes) info.nodes.push_back(node.id);
    std::sort(info.nodes.begin(), info.nodes.end());
    impl_->lastDesc = copy;  // IO-021 (5): rebuilt at a new session rate
    const uint64_t ticket = impl_->compiler->submit(std::move(copy));
    // == version − ticketBase: the facade is the only submitter, under this lock
    (void)ticket;
    impl_->pump();
    return impl_->submitted;
}

GraphStatusPOD EngineFacade::graphStatus() const {
    std::lock_guard lock(impl_->mutex);
    impl_->pump();
    return impl_->graphStatusLocked();
}

GraphStatusPOD EngineFacade::waitForGraph(uint64_t version, uint32_t timeoutMs) {
    {
        // A version up to ticketBase was finished by an earlier compiler (ticket 0).
        std::shared_ptr<GraphCompiler> builder;
        uint64_t ticket;
        {
            std::lock_guard lock(impl_->mutex);
            builder = impl_->compiler;
            ticket = impl_->ticketOf(version);
        }
        if (ticket != 0) (void)builder->wait(ticket, std::chrono::milliseconds(timeoutMs));
    }
    std::lock_guard lock(impl_->mutex);
    impl_->pump();
    if (version > 0) impl_->applyTransportCommands();  // a first graph lets queued commands apply
    return impl_->graphStatusLocked();
}

ParamID EngineFacade::allocateParams(uint32_t count) {
    std::lock_guard lock(impl_->mutex);
    impl_->pump();
    auto id = impl_->engine.params().allocate(count);
    return id ? id.value() : kInvalidParamID;
}

void EngineFacade::freeParams(ParamID first, uint32_t count) {
    std::lock_guard lock(impl_->mutex);
    ParamSlotTable& params = impl_->engine.params();
    if (count == 0 || first >= params.capacity() || count > params.capacity() - first) return;
    for (uint32_t i = 0; i < count; ++i)
        if (!params.isAllocated(first + i)) return;  // not ours to free (or freed twice)
    for (const auto& p : impl_->pendingFrees)
        if (first < p.first + p.count && p.first < first + count) return;  // already pending
    // DW-029: nothing was ever applied, so no graph can reference the range.
    if (impl_->submitted == 0) {
        (void)params.free(first, count);
        return;
    }
    impl_->pendingFrees.push_back({first, count, impl_->submitted});
    impl_->pump();
}

void EngineFacade::setParam(ParamID id, float value) {
    ParamSlotTable& params = impl_->engine.params();
    if (id < params.capacity()) params.set(id, value);  // ENG-021/023: the slot only
}

float EngineFacade::getParam(ParamID id) const {
    const ParamSlotTable& params = impl_->engine.params();
    return id < params.capacity() ? params.get(id) : 0.0f;
}

// MARK: Transport

void EngineFacade::play() {
    std::lock_guard lock(impl_->mutex);
    if (impl_->reloader.active()) return;  // IO-033 (T-056): refused while assets re-convert
    (void)impl_->engine.transport().play();
    impl_->applyTransportCommands();
}

void EngineFacade::stop() {
    std::lock_guard lock(impl_->mutex);
    impl_->previewInbox.releaseAll();  // UI-021: no preview note outlives a stop
    (void)impl_->engine.transport().stop();
    impl_->applyTransportCommands();
}

void EngineFacade::locate(Tick tick) {
    std::lock_guard lock(impl_->mutex);
    impl_->previewInbox.releaseAll();  // UI-021: nor a locate
    (void)impl_->engine.transport().locate(tick);
    impl_->applyTransportCommands();
}

void EngineFacade::setLoop(bool enabled, Tick start, Tick end) {
    std::lock_guard lock(impl_->mutex);
    (void)impl_->engine.transport().setLoop(enabled, start, end);
    impl_->applyTransportCommands();
}

void EngineFacade::setRecording(bool recording) {
    std::lock_guard lock(impl_->mutex);
    (void)impl_->engine.transport().setRecording(recording);
    impl_->applyTransportCommands();
}

// UI-021 (T-043): see EngineFacade.h. The inbox (nodes/MidiClipPlayer.h) is lock-free towards
// the audio thread; the facade lock only serializes its producers.
void EngineFacade::previewNote(NodeID source, uint8_t pitch, uint8_t velocity, bool on) {
    std::lock_guard lock(impl_->mutex);
    if (on && (impl_->mode == EngineMode::offline || impl_->exportBusy())) return;
    (void)impl_->previewInbox.post(source, pitch, velocity, on);
}

TransportPOD EngineFacade::transport() const {
    // DW-059
    const TransportPlayhead ph = impl_->engine.transport().playhead();
    TransportPOD out;
    out.sample = ph.sample;
    out.tick = ph.tick;
    out.playing = ph.playing;
    out.recording = ph.recording;
    out.loopEnabled = ph.loopEnabled;
    out.loopStart = ph.loopStart;
    out.loopEnd = ph.loopEnd;
    return out;
}

// MARK: Assets (DW-041)

JobID EngineFacade::loadAsset(uint64_t assetID, const std::string& path) {
    return loadAsset(assetID, path, std::string());
}

JobID EngineFacade::loadAsset(uint64_t assetID, const std::string& path, const std::string& peakCacheDir) {
    std::lock_guard lock(impl_->mutex);
    return impl_->submitLoad(assetID, path, peakCacheDir);
}

// Only enqueues on daw.loader (the completion takes the facade mutex there).
JobID EngineFacade::Impl::submitLoad(uint64_t assetID, const std::string& path, const std::string& peakCacheDir) {
    if (path.empty()) return 0;
    const JobID jobID = addJob(JobKind::loadAsset, JobState::queued);
    AudioLoadRequest request;
    request.assetID = assetID;
    request.file = path;
    request.sessionRate = sampleRate;
    request.peakCacheDir = peakCacheDir;  // DW-077: empty computes the peaks without a cache file
    // DW-118 (T-056): kept to re-convert the asset when the session rate changes (IO-033).
    (void)reloader.recordLoad(assetID, AssetReloader::Source{path, peakCacheDir});
    Impl* impl = this;
    loader.submit(std::move(request), [impl, jobID, assetID](Result<LoadedAudio> loaded) {
        std::shared_ptr<const PeakMipmap> peaks;
        EngineEventPOD event;
        event.subject = assetID;
        event.job = jobID;
        AssetInfoPOD info;
        if (loaded) {
            const AudioAsset& asset = *loaded->asset;
            info = AssetInfoPOD{assetID, asset.channels, asset.frames, asset.sampleRate,
                                loaded->fileSampleRate, loaded->fileFrames, loaded->resampled};
            // IO-034 / UI-011: here on daw.loader, before anyone hears the asset loaded. DW-077: from
            // the cache file when the load named a cache directory.
            peaks = loaded->peaks ? loaded->peaks : std::make_shared<const PeakMipmap>(PeakMipmap::compute(asset));
            impl->assets.put(assetID, std::move(loaded->asset));
            event.type = EngineEventType::assetLoaded;
        } else {
            event.type = EngineEventType::assetLoadFailed;
            event.error = toFacadeError(loaded.error());
        }
        std::lock_guard lock(impl->mutex);
        if (peaks) impl->peaks[assetID] = std::move(peaks);
        if (auto it = impl->jobs.find(jobID); it != impl->jobs.end()) {
            it->second.asset = info;
            impl->finishJob(it->second, event.error);
        }
        impl->pushEvent(std::move(event));
    });
    return jobID;
}

PeakLevelPOD EngineFacade::peaks(uint64_t assetID, uint32_t level) const {
    PeakLevelPOD out;
    std::shared_ptr<const PeakMipmap> mipmap;
    {
        std::lock_guard lock(impl_->mutex);
        auto it = impl_->peaks.find(assetID);
        if (it == impl_->peaks.end() || level >= kPeakLevelCount) return out;
        mipmap = it->second;
    }
    // Immutable once shared, so the copy happens outside the lock.
    const PeakMipmap::Level& source = mipmap->levels()[level];
    out.found = true;
    out.assetID = assetID;
    out.channels = mipmap->channels();
    out.sampleRate = mipmap->sampleRate();
    out.frames = mipmap->frames();
    out.blockSize = source.blockSize;
    out.blockCount = source.blockCount;
    out.minMax.resize(source.peaks.size() * 2);
    for (size_t i = 0; i < source.peaks.size(); ++i) {
        out.minMax[2 * i] = source.peaks[i].min;
        out.minMax[2 * i + 1] = source.peaks[i].max;
    }
    return out;
}

JobStatus EngineFacade::pollJob(JobID job) const {
    std::lock_guard lock(impl_->mutex);
    auto it = impl_->jobs.find(job);
    return it == impl_->jobs.end() ? JobStatus{} : it->second;
}

// MARK: Recording and plugins: later tasks (09, 10)

// DW-067: no live input switch, so input on/off restarts the device. Routing the channel pair
// to the track is 09 (T-030s).
void EngineFacade::armInput(NodeID track, uint32_t, bool armed) {
    std::lock_guard lock(impl_->mutex);
    Impl& impl = *impl_;
    const bool wasEnabled = !impl.armedTracks.empty();
    if (armed)
        impl.armedTracks.insert(track);
    else
        impl.armedTracks.erase(track);
    if (wasEnabled == impl.armedTracks.empty() && impl.driverStarted) {
        if (auto restarted = impl.restartDriver(); !restarted) impl.pushStartFailed(restarted.error());
    }
}

JobID EngineFacade::instantiatePlugin(NodeID, const PluginDescriptorPOD&) {
    std::lock_guard lock(impl_->mutex);
    const JobID job = impl_->addJob(JobKind::instantiatePlugin, JobState::queued);
    impl_->finishJob(impl_->jobs[job], facadeError(FacadeErrorCode::unsupported,
                                                   "plugin hosting is not implemented yet (10)"));
    return job;
}

ByteVector EngineFacade::getPluginState(NodeID) { return {}; }
void EngineFacade::setPluginState(NodeID, const ByteVector&) {}
void* EngineFacade::createPluginView(NodeID) { return nullptr; }
void EngineFacade::destroyPluginView(NodeID) {}

// MARK: Offline

JobID EngineFacade::renderOffline(Tick from, Tick to, const ExportSpecPOD& spec) {
    std::lock_guard lock(impl_->mutex);
    const JobID job = impl_->addJob(JobKind::renderOffline, JobState::queued);
    // DW-056: graphs are prepared for blocks of up to kMaxBlock (GraphCompiler's default).
    if (spec.blockSize == 0 || spec.blockSize > kMaxBlock) {
        impl_->finishJob(impl_->jobs[job], facadeError(FacadeErrorCode::invalidArgument,
                                                       "offline render: block size must be 1…" +
                                                           std::to_string(kMaxBlock)));
        return job;
    }
    impl_->previewInbox.releaseAll();  // UI-021: previews end before the export
    impl_->exportQueue.push_back({job, from, to, spec});
    impl_->exportWake.notify_one();
    return job;
}

// MARK: Device

std::vector<DeviceInfoPOD> EngineFacade::devices() const {
    std::lock_guard lock(impl_->mutex);
    return impl_->driver ? impl_->driver->devices() : std::vector<DeviceInfoPOD>{};
}

FacadeError EngineFacade::simulateDeviceEvent(const DeviceEventPOD& event) {
    std::lock_guard lock(impl_->mutex);
    Impl& impl = *impl_;
    if (impl.mode != EngineMode::realtime || !impl.driver || impl.config.driver != DeviceDriverKind::fake)
        return facadeError(FacadeErrorCode::unsupported, "device events can only be simulated on the fake device driver");
    FakeDeviceEvent fake;
    fake.type = toFakeEvent(event.kind);
    fake.device = event.deviceID;
    fake.sampleRate = event.sampleRate;
    if (auto injected = impl.driver->simulate(fake); !injected) return toFacadeError(injected.error());
    // React now rather than at daw.device's next poll, so a script sees the outcome on return.
    impl.processDeviceNotifications();
    return {};
}

FacadeError EngineFacade::setDevice(const DriverConfigPOD& config) {
    std::lock_guard lock(impl_->mutex);
    Impl& impl = *impl_;
    if (impl.mode != EngineMode::realtime || !impl.driver)
        return facadeError(FacadeErrorCode::unsupported, "no device driver in this engine");
    if (config.driver != impl.config.driver)
        return facadeError(FacadeErrorCode::invalidArgument, "the device driver kind is fixed when the engine is created");

    // DW-079: the rate the session should run at. Rate 0 keeps the session rate when the device
    // supports it (IO-021 (5)), else takes the device's; a driver that can't describe its devices
    // just tries the request.
    // A bad request fails before anything is stopped.
    double rate = config.sampleRate;
    if (rate != 0 && !isSessionRate(rate))
        return facadeError(FacadeErrorCode::invalidArgument, "not a session rate (44.1/48/88.2/96 kHz)");
    const AudioDeviceRef target = config.outputDevice != 0 ? config.outputDevice : impl.driver->defaultOutputDevice();
    auto caps = impl.driver->outputCaps(target);
    if (rate != 0 && caps && !supportsRate(*caps, rate))
        return facadeError(FacadeErrorCode::unsupported, "the device can't run at that rate");
    if (rate == 0) {
        if (caps) {
            if (supportsRate(*caps, impl.sampleRate)) {
                rate = impl.sampleRate;
            } else {
                auto resolved = resolveConfig(0, config.bufferFrames, config.outputChannels, *caps);
                if (!resolved) return toFacadeError(resolved.error());
                rate = resolved->sampleRate;
            }
        }
    }
    if (rate != 0 && rate != impl.sampleRate) {
        if (impl.exportBusy())
            return facadeError(FacadeErrorCode::unsupported, "can't change the session rate during an export");
        impl.stopForDeviceChange();
        if (auto changed = impl.changeSessionRate(rate); !changed) return toFacadeError(changed.error());
    }
    impl.config = config;
    if (rate != 0) impl.config.sampleRate = rate;  // later restarts keep the session rate
    // During an export the device is paused; it restarts with the new config afterwards.
    if (impl.exportRunning) return {};
    if (auto started = impl.restartDriver(); !started) return toFacadeError(started.error());
    if (impl.driver->sampleRate() != impl.sampleRate) {
        impl.driver->stop();
        impl.driverStarted = false;
        return facadeError(FacadeErrorCode::unsupported, "the device runs at another rate than the session");
    }
    return {};
}

// MODEL-005 SetSessionSampleRate, IO-033 (T-056). Realtime with a driver goes through setDevice
// with the running config at the new rate (the device must support it, IO-021 (5)); otherwise
// (offline, or no driver) the session rate changes on its own.
FacadeError EngineFacade::setSessionSampleRate(double rate) {
    if (!isSessionRate(rate))
        return facadeError(FacadeErrorCode::invalidArgument, "not a session rate (44.1/48/88.2/96 kHz)");
    DriverConfigPOD config;
    {
        std::lock_guard lock(impl_->mutex);
        Impl& impl = *impl_;
        if (rate == impl.sampleRate) return {};
        if (impl.exportBusy())
            return facadeError(FacadeErrorCode::unsupported, "can't change the session rate during an export");
        if (impl.mode != EngineMode::realtime || !impl.driver) {
            impl.stopForDeviceChange();  // the transport stops (there is no driver to stop)
            if (auto changed = impl.changeSessionRate(rate); !changed) return toFacadeError(changed.error());
            impl.config.sampleRate = rate;
            return {};
        }
        config = impl.config;
        config.sampleRate = rate;
    }
    return setDevice(config);
}

// MARK: Observability

TelemetryPOD EngineFacade::telemetry() const {
    // DW-049: field by field.
    const TelemetrySnapshot s = impl_->engine.telemetry().snapshot();
    TelemetryPOD t;
    t.dspLoadPercent = s.dspLoadPercent;
    t.lastBlockLoadPercent = s.lastBlockLoadPercent;
    t.xruns = s.xruns;
    t.rtViolations = s.rtViolations;
    t.graphEpoch = s.graphEpoch;
    t.oversizeBlocks = s.oversizeBlocks;
    t.retireQueueFullBlocks = s.retireQueueFullBlocks;
    t.deviceOutputLatency = s.deviceOutputLatency;
    t.graphLatency = s.graphLatency;
    t.outputLatency = s.outputLatency;
    t.numNodeLatencies = s.numNodeLatencies;

    std::lock_guard lock(impl_->mutex);
    impl_->pump();
    t.graphVersion = impl_->compilerStatus().publishedVersion;  // DW-047
    t.blocksRendered = impl_->engine.blocksRendered();
    t.paramsAllocated = impl_->engine.params().allocatedCount();
    for (const auto& p : impl_->pendingFrees) t.paramsPendingFree += p.count;
    t.assetsLoaded = impl_->assets.size();
    t.eventsDropped = impl_->eventsDropped;
    t.sampleRate = impl_->sampleRate;
    t.deviceRunning = impl_->driver && impl_->driver->running();
    if (const auto& reload = impl_->reloader.progress(); reload.active) t.assetsReloadPending = reload.total - reload.done;
    if (impl_->driver) {
        t.outputDeviceID = t.deviceRunning ? impl_->driver->current().outputDevice : 0;
        t.processorOverloads = impl_->driver->processorOverloads();
        t.renderOverruns = impl_->driver->renderOverruns();
    }
    return t;
}

std::vector<NodeLatencyPOD> EngineFacade::nodeLatencies() const {
    const Telemetry& telemetry = impl_->engine.telemetry();
    std::vector<NodeLatency> table(Telemetry::kMaxNodeLatencies);
    table.resize(telemetry.nodeLatencies(table.data(), Telemetry::kMaxNodeLatencies));
    std::vector<NodeLatencyPOD> out;
    out.reserve(table.size());
    for (const NodeLatency& n : table) out.push_back(NodeLatencyPOD{n.node, n.samples});
    return out;
}

// MIX-005, DW-071: the node's meter, if it has one (channel strips).
MeterPOD EngineFacade::meter(NodeID node) const {
    const std::optional<MeterID> id = impl_->meters.find(node);
    if (!id) return MeterPOD{};
    const MeterReading reading = impl_->engine.telemetry().meter(*id);
    return MeterPOD{reading.peak, reading.rms, true};
}

size_t EngineFacade::pollEvents(EngineEventPOD* out, size_t max) {
    std::lock_guard lock(impl_->mutex);
    impl_->pump();
    size_t n = 0;
    while (n < max && !impl_->events.empty()) {
        out[n++] = std::move(impl_->events.front());
        impl_->events.pop_front();
    }
    return n;
}

// CTL engine.paramInfo. Only the kinds whose nodes publish ParamInfo so far; "[]" for the rest.
std::string EngineFacade::paramInfoJSON(NodeKind kind) const {
    std::span<const ParamInfo> params;
    if (kind == NodeKind::channelStrip) params = ChannelStrip::kParamInfo;
    if (kind == NodeKind::compressor) params = Compressor::kParamInfo;  // DSP-041
    if (kind == NodeKind::gain) params = GainNode::kParamInfo;            // DW-160 (T-026): sends, MIX-007
    if (kind == NodeKind::metronome) params = Metronome::kParamInfo;      // DW-160 (T-026): TIME-010 slots
    if (kind == NodeKind::reverb) params = Reverb::kParamInfo;            // DSP-041 (T-073)
    if (kind == NodeKind::delay) params = Delay::kParamInfo;              // DSP-041 (T-072)
    std::string json = "[";
    for (const ParamInfo& p : params) {
        if (json.size() > 1) json += ",";
        const char* curve = p.curve == ParamInfo::Curve::db ? "db" : p.curve == ParamInfo::Curve::log ? "log" : "linear";
        // The strings are compile-time identifiers and units: nothing to escape.
        json += std::string("{\"index\":") + std::to_string(p.index) + ",\"id\":\"" + p.id + "\",\"name\":\"" +
                p.name + "\",\"min\":" + std::to_string(p.min) + ",\"max\":" + std::to_string(p.max) +
                ",\"default\":" + std::to_string(p.def) + ",\"curve\":\"" + curve + "\",\"unit\":\"" + p.unit +
                "\",\"automatable\":" + (p.automatable ? "true" : "false") + "}";
    }
    return json + "]";
}

} // namespace daw

// MARK: Lifetime (BRIDGE-001)

void retainFacade(daw::EngineFacade* facade) {
    facade->impl_->refs.fetch_add(1, std::memory_order_relaxed);
}

void releaseFacade(daw::EngineFacade* facade) {
    if (facade->impl_->refs.fetch_sub(1, std::memory_order_acq_rel) == 1) delete facade;
}
