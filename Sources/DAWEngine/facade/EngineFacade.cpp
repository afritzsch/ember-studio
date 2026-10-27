// 08-bridge-facade (BRIDGE-001..008): the facade over Engine, GraphCompiler, the transport,
// AudioFileLoader, OfflineDriver and (later) a device driver.
//
// Locking. One facade mutex guards the facade's own state (versions, jobs, events, deferred
// param frees, the driver and export flags). It is taken by API calls, by the loader's
// completions (daw.loader) and by the export thread. Under it the facade may call into the
// GraphCompiler and the driver adapter, which never call back into the facade, so there is no
// lock cycle. The audio thread never takes it (CONV-RT-02).

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
#include <thread>
#include <utility>

#include "core/Engine.h"
#include "core/RenderTarget.h"
#include "facade/AssetTable.h"
#include "facade/DriverAdapter.h"
#include "facade/FacadeErrors.h"
#include "facade/FacadeOptions.h"
#include "graph/GraphCompiler.h"
#include "graph/NodeRegistry.h"
#include "io/AudioFileLoader.h"
#include "io/ExportSpec.h"
#include "io/OfflineDriver.h"
#include "time/TempoMap.h"

// T-013's node module registers the clip player and channel strip. Until it is merged the facade
// builds graphs of the engine's own kinds only.
#if __has_include("nodes/BuiltinNodes.h")
#include "nodes/BuiltinNodes.h"
#define DAW_FACADE_HAS_BUILTIN_NODES 1
#else
#define DAW_FACADE_HAS_BUILTIN_NODES 0
#endif

namespace daw {

namespace {

constexpr std::size_t kMaxEvents = 1024;      // BRIDGE-004: polled at 60 Hz; overflow drops oldest
constexpr std::size_t kMaxFinishedJobs = 1024;
constexpr auto kExportGraphWait = std::chrono::seconds(30);

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

// The registry every facade builds graphs with: the engine's kinds, the built-in nodes (T-013)
// reading this facade's assets, then whatever the creator adds.
Result<NodeRegistry> makeRegistry(AssetTable& assets, const FacadeOptions& options) {
    NodeRegistry registry = NodeRegistry::withBuiltins();
#if DAW_FACADE_HAS_BUILTIN_NODES
    // DW-041: clip players resolve assetIDs here when daw.compile creates them.
    auto registered = registerBuiltinNodes(registry, [&assets](uint64_t assetID) { return assets.find(assetID); });
    if (!registered) return registered.error();
#else
    (void)assets;
#endif
    if (options.registerNodes) {
        auto registered = options.registerNodes(registry);
        if (!registered) return registered.error();
    }
    return registry;
}

} // namespace

// MARK: Impl

struct EngineFacade::Impl {
    Impl(EngineMode mode, const DriverConfig& config, FacadeOptions options);
    ~Impl();

    // Everything below runs with `mutex` held.
    void pump();
    void pushEvent(EngineEventPOD event);
    bool rendererActive() const { return exportRunning || (driver && driver->running()); }
    void applyTransportCommands();
    JobID addJob(JobKind kind, JobState state);
    void finishJob(JobStatus& job, FacadeError error);
    void pruneJobs();
    GraphStatusPOD graphStatusLocked() const;

    void exportLoop();
    void runExport(JobID job, Tick from, Tick to, const ExportSpecPOD& spec);

    std::atomic<uint32_t> refs{1};  // BRIDGE-001
    uint64_t instanceID = 0;
    const EngineMode mode;

    // Declaration order is destruction order in reverse: the loader and compiler threads stop
    // before the state their callbacks touch, and the engine outlives everything rendering
    // into it. ~Impl stops the driver and the export thread first.
    mutable std::mutex mutex;
    DriverConfig config;
    double sampleRate = 0;

    // Graphs (DW-047, DW-053). applyGraph is the compiler's only submitter, so its tickets are
    // the versions applyGraph stamps (1, 2, …).
    uint64_t submitted = 0;
    uint64_t lastSeenCompleted = 0;  // graphRejected events up to here
    std::map<uint64_t, TempoMapDesc> tempoByVersion;  // DW-064: published and later versions

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
    struct ExportRequest {
        JobID job;
        Tick from, to;
        ExportSpecPOD spec;
    };
    std::deque<ExportRequest> exportQueue;
    bool stopping = false;
    std::condition_variable exportWake;

