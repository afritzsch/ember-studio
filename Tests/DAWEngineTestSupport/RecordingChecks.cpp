// T-052 checks for audio recording (REC-001..005). Run from Tests/DAWEngineTests/RecordingTests.swift;
// see RecordingChecks.h.

#include "RecordingChecks.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <random>
#include <thread>
#include <utility>
#include <vector>

#include "TestAudio.h"
#include "core/AudioBufferView.h"
#include "core/RtTrap.h"
#include "daw/EngineFacade.h"
#include "facade/DriverAdapter.h"
#include "facade/FacadeOptions.h"
#include "io/AudioFileLoader.h"
#include "io/FakeDeviceDriver.h"
#include "nodes/Metronome.h"
#include "record/RecordFifo.h"
#include "record/Recorder.h"
#include "time/TempoMap.h"
#include "time/Transport.h"

using namespace std::chrono_literals;

namespace daw::testing {

namespace {

constexpr double kRate = 48000.0;
constexpr uint32_t kInChannels = 4;

TempoMap makeTempo() { return std::move(TempoMap::make({{0, 120.0}}, {{0, 4, 4}}, kRate)).value(); }

// Input channel c at transport position q: integers, exact in float32 (< 2^24).
float value(uint32_t c, int64_t q) { return static_cast<float>((c + 1) * 1'000'000 + q); }

// A Transport driven by hand and a 4-channel device input whose samples say where they were
// captured (value()), fed to a Recorder block by block like DeviceRenderer does.
struct Rig {
    TempDir dir;
    Recorder recorder;
    Transport transport;
    TempoMap tempo = makeTempo();
    std::vector<std::vector<float>> in = std::vector<std::vector<float>>(kInChannels, std::vector<float>(kMaxBlock));
    float* ptrs[kInChannels]{};
    uint64_t violations = 0;
    int64_t capturedFirst = INT64_MIN;  // transport position of the first frame that records
    int64_t captured = 0;               // frames played while playing + recording

    Rig() {
        for (uint32_t c = 0; c < kInChannels; ++c) ptrs[c] = in[c].data();
        recorder.setDirectory(dir.path() / "Recordings");
    }

