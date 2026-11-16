// T-080 checks for loop recording (REC-030, REC-034, DW-243). Run from
// Tests/DAWEngineTests/RecordingTests.swift; see LoopTakeChecks.h.

#include "LoopTakeChecks.h"

#include <mach/mach_time.h>

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
#include "daw/GraphDescription.h"
#include "facade/DriverAdapter.h"
#include "facade/FacadeOptions.h"
#include "io/AudioFileLoader.h"
#include "io/FakeDeviceDriver.h"
#include "nodes/Metronome.h"
#include "record/MidiInputRouter.h"
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

std::optional<LoadedAudio> load(const std::string& file) {
    AudioLoadRequest request;
    request.file = file;
    request.sessionRate = kRate;
    auto loaded = AudioFileLoader::load(request);
    if (!loaded) return std::nullopt;
    return std::move(loaded).value();
}

// A Transport whose blocks are laid out in passes exactly like Engine::render (DW-125), feeding a
// Recorder the device input like DeviceRenderer. `positions` keeps the transport position of every
// frame captured while playing and recording: the ground truth.
struct PassRig {
    TempDir dir;
    Recorder recorder;
    Transport transport;
    TempoMap tempo = makeTempo();
    std::vector<std::vector<float>> in = std::vector<std::vector<float>>(kInChannels, std::vector<float>(kMaxBlock));
    std::vector<int64_t> framePos = std::vector<int64_t>(kMaxBlock);
    float* ptrs[kInChannels]{};
    uint64_t violations = 0;
    uint64_t multiPassBlocks = 0;
    std::vector<int64_t> positions;

    PassRig() {
        for (uint32_t c = 0; c < kInChannels; ++c) ptrs[c] = in[c].data();
        recorder.setDirectory(dir.path() / "Recordings");
    }

    void block(uint32_t n) {
        bool recorded = false;
        uint32_t passes = 0;
        {
            RtScope scope;
            transport.beginBlock(tempo);
            uint32_t done = 0, lastOffset = 0;
            do {
                const TransportBlock& b = transport.layOutPass(tempo, n - done);
                const uint32_t frames = transport.passFrames();
                for (uint32_t c = 0; c < kInChannels; ++c) std::fill(in[c].begin() + done, in[c].begin() + done + frames, 0.0f);
                for (uint8_t s = 0; s < b.numSegments && s < 2; ++s)
                    for (uint32_t f = 0; f < b.seg[s].numFrames; ++f) {
                        const uint32_t at = done + b.seg[s].frameOffset + f;
                        for (uint32_t c = 0; c < kInChannels; ++c) in[c][at] = value(c, b.seg[s].startSample + f);
                        framePos[at] = b.seg[s].startSample + f;
                    }
                recorded = b.playing && b.recording && b.numSegments > 0;
                lastOffset = done;
                done += frames;
                ++passes;
            } while (done < n);
            if (lastOffset > 0) transport.offsetLastPass(lastOffset);
            AudioBufferView view{ptrs, kInChannels, n};
            recorder.captureBlock(transport, view, n);
            violations += scope.violations();
        }
        if (passes > 1) ++multiPassBlocks;
        if (recorded) positions.insert(positions.end(), framePos.begin(), framePos.begin() + n);
    }
};

// REC-030: what passStarts must be for frames captured at `positions` with latency D.
std::vector<int64_t> expectedPassStarts(const std::vector<int64_t>& positions, int64_t latency) {
    std::vector<int64_t> starts{0};
    const auto n = static_cast<int64_t>(positions.size());
    for (int64_t k = 1; k < n; ++k)
        if (positions[k] != positions[k - 1] + 1 && k + latency < n) starts.push_back(k + latency);
    if (starts.size() < 2) starts.clear();
    return starts;
}

struct LoopCase {
    const char* name;
    Tick loopStart, loopEnd;
    Tick playFrom;
    uint32_t minBlock, maxBlock;
    uint32_t latency;
    int64_t idleFrames;    // played before recording starts
    int64_t recordFrames;  // at least this much recorded
};

