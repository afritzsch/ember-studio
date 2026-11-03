// T-056 checks for session-rate changes through the facade. Run from Tests/DAWEngineTests/
// SessionRateTests.swift; see SessionRateChecks.h.

#include "SessionRateChecks.h"

#include <chrono>
#include <cmath>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <thread>
#include <vector>

#include "ExportTestSupport.h"
#include "TestAudio.h"
#include "daw/EngineFacade.h"
#include "facade/AssetReloader.h"
#include "facade/DriverAdapter.h"
#include "facade/FacadeOptions.h"
#include "io/FakeDeviceDriver.h"
#include "io/PeakMipmap.h"

using namespace std::chrono_literals;

namespace daw::testing {

namespace {

constexpr double kFileRate = 44100.0;
constexpr double kTone = 1000.0;

bool eventually(const std::function<bool()>& done, std::chrono::milliseconds timeout = 10000ms) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (!done()) {
        if (std::chrono::steady_clock::now() > deadline) return false;
        std::this_thread::sleep_for(1ms);
    }
    return true;
}

// A 1 kHz sine at 0.5, `seconds` long, at 44.1 kHz.
Channels tone(double seconds, uint32_t channels = 1) {
    const auto frames = static_cast<size_t>(seconds * kFileRate);
    std::vector<float> samples(frames);
    for (size_t i = 0; i < frames; ++i)
        samples[i] = 0.5f * static_cast<float>(std::sin(2.0 * M_PI * kTone * double(i) / kFileRate));
    return Channels(channels, samples);
}

// Polls events into `seen`.
struct EventLog {
    std::vector<EngineEventPOD> seen;
    void poll(EngineFacade& facade) {
        EngineEventPOD batch[32];
        for (size_t n; (n = facade.pollEvents(batch, 32)) > 0;)
            for (size_t i = 0; i < n; ++i) seen.push_back(batch[i]);
    }
    std::vector<EngineEventPOD> reloads() const {
        std::vector<EngineEventPOD> out;
        for (const auto& e : seen)
            if (e.type == EngineEventType::assetsReloaded) out.push_back(e);
        return out;
    }
    bool finished() const {
        for (const auto& e : seen)
            if (e.type == EngineEventType::assetsReloaded && e.reload.phase == AssetsReloadPhase::finished) return true;
        return false;
    }
    bool waitFinished(EngineFacade& facade, std::chrono::milliseconds timeout = 20000ms) {
        return eventually([&] {
            poll(facade);
            return finished();
        }, timeout);
    }
    void clear() { seen.clear(); }
};

JobStatus waitJob(EngineFacade& facade, JobID job, std::chrono::milliseconds timeout = 20000ms) {
    JobStatus status;
    (void)eventually([&] {
        status = facade.pollJob(job);
        return status.state == JobState::succeeded || status.state == JobState::failed;
    }, timeout);
    return status;
}

// master(1) ← strip(3) ← player(2), one clip of `asset` from tick `start` (offset 0, 2 s long).
GraphDescription clipGraph(uint64_t asset, Tick start, ParamID strip) {
    GraphDescriptionBuilder b;
    b.addNode(1, NodeKind::master, 1, 0, 0, "");
    b.addNode(2, NodeKind::audioClipPlayer, 1, 0, 0, "");
    b.addNode(3, NodeKind::channelStrip, 1, strip, 4, "");
    b.addEdge(10, 2, 3, EdgeKind::audio, 0);
    b.addEdge(11, 3, 1, EdgeKind::audio, 0);
    b.addClip(2, 20, start, 4 * kPPQ, asset, 0, 1.0f, 0, 0);
    b.setTempo(0, 120.0);
    b.setTimeSignature(0, 4, 4);
    b.setMaster(1);
    return b.description();
}

bool published(EngineFacade& facade, uint64_t version) {
    const GraphStatusPOD s = facade.waitForGraph(version, 5000);
    return s.publishedVersion >= version && s.lastError.ok();
}

// Upward zero crossings per second over [from, to) of `x` at `rate`.
double crossingsPerSecond(const std::vector<float>& x, double rate, size_t from, size_t to) {
    size_t n = 0;
    for (size_t i = from + 1; i < to && i < x.size(); ++i) n += x[i - 1] <= 0.0f && x[i] > 0.0f;
    return double(n) * rate / double(to - from);
}

size_t firstAudible(const std::vector<float>& x, float threshold = 1e-4f) {
    for (size_t i = 0; i < x.size(); ++i)
        if (std::fabs(x[i]) > threshold) return i;
    return x.size();
}

EngineFacade* offlineFacade(double rate) {
    DriverConfigPOD config;
    config.sampleRate = rate;
    return EngineFacade::create(EngineMode::offline, config);
}

} // namespace