    // One block of `n` frames; `twice` calls the capture again without advancing (a stale block).
    void block(uint32_t n, bool twice = false) {
        RtScope scope;
        const TransportBlock& b = transport.advance(tempo, n);
        for (uint32_t c = 0; c < kInChannels; ++c) std::fill(in[c].begin(), in[c].begin() + n, 0.0f);
        for (uint8_t s = 0; s < b.numSegments && s < 2; ++s)
            for (uint32_t f = 0; f < b.seg[s].numFrames; ++f)
                for (uint32_t c = 0; c < kInChannels; ++c)
                    in[c][b.seg[s].frameOffset + f] = value(c, b.seg[s].startSample + f);
        AudioBufferView view{ptrs, kInChannels, n};
        recorder.captureBlock(transport, view, n);
        if (twice) recorder.captureBlock(transport, view, n);
        violations += scope.violations();
        if (b.playing && b.recording && b.numSegments > 0) {
            if (capturedFirst == INT64_MIN) capturedFirst = b.seg[0].startSample;
            captured += n;
        }
    }
};

std::optional<LoadedAudio> load(const std::string& file) {
    AudioLoadRequest request;
    request.file = file;
    request.sessionRate = kRate;
    auto loaded = AudioFileLoader::load(request);
    if (!loaded) return std::nullopt;
    return std::move(loaded).value();
}

const FinalizedTake* takeOf(const std::vector<FinalizedTake>& takes, NodeID track) {
    for (const FinalizedTake& t : takes)
        if (t.track == track) return &t;
    return nullptr;
}

} // namespace

// MARK: REC-001 FIFO

CheckResult recordFifoKeepsBlocksWhole() {
    CheckResult checks;
    DAW_CHECK(RecordFifo::kFrames >= 2 * 96000);
    auto fifo = std::make_unique<RecordFifo>();
    std::vector<float> l(4096), r(4096);
    for (size_t i = 0; i < l.size(); ++i) {
        l[i] = static_cast<float>(i);
        r[i] = -static_cast<float>(i);
    }
    uint64_t violations = 0;
    int64_t at = 0;
    uint32_t accepted = 0;
    {
        RtScope scope;
        // Fill to the brim with 4096-frame blocks: exactly kFrames / 4096 fit.
        for (size_t i = 0; i < RecordFifo::kFrames / 4096 + 3; ++i) {
            if (fifo->write(l.data(), r.data(), 4096, at)) ++accepted;
            at += 4096;
        }
        DAW_CHECK(!fifo->write(l.data(), nullptr, 1, at));  // full: a single frame is refused
        violations += scope.violations();
    }
    DAW_CHECK(accepted == RecordFifo::kFrames / 4096);
    DAW_CHECK(fifo->framesQueued() == RecordFifo::kFrames);
    RecordChunk chunk;
    std::vector<RecordFrame> frames(4096);
    for (uint32_t k = 0; k < accepted; ++k) {
        DAW_CHECK(fifo->popChunk(chunk));
        DAW_CHECK(chunk.fileFrame == int64_t{k} * 4096 && chunk.frames == 4096);
        DAW_CHECK(fifo->popFrames(frames) == 4096);
        DAW_CHECK(frames[17].left == 17.0f && frames[17].right == -17.0f);
    }
    DAW_CHECK(!fifo->popChunk(chunk));
    // A null channel records silence.
    DAW_CHECK(fifo->write(l.data(), nullptr, 8, 100));
    DAW_CHECK(fifo->popChunk(chunk) && chunk.fileFrame == 100 && chunk.frames == 8);
    DAW_CHECK(fifo->popFrames(std::span<RecordFrame>(frames.data(), 8)) == 8);
    DAW_CHECK(frames[3].left == 3.0f && frames[3].right == 0.0f);
    DAW_CHECK(violations == 0);
    return checks;
}

// MARK: REC-001, REC-003, REC-004

CheckResult recorderCapturesArmedPairs() {
    CheckResult checks;
    Rig rig;
    Recorder& rec = rig.recorder;
    rec.setArmed(7, 1, true);
    rec.setArmed(9, 0, true);
    rec.setArmed(11, 2, true);
    rec.setArmed(11, 2, false);  // disarmed again
    rec.setLatency(100);
    DAW_CHECK(rec.armedCount() == 2);
    DAW_CHECK(rec.prepare(kRate).empty());

    std::mt19937 rng(52);
    std::uniform_int_distribution<uint32_t> size(1, 700);
    // Stopped, then playing without recording: nothing.
    for (int i = 0; i < 10; ++i) rig.block(size(rng));
    (void)rig.transport.play();
    for (int i = 0; i < 10; ++i) rig.block(size(rng));
    DAW_CHECK(!rec.capturing() && rig.captured == 0);

    (void)rig.transport.setRecording(true);
    for (int i = 0; i < 60; ++i) rig.block(size(rng), /*twice=*/i % 7 == 3);
    DAW_CHECK(rec.capturing());
    (void)rig.transport.setRecording(false);
    for (int i = 0; i < 10; ++i) rig.block(size(rng));
    const int64_t first = rig.capturedFirst, frames = rig.captured;

    const std::vector<FinalizedTake> takes = rec.finalize();
    DAW_CHECK(!rec.capturing());
    DAW_CHECK(takes.size() == 2);
    for (auto [track, pair] : {std::pair<NodeID, uint32_t>{7, 1}, {9, 0}}) {
        const FinalizedTake* take = takeOf(takes, track);
        DAW_CHECK(take != nullptr);
        if (!take) continue;
        DAW_CHECK(!take->error && take->droppedFrames == 0);
        DAW_CHECK(take->inputPair == pair && take->takeIndex == 0 && take->channels == 2);
        DAW_CHECK(take->sampleRate == kRate);
        DAW_CHECK(take->startSample == first - 100);  // REC-003
        DAW_CHECK(take->frames == frames);
        DAW_CHECK(std::filesystem::path(take->file).parent_path() == rig.dir.path() / "Recordings");
        DAW_CHECK(std::filesystem::path(take->file).extension() == ".caf");
        auto audio = load(take->file);
        DAW_CHECK(audio.has_value());
        if (!audio) continue;
        DAW_CHECK(audio->fileSampleRate == kRate && !audio->resampled);
        DAW_CHECK(audio->asset->channels == 2 && audio->asset->frames == frames);
        int bad = 0;
        for (int64_t k = 0; k < audio->asset->frames; ++k) {
            bad += audio->asset->data[0][k] != value(2 * pair, first + k);
            bad += audio->asset->data[1][k] != value(2 * pair + 1, first + k);
        }
        DAW_CHECK(bad == 0);
    }
    // Two tracks, two files.
    if (takes.size() == 2) DAW_CHECK(takes[0].file != takes[1].file);
    // A second take gets new files; the first ones stay.
    DAW_CHECK(rec.prepare(kRate).empty());
    rig.capturedFirst = INT64_MIN;
    rig.captured = 0;
    (void)rig.transport.setRecording(true);
    for (int i = 0; i < 5; ++i) rig.block(256);
    const std::vector<FinalizedTake> again = rec.finalize();
    DAW_CHECK(again.size() == 2);
    for (const FinalizedTake& t : again) {
        DAW_CHECK(t.frames == rig.captured && t.startSample == rig.capturedFirst - 100);
        for (const FinalizedTake& old : takes) DAW_CHECK(t.file != old.file);
        for (const FinalizedTake& old : takes) DAW_CHECK(std::filesystem::exists(old.file));
    }
    // Nothing captured since: finalize reports nothing.
    DAW_CHECK(rec.finalize().empty());
    DAW_CHECK(rig.violations == 0);
    return checks;
}

// MARK: REC-005

CheckResult recorderPunchesInAndOut() {
    CheckResult checks;
    for (uint32_t seed : {1u, 2u, 3u}) {
        Rig rig;
        Recorder& rec = rig.recorder;
        rec.setArmed(3, 0, true);
        rec.setLatency(100);
        rec.setPunch({true, 960, 1920});  // samples [24000, 48000) at 120 bpm, 48 kHz
        DAW_CHECK(rec.punch().enabled && rec.punch().in == 960 && rec.punch().out == 1920);
        (void)rec.prepare(kRate);
        (void)rig.transport.play();
        (void)rig.transport.setRecording(true);
        std::mt19937 rng(seed);
        std::uniform_int_distribution<uint32_t> size(1, seed == 1 ? 1 : 4096);
        while (rig.transport.samplePos() < 52000) rig.block(size(rng));
        const std::vector<FinalizedTake> takes = rec.finalize();
        DAW_CHECK(takes.size() == 1);
        if (takes.size() != 1) continue;
        DAW_CHECK(takes[0].startSample == 24000 && takes[0].frames == 24000);
        auto audio = load(takes[0].file);
        DAW_CHECK(audio && audio->asset->frames == 24000);
        if (!audio) continue;
        int bad = 0;
        for (int64_t k = 0; k < 24000; ++k) bad += audio->asset->data[0][k] != value(0, 24000 + k + 100);
        DAW_CHECK(bad == 0);
        DAW_CHECK(rig.violations == 0);
    }
    {
        // The loop on: the punch doesn't apply, the file runs on across the wraps.
        Rig rig;
        Recorder& rec = rig.recorder;
        rec.setArmed(3, 0, true);
        rec.setPunch({true, 960, 1920});
        (void)rec.prepare(kRate);
        (void)rig.transport.setLoop(true, 0, 480);  // 12000 samples
        (void)rig.transport.play();
        (void)rig.transport.setRecording(true);
        for (int i = 0; i < 60; ++i) rig.block(500);
        const std::vector<FinalizedTake> takes = rec.finalize();
        DAW_CHECK(takes.size() == 1 && takes[0].frames == rig.captured && takes[0].startSample == 0);
        DAW_CHECK(rig.violations == 0);
    }
    return checks;
}

// MARK: REC-002

CheckResult recorderDropsWhenWriterStalls() {
    CheckResult checks;
    Rig rig;
    Recorder& rec = rig.recorder;
    rec.setArmed(4, 0, true);
    (void)rec.prepare(kRate);
    rec.pauseWriter(true);
    (void)rig.transport.play();
    (void)rig.transport.setRecording(true);
    constexpr uint32_t kBlock = 512;
    constexpr uint32_t kFit = RecordFifo::kFrames / kBlock;
    for (uint32_t i = 0; i < kFit + 88; ++i) rig.block(kBlock);
    const uint64_t dropped = uint64_t{88} * kBlock;
    DAW_CHECK(rec.droppedFrames() == dropped);
    DAW_CHECK(rig.violations == 0);  // the audio thread never waited for the writer
    rec.pauseWriter(false);
    const auto deadline = std::chrono::steady_clock::now() + 10s;
    while (rec.queuedFrames() > 0 && std::chrono::steady_clock::now() < deadline) std::this_thread::sleep_for(5ms);
    DAW_CHECK(rec.queuedFrames() == 0);
    for (int i = 0; i < 100; ++i) rig.block(kBlock);
    DAW_CHECK(rec.droppedFrames() == dropped);
    const std::vector<FinalizedTake> takes = rec.finalize();
    DAW_CHECK(takes.size() == 1);
    if (takes.size() != 1) return checks;
    const FinalizedTake& take = takes[0];
    DAW_CHECK(!take.error && take.droppedFrames == dropped);
    DAW_CHECK(take.frames == rig.captured && take.startSample == 0);
    auto audio = load(take.file);
    DAW_CHECK(audio && audio->asset->frames == rig.captured);
    if (!audio) return checks;
    int bad = 0;
    const int64_t gapStart = RecordFifo::kFrames, gapEnd = gapStart + static_cast<int64_t>(dropped);
    for (int64_t k = 0; k < audio->asset->frames; ++k) {
        const float expected = k >= gapStart && k < gapEnd ? 0.0f : value(0, k);
        bad += audio->asset->data[0][k] != expected;
    }
    DAW_CHECK(bad == 0);
    DAW_CHECK(rig.violations == 0);
    return checks;
}

// MARK: Through the facade

namespace {

struct RecFacade {
    EngineFacade* facade = nullptr;
    FakeDeviceDriverAdapter* adapter = nullptr;
    std::vector<EngineEventPOD> events;