    Engine engine;
    AssetTable assets;
    std::unique_ptr<GraphCompiler> compiler;
    AudioFileLoader loader;
    std::unique_ptr<DriverAdapter> driver;
    bool driverStarted = false;  // the device should be running (export pauses it)
    std::thread exportThread;    // last: started once everything above exists
};

EngineFacade::Impl::Impl(EngineMode m, const DriverConfig& cfg, FacadeOptions options)
    : mode(m), config(cfg) {
    sampleRate = cfg.sampleRate;
    if (mode == EngineMode::realtime) {
        driver = std::move(options.driver);
        if (driver) {
            auto started = driver->start(engine, config);
            if (started) {
                driverStarted = true;
                sampleRate = driver->sampleRate();
            } else {
                EngineEventPOD event;
                event.type = EngineEventType::deviceChanged;
                event.error = toFacadeError(started.error());
                pushEvent(std::move(event));
            }
        }
    }
    if (!(sampleRate >= kMinSampleRate && sampleRate <= kMaxSampleRate)) sampleRate = 48000.0;

    auto registry = makeRegistry(assets, options);
    if (!registry) {
        // A registration hook failed: build graphs of the engine's kinds only, and say why.
        EngineEventPOD event;
        event.type = EngineEventType::graphRejected;
        event.error = toFacadeError(registry.error());
        pushEvent(std::move(event));
    }
    compiler = std::make_unique<GraphCompiler>(
        engine, registry ? std::move(registry).value() : NodeRegistry::withBuiltins(), sampleRate);
    exportThread = std::thread([this] { exportLoop(); });
}

EngineFacade::Impl::~Impl() {
    {
        std::lock_guard lock(mutex);
        stopping = true;
        if (driver) driver->stop();
    }
    exportWake.notify_all();
    exportThread.join();
    // The loader and compiler join in their destructors, then the engine frees what's left.
}

void EngineFacade::Impl::pushEvent(EngineEventPOD event) {
    if (events.size() >= kMaxEvents) {
        events.pop_front();
        ++eventsDropped;
    }
    events.push_back(std::move(event));
}

GraphStatusPOD EngineFacade::Impl::graphStatusLocked() const {
    const GraphCompiler::Status status = compiler->status();
    GraphStatusPOD out;
    out.submittedVersion = submitted;
    out.completedVersion = status.completed;
    out.publishedVersion = status.publishedVersion;
    if (status.lastError) out.lastError = toFacadeError(*status.lastError);
    return out;
}

// Turns what changed since the last call into events and finishes deferred param frees.
void EngineFacade::Impl::pump() {
    const GraphCompiler::Status status = compiler->status();

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

    // DW-064: keep the tempo map of the published version and of everything newer.
    tempoByVersion.erase(tempoByVersion.begin(), tempoByVersion.lower_bound(status.publishedVersion));

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
        }
        runExport(request.job, request.from, request.to, request.spec);
    }
}