// MARK: AssetReloader

CheckResult assetReloaderBookkeeping() {
    CheckResult checks;
    AssetReloader r;
    DAW_CHECK(!r.active());
    // Nothing loaded: an empty pass, never active.
    DAW_CHECK(r.beginPass(48000, 44100).empty());
    DAW_CHECK(!r.active() && r.progress().total == 0 && r.progress().rate == 44100);

    (void)r.recordLoad(9, {"/a/nine.wav", ""});
    (void)r.recordLoad(3, {"/a/three.wav", "/cache"});
    (void)r.recordLoad(5, {"/a/five.wav", ""});
    auto pass = r.beginPass(48000, 96000);
    DAW_CHECK(pass.size() == 3 && r.active());
    if (pass.size() != 3) return checks;
    DAW_CHECK(pass[0].assetID == 3 && pass[1].assetID == 5 && pass[2].assetID == 9);  // ID order
    DAW_CHECK(pass[0].source.path == "/a/three.wav" && pass[0].source.peakCacheDir == "/cache");

    // A new pass abandons the first one: its results are stale.
    auto second = r.beginPass(96000, 88200);
    DAW_CHECK(r.complete(pass[0], {}) == AssetReloader::Outcome::stale);
    DAW_CHECK(r.progress().done == 0 && r.progress().previousRate == 96000 && r.progress().rate == 88200);

    // Asset 5 loads again meanwhile: the newer load wins, so its result is left out (but counted).
    (void)r.recordLoad(5, {"/b/five.wav", ""});
    DAW_CHECK(r.complete(second[0], {}) == AssetReloader::Outcome::progress);  // failed (null asset)
    DAW_CHECK(r.complete(second[1], {}) == AssetReloader::Outcome::progress);  // superseded
    DAW_CHECK(r.progress().done == 2 && r.progress().failed == 1);
    DAW_CHECK(r.complete(second[2], {}) == AssetReloader::Outcome::finished);
    DAW_CHECK(r.progress().done == 3 && r.progress().total == 3 && r.progress().failed == 2);
    DAW_CHECK(r.active());  // until the swap takes the results
    auto staged = r.takeStaged();
    DAW_CHECK(!r.active());
    DAW_CHECK(staged.size() == 2 && staged[0].assetID == 3 && staged[1].assetID == 9);
    // A late result after the pass ended is stale too.
    DAW_CHECK(r.complete(second[0], {}) == AssetReloader::Outcome::stale);
    // The next pass reloads the newer source.
    auto third = r.beginPass(88200, 48000);
    DAW_CHECK(third.size() == 3 && third[1].source.path == "/b/five.wav");
    return checks;
}

// MARK: Offline