    explicit RecFacade(FakeDeviceSpec spec) {
        auto owned = std::make_unique<FakeDeviceDriverAdapter>(std::move(spec));
        adapter = owned.get();
        FacadeOptions options;
        options.driver = std::move(owned);
        DriverConfigPOD config;
        config.driver = DeviceDriverKind::fake;
        config.sampleRate = 0;
        config.bufferFrames = 256;
        facade = EngineFacadeAccess::create(EngineMode::realtime, config, std::move(options));
    }
    ~RecFacade() {
        if (facade) releaseFacade(facade);
    }
    uint64_t violations() const {
        FakeDeviceDriver* driver = adapter->driver();
        return (driver ? driver->rtViolations() : 0) + facade->telemetry().rtViolations;
    }
    void poll() {
        EngineEventPOD batch[16];
        for (size_t n; (n = facade->pollEvents(batch, 16)) > 0;)
            for (size_t i = 0; i < n; ++i) events.push_back(batch[i]);
    }
    std::vector<EngineEventPOD> takeAll(EngineEventType type) {
        poll();
        std::vector<EngineEventPOD> out;
        std::erase_if(events, [&](const EngineEventPOD& e) {
            if (e.type != type) return false;
            out.push_back(e);
            return true;
        });
        return out;
    }
};

// master ← metronome (on, level 0.5, accent 1): a click at every beat, straight into the master.
GraphDescription clickGraph(EngineFacade& facade) {
    const ParamID p = facade.allocateParams(Metronome::kNumParams);
    facade.setParam(p + Metronome::kOn, 1.0f);
    facade.setParam(p + Metronome::kLevel, 0.5f);
    facade.setParam(p + Metronome::kAccent, 1.0f);
    GraphDescriptionBuilder b;
    b.addNode(1, NodeKind::master, 1, 0, 0, "");
    b.addNode(10, NodeKind::metronome, 1, p, Metronome::kNumParams, "");
    b.addEdge(1, 10, 1, EdgeKind::audio, 0);
    b.setTempo(0, 120.0);
    b.setTimeSignature(0, 4, 4);
    b.setMaster(1);
    return b.description();
}

bool waitUntil(const std::function<bool()>& condition, std::chrono::milliseconds timeout = 5000ms) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (!condition()) {
        if (std::chrono::steady_clock::now() > deadline) return false;
        std::this_thread::sleep_for(1ms);
    }
    return true;
}

// Onsets: the first frame of each run of non-silence after at least `gap` silent frames.
std::vector<int64_t> onsets(const float* x, int64_t n, int64_t gap = 2000) {
    std::vector<int64_t> out;
    int64_t quiet = gap;
    for (int64_t i = 0; i < n; ++i) {
        if (std::abs(x[i]) > 1e-4f) {
            if (quiet >= gap) out.push_back(i);
            quiet = 0;
        } else {
            ++quiet;
        }
    }
    return out;
}

} // namespace