bool runLoopCase(CheckResult& checks, const LoopCase& c, uint32_t seed) {
    PassRig rig;
    Recorder& rec = rig.recorder;
    rec.setArmed(3, 1, true);
    rec.setLatency(c.latency);
    (void)rec.prepare(kRate);
    (void)rig.transport.setLoop(true, c.loopStart, c.loopEnd);
    (void)rig.transport.locate(c.playFrom);
    (void)rig.transport.play();
    std::mt19937 rng(seed);
    std::uniform_int_distribution<uint32_t> size(c.minBlock, c.maxBlock);
    int64_t played = 0;
    while (played < c.idleFrames) {
        const uint32_t n = size(rng);
        rig.block(n);
        played += n;
    }
    (void)rig.transport.setRecording(true);
    while (static_cast<int64_t>(rig.positions.size()) < c.recordFrames) rig.block(size(rng));
    const std::vector<FinalizedTake> takes = rec.finalize();
    DAW_CHECK(takes.size() == 1);
    if (takes.size() != 1) return false;
    const FinalizedTake& take = takes[0];
    const auto frames = static_cast<int64_t>(rig.positions.size());
    DAW_CHECK(!take.error && take.droppedFrames == 0);
    DAW_CHECK(take.frames == frames);  // DW-243: no pass of a block left out
    DAW_CHECK(take.startSample == rig.positions.front() - c.latency);
    const std::vector<int64_t> expected = expectedPassStarts(rig.positions, c.latency);
    if (take.passStarts != expected) {
        const std::string what = std::string(c.name) + ": " + std::to_string(take.passStarts.size()) +
                                 " pass starts, expected " + std::to_string(expected.size());
        checks.fail(what.c_str(), __FILE__, __LINE__);
    }
    if (!expected.empty()) {
        DAW_CHECK(take.loopStart == rig.tempo.tickToSample(c.loopStart));
        DAW_CHECK(take.loopEnd == rig.tempo.tickToSample(c.loopEnd));
    }
    // Every frame in order: file frame k is what the input held at positions[k].
    auto audio = load(take.file);
    DAW_CHECK(audio && audio->asset->frames == frames);
    if (audio) {
        int bad = 0;
        for (int64_t k = 0; k < audio->asset->frames && k < frames; ++k) {
            bad += audio->asset->data[0][k] != value(2, rig.positions[k]);
            bad += audio->asset->data[1][k] != value(3, rig.positions[k]);
        }
        DAW_CHECK(bad == 0);
    }
    DAW_CHECK(rig.violations == 0);
    return rig.multiPassBlocks > 0;
}

// MARK: Facade

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
    std::vector<EngineEventPOD> takeAll(EngineEventType type) {
        EngineEventPOD batch[16];
        for (size_t n; (n = facade->pollEvents(batch, 16)) > 0;)
            for (size_t i = 0; i < n; ++i) events.push_back(batch[i]);
        std::vector<EngineEventPOD> out;
        std::erase_if(events, [&](const EngineEventPOD& e) {
            if (e.type != type) return false;
            out.push_back(e);
            return true;
        });
        return out;
    }
};

// master ← metronome (on, level 0.5, accent 1): a click at every beat.
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

FakeDeviceSpec loopbackSpec() {
    FakeDeviceSpec spec;
    FakeDevice device;
    device.id = 1;
    device.name = "Loopback";
    device.outputLatency = LatencyComponents{37, 11, 5, 0};  // + buffer 256 = 309
    device.inputLatency = LatencyComponents{23, 7, 0, 0};    // + buffer 256 = 286
    spec.devices = {device};
    spec.pacing = FakePacing::asFastAsPossible;
    spec.cycleLimit = 0;  // parked until the test lets it run
    return spec;
}
constexpr int64_t kLoopbackD = 309 + 286;

// Records `cycles` device cycles of 256 frames with the loop [start, end) from tick 0; the take.
std::optional<RecordingPOD> recordLoop(CheckResult& checks, RecFacade& f, const TempDir& dir, Tick start, Tick end,
                                       uint64_t cycles) {
    DAW_CHECK(f.facade != nullptr);
    if (!f.facade) return std::nullopt;
    EngineFacade& facade = *f.facade;
    const uint64_t version = facade.applyGraph(clickGraph(facade));
    DAW_CHECK(facade.waitForGraph(version, 5000).publishedVersion == version);
    facade.setRecordingDirectory((dir.path() / "Recordings").string());
    facade.armInput(5, 0, true);
    facade.setLoop(true, start, end);
    facade.setRecording(true);
    facade.play();
    FakeDeviceDriver* driver = f.adapter->driver();
    DAW_CHECK(driver != nullptr);
    if (!driver) return std::nullopt;
    driver->setCycleLimit(driver->cycles() + cycles);
    DAW_CHECK(driver->waitUntilIdle(10000ms));
    facade.stop();
    const auto takes = f.takeAll(EngineEventType::recordingFinalized);
    DAW_CHECK(takes.size() == 1);
    if (takes.size() != 1) return std::nullopt;
    DAW_CHECK(takes[0].error.ok());
    DAW_CHECK(takes[0].recording.frames == int64_t(cycles) * 256);
    return takes[0].recording;
}