CheckResult facadeSessionRateReconvertsAssets() {
    CheckResult checks;
    TempDir dir;
    EngineFacade* created = offlineFacade(48000);
    DAW_CHECK(created != nullptr);
    if (!created) return checks;
    EngineFacade& facade = *created;
    EventLog log;

    // 30 s of stereo, so the re-conversion takes long enough to watch play() be refused.
    const auto file = dir.path() / "tone.wav";
    DAW_CHECK(writeTestFile(file, "wav-f32", kFileRate, tone(30, 2)).ok());
    JobStatus loaded = waitJob(facade, facade.loadAsset(1, file.string()));
    DAW_CHECK(loaded.state == JobState::succeeded && loaded.asset.sampleRate == 48000 && loaded.asset.resampled);
    DAW_CHECK(facade.peaks(1, 0).sampleRate == 48000);

    const ParamID strip = facade.allocateParams(4);
    facade.setParam(strip + 0, 1.0f);
    DAW_CHECK(published(facade, facade.applyGraph(clipGraph(1, 2 * kPPQ, strip))));  // the clip at 1 s
    log.poll(facade);
    log.clear();

    // Bad and no-op requests.
    DAW_CHECK(facade.setSessionSampleRate(50000).code == FacadeErrorCode::invalidArgument);
    DAW_CHECK(facade.setSessionSampleRate(48000).ok());
    log.poll(facade);
    DAW_CHECK(log.reloads().empty() && facade.telemetry().sampleRate == 48000);

    // IO-033: the change. The re-conversion runs on daw.loader; until it is done play() is refused.
    DAW_CHECK(facade.setSessionSampleRate(96000).ok());
    const TelemetryPOD during = facade.telemetry();
    DAW_CHECK(during.sampleRate == 96000);
    // 30 s of stereo at Mastering quality takes far longer than returning from the call.
    DAW_CHECK(during.assetsReloadPending == 1);
    facade.play();
    DAW_CHECK(!facade.transport().playing);
    // An export asked for now waits for the new assets (it would otherwise render silence: a
    // clip player plays only assets at the session rate).
    ExportSpecPOD spec;
    spec.path = (dir.path() / "out.wav").string();
    spec.tailEnabled = false;
    const JobStatus render = waitJob(facade, facade.renderOffline(0, 8 * kPPQ, spec), 60000ms);  // 4 s
    DAW_CHECK(render.state == JobState::succeeded && render.render.rtViolations == 0);
    DAW_CHECK(render.render.sampleRate == 96000);

    DAW_CHECK(log.waitFinished(facade));
    const auto reloads = log.reloads();
    DAW_CHECK(reloads.size() == 3);
    if (reloads.size() == 3) {
        const AssetsReloadPOD& started = reloads[0].reload;
        DAW_CHECK(started.phase == AssetsReloadPhase::started && started.previousSampleRate == 48000 &&
                  started.sampleRate == 96000 && started.total == 1 && started.done == 0);
        const AssetsReloadPOD& progress = reloads[1].reload;
        DAW_CHECK(progress.phase == AssetsReloadPhase::progress && progress.assetID == 1 && progress.done == 1 &&
                  progress.total == 1 && reloads[1].subject == 1 && reloads[1].error.ok());
        const AssetsReloadPOD& finished = reloads[2].reload;
        DAW_CHECK(finished.phase == AssetsReloadPhase::finished && finished.done == 1 && finished.failed == 0 &&
                  reloads[2].error.ok());
    }
    const TelemetryPOD after = facade.telemetry();
    DAW_CHECK(after.assetsReloadPending == 0 && after.assetsLoaded == 1);
    DAW_CHECK(facade.peaks(1, 0).sampleRate == 96000);
    DAW_CHECK(facade.peaks(1, 0).frames == framesAtRate(30 * 44100, kFileRate, 96000));

    // The render: silence until the clip's tick (1 s = sample 96000), then the tone at 1 kHz.
    auto back = readBack(spec.path, 96000);
    DAW_CHECK(back.ok());
    if (back && back->size() == 2 && (*back)[0].size() == 4 * 96000) {
        const auto& left = (*back)[0];
        const size_t onset = firstAudible(left);
        DAW_CHECK(onset >= 96000 && onset <= 96000 + 8);  // the sine starts at 0
        const double hz = crossingsPerSecond(left, 96000, 120000, 120000 + 96000);
        DAW_CHECK(std::fabs(hz - kTone) <= 2.0);
    } else {
        DAW_CHECK(false);
    }

    // Playback works again once it's done.
    facade.play();
    DAW_CHECK(facade.transport().playing);
    facade.stop();
    DAW_CHECK(facade.telemetry().rtViolations == 0);
    releaseFacade(created);
    return checks;
}