CheckResult facadeRecordsLoopbackAligned() {
    CheckResult checks;
    FakeDeviceSpec spec;
    FakeDevice device;
    device.id = 1;
    device.name = "Loopback";
    device.outputLatency = LatencyComponents{37, 11, 5, 0};  // + buffer 256 = 309
    device.inputLatency = LatencyComponents{23, 7, 0, 0};    // + buffer 256 = 286
    spec.devices = {device};
    spec.pacing = FakePacing::asFastAsPossible;
    spec.cycleLimit = 0;  // parked until the test lets it run
    constexpr int64_t kD = 309 + 286;

    TempDir dir;
    RecFacade f(spec);
    DAW_CHECK(f.facade != nullptr);
    if (!f.facade) return checks;
    EngineFacade& facade = *f.facade;
    const uint64_t version = facade.applyGraph(clickGraph(facade));
    DAW_CHECK(facade.waitForGraph(version, 5000).publishedVersion == version);
    facade.setRecordingDirectory((dir.path() / "Audio" / "Recordings").string());
    DAW_CHECK(facade.recordingDirectory() == (dir.path() / "Audio" / "Recordings").string());

    facade.armInput(5, 0, true);  // input on: the driver restarts with the loopback
    TelemetryPOD t = facade.telemetry();
    DAW_CHECK(t.deviceRunning && t.armedTracks == 1 && t.deviceInputLatency == 286);
    facade.setRecording(true);
    facade.play();
    FakeDeviceDriver* driver = f.adapter->driver();
    DAW_CHECK(driver != nullptr);
    if (!driver) return checks;
    driver->setCycleLimit(driver->cycles() + 220);  // 56320 frames: beats at 0 and 24000, 48000
    DAW_CHECK(driver->waitUntilIdle(10000ms));
    DAW_CHECK(facade.transport().recording && facade.transport().playing);
    facade.stop();

    const auto takes = f.takeAll(EngineEventType::recordingFinalized);
    DAW_CHECK(takes.size() == 1);
    if (takes.size() != 1) return checks;
    const RecordingPOD& r = takes[0].recording;
    DAW_CHECK(takes[0].error.ok() && takes[0].subject == 5 && r.track == 5);
    DAW_CHECK(r.startSample == -kD);  // REC-003: started at transport 0
    DAW_CHECK(r.frames == 220 * 256 && r.sampleRate == 48000.0 && r.droppedFrames == 0);
    DAW_CHECK(std::filesystem::path(r.file).parent_path() == dir.path() / "Audio" / "Recordings");
    auto audio = load(r.file);
    DAW_CHECK(audio.has_value());
    if (!audio) return checks;
    // Each click lands on its beat, ±1 sample, once the file is placed at startSample.
    const std::vector<int64_t> at = onsets(audio->asset->data[0], audio->asset->frames);
    DAW_CHECK(at.size() == 3);
    const int64_t beats[] = {0, 24000, 48000};
    for (size_t i = 0; i < at.size() && i < 3; ++i) DAW_CHECK(std::abs(r.startSample + at[i] - beats[i]) <= 1);
    t = facade.telemetry();
    DAW_CHECK(t.recordDrops == 0);
    DAW_CHECK(f.violations() == 0);
    return checks;
}