void EngineFacade::Impl::runExport(JobID jobID, Tick from, Tick to, const ExportSpecPOD& pod) {
    uint64_t latest;
    {
        std::lock_guard lock(mutex);
        latest = submitted;
        if (auto it = jobs.find(jobID); it != jobs.end()) it->second.state = JobState::running;
    }
    // Render what was applied last: wait until every submitted description has been built.
    const bool built = latest == 0 || compiler->wait(latest, kExportGraphWait);

    ExportSpec spec;
    spec.file = pod.path;
    spec.fileType = toFileType(pod.fileType);
    spec.sampleFormat = toSampleFormat(pod.sampleFormat);
    spec.dither = pod.dither;
    spec.ditherSeed = pod.ditherSeed;
    spec.numChannels = pod.numChannels;
    spec.blockSize = pod.blockSize;
    spec.tail = TailSpec{pod.tailEnabled, pod.tailThresholdDb, pod.tailQuietSeconds, pod.tailMaxSeconds};

    FacadeError error;
    bool render = false;
    {
        std::lock_guard lock(mutex);
        pump();
        const GraphCompiler::Status status = compiler->status();
        auto tempo = tempoByVersion.find(status.publishedVersion);
        if (!built) {
            error = facadeError(FacadeErrorCode::internal, "offline render: graph build timed out");
        } else if (status.publishedVersion == 0 || tempo == tempoByVersion.end()) {
            error = facadeError(FacadeErrorCode::invalidArgument, "offline render: no graph applied");
        } else if (auto map = makeTempoMap(tempo->second, sampleRate); !map) {
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
            auto restarted = driver->start(engine, config);
            if (!restarted) {
                driverStarted = false;
                EngineEventPOD event;
                event.type = EngineEventType::deviceChanged;
                event.error = toFacadeError(restarted.error());
                pushEvent(std::move(event));
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

EngineFacade* EngineFacade::create(EngineMode mode, const DriverConfig& config) {
    FacadeOptions options;
    if (mode == EngineMode::realtime) options.driver = makeDefaultDriverAdapter();
    return EngineFacadeAccess::create(mode, config, std::move(options));
}

EngineFacade* EngineFacadeAccess::create(EngineMode mode, const DriverConfig& config, FacadeOptions options) {
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
    impl_->tempoByVersion[copy.version] = copy.tempo;
    const uint64_t ticket = impl_->compiler->submit(std::move(copy));
    (void)ticket;  // == version: applyGraph is the only submitter, under this lock
    impl_->pump();
    return impl_->submitted;
}

GraphStatusPOD EngineFacade::graphStatus() const {
    std::lock_guard lock(impl_->mutex);
    impl_->pump();
    return impl_->graphStatusLocked();
}

GraphStatusPOD EngineFacade::waitForGraph(uint64_t version, uint32_t timeoutMs) {
    (void)impl_->compiler->wait(version, std::chrono::milliseconds(timeoutMs));
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
    (void)impl_->engine.transport().play();
    impl_->applyTransportCommands();
}

void EngineFacade::stop() {
    std::lock_guard lock(impl_->mutex);
    (void)impl_->engine.transport().stop();
    impl_->applyTransportCommands();
}

void EngineFacade::locate(Tick tick) {
    std::lock_guard lock(impl_->mutex);
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
    JobID jobID;
    AudioLoadRequest request;
    {
        std::lock_guard lock(impl_->mutex);
        if (path.empty()) return 0;
        jobID = impl_->addJob(JobKind::loadAsset, JobState::queued);
        request.assetID = assetID;
        request.file = path;
        request.sessionRate = impl_->sampleRate;
    }
    // Outside the facade lock: the completion takes it, on daw.loader.
    Impl* impl = impl_;
    impl_->loader.submit(std::move(request), [impl, jobID, assetID](Result<LoadedAudio> loaded) {
        EngineEventPOD event;
        event.subject = assetID;
        event.job = jobID;
        AssetInfoPOD info;
        if (loaded) {
            const AudioAsset& asset = *loaded->asset;
            info = AssetInfoPOD{assetID, asset.channels, asset.frames, asset.sampleRate,
                                loaded->fileSampleRate, loaded->fileFrames, loaded->resampled};
            impl->assets.put(assetID, std::move(loaded->asset));
            event.type = EngineEventType::assetLoaded;
        } else {
            event.type = EngineEventType::assetLoadFailed;
            event.error = toFacadeError(loaded.error());
        }
        std::lock_guard lock(impl->mutex);
        if (auto it = impl->jobs.find(jobID); it != impl->jobs.end()) {
            it->second.asset = info;
            impl->finishJob(it->second, event.error);
        }
        impl->pushEvent(std::move(event));
    });
    return jobID;
}

JobStatus EngineFacade::pollJob(JobID job) const {
    std::lock_guard lock(impl_->mutex);
    auto it = impl_->jobs.find(job);
    return it == impl_->jobs.end() ? JobStatus{} : it->second;
}

// MARK: Recording and plugins: later tasks (09, 10)

void EngineFacade::armInput(NodeID, uint32_t, bool) {}  // REC (T-030s)

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
    impl_->exportQueue.push_back({job, from, to, spec});
    impl_->exportWake.notify_one();
    return job;
}

// MARK: Device

std::vector<DeviceInfoPOD> EngineFacade::devices() const {
    std::lock_guard lock(impl_->mutex);
    return impl_->driver ? impl_->driver->devices() : std::vector<DeviceInfoPOD>{};
}

FacadeError EngineFacade::setDevice(const DriverConfig& config) {
    std::lock_guard lock(impl_->mutex);
    Impl& impl = *impl_;
    if (impl.mode != EngineMode::realtime || !impl.driver)
        return facadeError(FacadeErrorCode::unsupported, "no device driver in this engine");
    // Graphs and assets are built at the session rate; changing it is IO-021/IO-033 (T-051, T-056).
    if (config.sampleRate != 0 && config.sampleRate != impl.sampleRate)
        return facadeError(FacadeErrorCode::unsupported, "changing the session rate is not supported yet");
    impl.config = config;
    // During an export the device is paused; it restarts with the new config afterwards.
    if (impl.exportRunning) return {};
    impl.driver->stop();
    auto started = impl.driver->start(impl.engine, config);
    impl.driverStarted = started.ok();
    if (!started) return toFacadeError(started.error());
    if (impl.driver->sampleRate() != impl.sampleRate) {
        impl.driver->stop();
        impl.driverStarted = false;
        return facadeError(FacadeErrorCode::unsupported, "the device runs at another rate than the session");
    }
    return {};
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
    t.graphVersion = impl_->compiler->status().publishedVersion;  // DW-047
    t.blocksRendered = impl_->engine.blocksRendered();
    t.paramsAllocated = impl_->engine.params().allocatedCount();
    for (const auto& p : impl_->pendingFrees) t.paramsPendingFree += p.count;
    t.assetsLoaded = impl_->assets.size();
    t.eventsDropped = impl_->eventsDropped;
    t.sampleRate = impl_->sampleRate;
    t.deviceRunning = impl_->driver && impl_->driver->running();
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

// Meters are written per MeterID, which GraphBuilder doesn't assign yet (MIX-005, T-020).
MeterPOD EngineFacade::meter(NodeID) const { return MeterPOD{}; }

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

// Param descriptions per kind arrive with the nodes that define them (06, T-013 onwards).
std::string EngineFacade::paramInfoJSON(NodeKind) const { return "[]"; }

} // namespace daw

// MARK: Lifetime (BRIDGE-001)

void retainFacade(daw::EngineFacade* facade) {
    facade->impl_->refs.fetch_add(1, std::memory_order_relaxed);
}

void releaseFacade(daw::EngineFacade* facade) {
    if (facade->impl_->refs.fetch_sub(1, std::memory_order_acq_rel) == 1) delete facade;
}