CheckResult facadeSessionRateFailureAndPeakCache() {
    CheckResult checks;
    TempDir dir;
    EngineFacade* created = offlineFacade(48000);
    DAW_CHECK(created != nullptr);
    if (!created) return checks;
    EngineFacade& facade = *created;
    EventLog log;

    const auto keep = dir.path() / "keep.wav";
    const auto gone = dir.path() / "gone.wav";
    const auto cache = dir.path() / "Cache";
    DAW_CHECK(writeTestFile(keep, "wav-f32", kFileRate, tone(1)).ok());
    DAW_CHECK(writeTestFile(gone, "wav-f32", kFileRate, tone(1)).ok());
    // DW-077: asset 1 through the peak cache, asset 2 without.
    DAW_CHECK(waitJob(facade, facade.loadAsset(1, keep.string(), cache.string())).state == JobState::succeeded);
    DAW_CHECK(waitJob(facade, facade.loadAsset(2, gone.string())).state == JobState::succeeded);
    const auto cacheFile = PeakMipmap::cachePath(cache, 1);
    auto cached = PeakMipmap::read(cacheFile);
    DAW_CHECK(cached.ok() && cached->sampleRate() == 48000);
    DAW_CHECK(!std::filesystem::exists(PeakMipmap::cachePath(cache, 2)));
    log.poll(facade);
    log.clear();

    std::filesystem::remove(gone);
    DAW_CHECK(facade.setSessionSampleRate(44100).ok());
    DAW_CHECK(log.waitFinished(facade));
    const auto reloads = log.reloads();
    DAW_CHECK(reloads.size() == 4);  // started, progress 1, progress 2, finished
    if (reloads.size() == 4) {
        DAW_CHECK(reloads[0].reload.total == 2);
        DAW_CHECK(reloads[1].reload.assetID == 1 && reloads[1].error.ok());
        DAW_CHECK(reloads[2].reload.assetID == 2 && !reloads[2].error.ok() && reloads[2].reload.failed == 1);
        DAW_CHECK(reloads[3].reload.phase == AssetsReloadPhase::finished && reloads[3].reload.failed == 1 &&
                  reloads[3].error.code == FacadeErrorCode::io);
    }
    bool namedFailure = false;
    for (const auto& e : log.seen)
        namedFailure |= e.type == EngineEventType::assetLoadFailed && e.subject == 2;
    DAW_CHECK(namedFailure);
    DAW_CHECK(facade.telemetry().assetsLoaded == 1);
    DAW_CHECK(!facade.peaks(2, 0).found);
    const PeakLevelPOD kept = facade.peaks(1, 0);
    DAW_CHECK(kept.found && kept.sampleRate == 44100 && kept.frames == 44100);
    // IO-034: the cache saw the stale rate and rewrote itself.
    cached = PeakMipmap::read(cacheFile);
    DAW_CHECK(cached.ok() && cached->sampleRate() == 44100);
    releaseFacade(created);
    return checks;
}

// MARK: Fake devices