CheckResult facadeFinalizesTakes() {
    CheckResult checks;
    TempDir dir;
    RecFacade f(defaultFakeDeviceSpec());  // real-time pacing; A 48 kHz, B 44.1 kHz only
    DAW_CHECK(f.facade != nullptr);
    if (!f.facade) return checks;
    EngineFacade& facade = *f.facade;
    const uint64_t version = facade.applyGraph(clickGraph(facade));
    DAW_CHECK(facade.waitForGraph(version, 5000).publishedVersion == version);
    facade.setRecordingDirectory(dir.path().string());
    facade.armInput(5, 0, true);

    auto recordFor = [&](Tick ticks) {
        const Tick from = facade.transport().tick;
        facade.setRecording(true);
        facade.play();
        return waitUntil([&] { return facade.transport().tick > from + ticks; });
    };
    std::vector<std::string> files;
    auto expectOne = [&](NodeID track, double rate) {
        const auto takes = f.takeAll(EngineEventType::recordingFinalized);
        DAW_CHECK(takes.size() == 1);
        if (takes.size() != 1) return;
        DAW_CHECK(takes[0].recording.track == track && takes[0].recording.frames > 0);
        DAW_CHECK(takes[0].recording.sampleRate == rate);
        DAW_CHECK(std::filesystem::exists(takes[0].recording.file));
        for (const std::string& old : files) DAW_CHECK(old != takes[0].recording.file);
        files.push_back(takes[0].recording.file);
    };

    // IO-021 (2), DW-119: the device goes away mid-take.
    DAW_CHECK(recordFor(240));
    DeviceEventPOD lost;
    lost.kind = DeviceEventKind::deviceLost;
    DAW_CHECK(facade.simulateDeviceEvent(lost).ok());
    expectOne(5, 48000.0);
    DAW_CHECK(!facade.transport().playing);
    DAW_CHECK(facade.telemetry().sampleRate == 44100.0);  // fell back to B

    // stop() at the new rate; the take is recorded there.
    DAW_CHECK(recordFor(240));
    facade.stop();
    expectOne(5, 44100.0);

    // Arming another track mid-take ends it (REC-022); the next take records both.
    DAW_CHECK(recordFor(240));
    facade.armInput(6, 1, true);
    expectOne(5, 44100.0);
    DAW_CHECK(waitUntil([&] { return facade.transport().tick > 0; }));
    // setRecording(false) is a manual punch-out.
    DAW_CHECK(recordFor(240));
    facade.setRecording(false);
    {
        const auto takes = f.takeAll(EngineEventType::recordingFinalized);
        DAW_CHECK(takes.size() == 2);
    }
    facade.stop();
    DAW_CHECK(f.takeAll(EngineEventType::recordingFinalized).empty());
    DAW_CHECK(f.violations() == 0);

    // Offline engines have no input: arming and recording produce nothing.
    DriverConfigPOD config;
    config.sampleRate = 48000.0;
    EngineFacade* offline = EngineFacade::create(EngineMode::offline, config);
    DAW_CHECK(offline != nullptr);
    if (offline) {
        offline->armInput(5, 0, true);
        offline->setRecording(true);
        offline->play();
        offline->stop();
        EngineEventPOD batch[16];
        const size_t n = offline->pollEvents(batch, 16);
        for (size_t i = 0; i < n; ++i) DAW_CHECK(batch[i].type != EngineEventType::recordingFinalized);
        DAW_CHECK(offline->telemetry().armedTracks == 1);
        releaseFacade(offline);
    }
    return checks;
}

} // namespace daw::testing