void injectAt(MidiInputRouter& router, int64_t framesFromNow, uint8_t status, uint8_t d1, uint8_t d2) {
    const uint8_t bytes[3] = {status, d1, d2};
    (void)router.inject(framesFromNow, true, bytes, 3);
}

uint64_t hostTicks(double seconds) {
    mach_timebase_info_data_t timebase{};
    mach_timebase_info(&timebase);
    return static_cast<uint64_t>(seconds * 1e9 * double(timebase.denom) / double(timebase.numer));
}

} // namespace

// MARK: REC-030, DW-243

CheckResult recorderLogsLoopPasses() {
    CheckResult checks;
    // 120 bpm at 48 kHz: 25 samples a tick.
    const LoopCase cases[] = {
        // Three passes of a long loop, the last partial.
        {"long loop", 0, 480, 0, 1, 4096, 100, 0, 30000},
        {"long loop, mid-loop record", 960, 1440, 0, 64, 2048, 0, 30000, 40000},
        // A 100-sample loop: several passes per block, entered from before it.
        {"short loop", 960, 964, 0, 1, 4096, 100, 0, 40000},
        {"short loop, recording mid-way", 960, 964, 0, 300, 4096, 37, 30000, 20000},
        // Blocks of 300 from the loop start: every block ends right on the loop end.
        {"short loop, blocks end on the loop end", 960, 964, 960, 300, 300, 10, 0, 6000},
        {"one-tick loop", 100, 101, 90, 1, 4096, 300, 0, 10000},
        {"loop of 12 ticks", 4, 16, 0, 1, 4096, 5, 0, 20000},
    };
    bool sawMultiPass = false;
    for (const LoopCase& c : cases)
        for (uint32_t seed : {1u, 2u, 3u}) sawMultiPass = runLoopCase(checks, c, seed) || sawMultiPass;
    DAW_CHECK(sawMultiPass);  // the short loops really were laid out in several passes per block
    {
        // No loop: no passes.
        PassRig rig;
        rig.recorder.setArmed(3, 0, true);
        (void)rig.recorder.prepare(kRate);
        (void)rig.transport.play();
        (void)rig.transport.setRecording(true);
        for (int i = 0; i < 20; ++i) rig.block(512);
        const auto takes = rig.recorder.finalize();
        DAW_CHECK(takes.size() == 1 && takes[0].passStarts.empty() && takes[0].loopStart == 0 && takes[0].loopEnd == 0);
    }
    return checks;
}

CheckResult facadeReportsLoopPasses() {
    CheckResult checks;
    {
        // Three passes of a one-second loop (two beats), the last partial: 520 cycles = 133120 frames.
        TempDir dir;
        RecFacade f(loopbackSpec());
        const auto r = recordLoop(checks, f, dir, 0, 1920, 520);
        DAW_CHECK(r.has_value());
        if (r) {
            DAW_CHECK(r->startSample == -kLoopbackD);
            DAW_CHECK(r->passes == 3);
            DAW_CHECK(r->loopStart == 0 && r->loopEnd == 48000);
            const std::vector<int64_t> expected{0, 48000 + kLoopbackD, 96000 + kLoopbackD};
            DAW_CHECK(r->passStarts == expected);
            auto audio = load(r->file);
            DAW_CHECK(audio.has_value());
            if (audio) {
                // Each pass's loop start (beat 0) and its second beat, at the pass start in the file.
                const std::vector<int64_t> at = onsets(audio->asset->data[0], audio->asset->frames);
                const int64_t beats[] = {kLoopbackD, kLoopbackD + 24000, expected[1], expected[1] + 24000,
                                         expected[2], expected[2] + 24000};
                DAW_CHECK(at.size() == 6);
                for (size_t i = 0; i < at.size() && i < 6; ++i) DAW_CHECK(std::abs(at[i] - beats[i]) <= 1);
            }
        }
        DAW_CHECK(f.violations() == 0);
    }
    {
        // DW-243: a 100-sample loop with 256-frame device buffers: a pass every 100 frames.
        TempDir dir;
        RecFacade f(loopbackSpec());
        const auto r = recordLoop(checks, f, dir, 0, 4, 40);
        DAW_CHECK(r.has_value());
        if (r) {
            std::vector<int64_t> expected{0};
            for (int64_t w = 100; w + kLoopbackD < 40 * 256; w += 100) expected.push_back(w + kLoopbackD);
            DAW_CHECK(r->passStarts == expected);
            DAW_CHECK(r->passes == expected.size());
            DAW_CHECK(r->loopStart == 0 && r->loopEnd == 100);
        }
        DAW_CHECK(f.violations() == 0);
    }
    return checks;
}