CheckResult facadeDeviceFallbackReconvertsAssets() {
    CheckResult checks;
    TempDir dir;
    auto owned = std::make_unique<FakeDeviceDriverAdapter>(defaultFakeDeviceSpec());
    FakeDeviceDriverAdapter* adapter = owned.get();
    FacadeOptions options;
    options.driver = std::move(owned);
    DriverConfigPOD config;
    config.driver = DeviceDriverKind::fake;
    config.sampleRate = 48000;
    EngineFacade* created = EngineFacadeAccess::create(EngineMode::realtime, config, std::move(options));
    DAW_CHECK(created != nullptr);
    if (!created) return checks;
    EngineFacade& facade = *created;
    EventLog log;
    DAW_CHECK(facade.telemetry().outputDeviceID == 1 && facade.telemetry().sampleRate == 48000);

    const auto file = dir.path() / "tone.wav";
    DAW_CHECK(writeTestFile(file, "wav-f32", kFileRate, tone(2)).ok());
    DAW_CHECK(waitJob(facade, facade.loadAsset(1, file.string())).asset.sampleRate == 48000);
    const ParamID strip = facade.allocateParams(4);
    DAW_CHECK(published(facade, facade.applyGraph(clipGraph(1, 0, strip))));
    log.poll(facade);
    log.clear();

    // IO-021: A is lost, B runs only 44.1 kHz → the session rate changes → IO-033 re-converts.
    DeviceEventPOD lost;
    lost.kind = DeviceEventKind::deviceLost;
    DAW_CHECK(facade.simulateDeviceEvent(lost).ok());
    DAW_CHECK(log.waitFinished(facade));
    const auto reloads = log.reloads();
    DAW_CHECK(reloads.size() == 3);
    if (reloads.size() == 3) {
        DAW_CHECK(reloads[0].reload.phase == AssetsReloadPhase::started && reloads[0].reload.previousSampleRate == 48000 &&
                  reloads[0].reload.sampleRate == 44100);
        DAW_CHECK(reloads[2].reload.phase == AssetsReloadPhase::finished && reloads[2].error.ok());
    }
    bool deviceChanged = false;
    for (const auto& e : log.seen)
        deviceChanged |= e.type == EngineEventType::deviceChanged && e.device.deviceID == 2 && e.device.sampleRate == 44100;
    DAW_CHECK(deviceChanged);
    PeakLevelPOD peaks = facade.peaks(1, 0);
    DAW_CHECK(peaks.sampleRate == 44100 && peaks.frames == 2 * 44100);  // the file's own rate: no resampling
    DAW_CHECK(facade.telemetry().outputDeviceID == 2 && facade.telemetry().sampleRate == 44100);

    // B can't run 48 kHz: refused, and nothing changes.
    log.clear();
    DAW_CHECK(facade.setSessionSampleRate(48000).code == FacadeErrorCode::unsupported);
    log.poll(facade);
    DAW_CHECK(log.reloads().empty() && facade.telemetry().sampleRate == 44100 && facade.telemetry().deviceRunning);

    // A is back; following the default, the engine stays on B until asked. Then 96 kHz on A.
    DeviceEventPOD restored;
    restored.kind = DeviceEventKind::deviceRestored;
    restored.deviceID = 1;
    DAW_CHECK(facade.simulateDeviceEvent(restored).ok());
    DriverConfigPOD onA = config;
    onA.outputDevice = 1;
    onA.sampleRate = 0;  // keep the session rate
    DAW_CHECK(facade.setDevice(onA).ok());
    log.clear();
    DAW_CHECK(facade.setSessionSampleRate(96000).ok());
    DAW_CHECK(log.waitFinished(facade));
    DAW_CHECK(facade.telemetry().sampleRate == 96000 && facade.telemetry().outputDeviceID == 1);
    DAW_CHECK(facade.peaks(1, 0).sampleRate == 96000);
    facade.play();
    DAW_CHECK(eventually([&] { return facade.transport().playing; }, 2000ms));
    facade.stop();

    FakeDeviceDriver* driver = adapter->driver();
    DAW_CHECK((driver ? driver->rtViolations() : 0) == 0);
    DAW_CHECK(facade.telemetry().rtViolations == 0);
    releaseFacade(created);
    return checks;
}

} // namespace daw::testing