// MARK: REC-034

CheckResult midiTakeReportsPasses() {
    CheckResult checks;
    constexpr uint8_t kOn = 0x90, kOff = 0x80;
    {
        MidiInputRouter router;
        Transport transport;
        const TempoMap tempo = makeTempo();
        router.setArmed(5, 0, true);
        (void)transport.setLoop(true, 0, 1920);  // 48000 samples
        (void)transport.setRecording(true);
        (void)transport.play();
        (void)router.prepare(kRate);
        uint64_t violations = 0;
        uint64_t rendered = 0;
        auto block = [&] {
            RtScope scope;
            (void)transport.advance(tempo, 512);
            router.beginBlock(transport, 512, kRate, hostTicks(double(rendered) / kRate + 1.0));
            router.endBlock();
            violations += scope.violations();
            rendered += 512;
        };
        // A note in each of three passes (pass 0 at block 10, 1 at block 110, 2 at block 200).
        for (int i = 0; i < 230; ++i) {
            if (i == 10 || i == 110 || i == 200) injectAt(router, 0, kOn, uint8_t(60 + i / 100), 100);
            if (i == 20 || i == 120 || i == 210) injectAt(router, 0, kOff, uint8_t(60 + i / 100), 0);
            block();
        }
        const auto takes = router.finalize();
        DAW_CHECK(takes.size() == 1);
        if (takes.size() == 1) {
            const FinalizedMidiTake& take = takes[0];
            DAW_CHECK(take.passes == 3 && take.loopStart == 0 && take.loopEnd == 48000);
            DAW_CHECK(take.notes.size() == 3);
            for (const RecordedMidiNote& note : take.notes) {
                DAW_CHECK(note.pass == note.pitch - 60);
                DAW_CHECK(note.start >= 0 && note.end <= 48000);  // in transport position (merged)
            }
        }
        DAW_CHECK(violations == 0);
    }
    {
        // The option: stamped on MIDI takes, read back; not on by default.
        DriverConfigPOD config;
        config.driver = DeviceDriverKind::fake;
        config.sampleRate = kRate;
        config.bufferFrames = 256;
        EngineFacade* facade = EngineFacade::create(EngineMode::realtime, config);
        DAW_CHECK(facade != nullptr);
        if (!facade) return checks;
        DAW_CHECK(!facade->transport().midiLoopTakes);
        facade->setRecordOptions(true);
        DAW_CHECK(facade->transport().midiLoopTakes);
        GraphDescriptionBuilder b;
        b.addNode(1, NodeKind::master, 1, 0, 0, "");
        b.setTempo(0, 120.0);
        b.setTimeSignature(0, 4, 4);
        b.setMaster(1);
        const uint64_t version = facade->applyGraph(b.description());
        DAW_CHECK(facade->waitForGraph(version, 5000).publishedVersion == version);
        facade->armMidiInput(5, 0, true);
        facade->setLoop(true, 0, 480);  // 12000 samples, a quarter second
        facade->setRecording(true);
        facade->play();
        const auto deadline = std::chrono::steady_clock::now() + 5s;
        while (!facade->transport().playing && std::chrono::steady_clock::now() < deadline) std::this_thread::sleep_for(1ms);
        DAW_CHECK(facade->injectMidi(0, true, kOn, 64, 90, 3).ok());
        std::this_thread::sleep_for(900ms);
        facade->stop();
        std::vector<EngineEventPOD> events;
        EngineEventPOD batch[8];
        for (size_t n; (n = facade->pollEvents(batch, 8)) > 0;)
            for (size_t i = 0; i < n; ++i)
                if (batch[i].type == EngineEventType::recordingFinalized) events.push_back(batch[i]);
        DAW_CHECK(events.size() == 1);
        if (events.size() == 1) {
            const RecordingPOD& r = events[0].recording;
            DAW_CHECK(r.midi && r.midiLoopTakes);
            DAW_CHECK(r.passes >= 2 && r.loopStart == 0 && r.loopEnd == 12000);
            DAW_CHECK(r.notes.size() == 1 && r.notes.size() == 1 && r.notes[0].pass < int32_t(r.passes));
            DAW_CHECK(r.passStarts.empty());  // audio only
        }
        facade->setRecordOptions(false);
        DAW_CHECK(!facade->transport().midiLoopTakes);
        DAW_CHECK(facade->telemetry().rtViolations == 0);
        releaseFacade(facade);
    }
    return checks;
}

} // namespace daw::testing
