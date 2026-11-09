// T-053 checks for MIDI input and recording (REC-010..012). Run from
// Tests/DAWEngineTests/MidiInputTests.swift; see MidiInputChecks.h.

#include "MidiInputChecks.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMIDI/CoreMIDI.h>
#include <mach/mach_time.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <numbers>
#include <thread>
#include <utility>
#include <vector>

#include "ExportTestSupport.h"
#include "TestAudio.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/ProcessContext.h"
#include "core/RtTrap.h"
#include "daw/EngineFacade.h"
#include "daw/GraphDescription.h"
#include "graph/GraphBuilder.h"
#include "io/CoreMidiInput.h"
#include "nodes/MidiClipPlayer.h"
#include "record/MidiInputRouter.h"
#include "time/TempoMap.h"
#include "time/Transport.h"

using namespace daw;
using namespace std::chrono_literals;

namespace daw::testing {

namespace {

constexpr double kRate = 48000.0;
constexpr uint32_t kBlock = 512;
constexpr NodeID kPlayer = 2;
constexpr NodeID kTrack = 5;
constexpr uint8_t kOn = 0x90, kOff = 0x80, kCC = 0xB0;

TempoMap makeTempo() { return std::move(TempoMap::make({{0, 120.0}}, {{0, 4, 4}}, kRate)).value(); }

template <class Condition>
bool eventually(Condition condition, std::chrono::milliseconds timeout = 15000ms) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (!condition()) {
        if (std::chrono::steady_clock::now() > deadline) return false;
        std::this_thread::sleep_for(2ms);
    }
    return true;
}

uint64_t hostTicks(double seconds) {
    mach_timebase_info_data_t timebase{};
    mach_timebase_info(&timebase);
    return static_cast<uint64_t>(seconds * 1e9 * double(timebase.denom) / double(timebase.numer));
}

struct Ev {
    uint32_t frame;
    uint8_t status, d1, d2;
    bool operator==(const Ev&) const = default;
};

// Runs a router (and optionally one armed player) the way Engine::render does, each block in its
// own RtScope.
class Rig {
public:
    explicit Rig(uint32_t latency = 0, std::vector<NoteDesc> notes = {}) : notes_(std::move(notes)), tempo_(makeTempo()) {
        transport_.setOutputLatency(latency);
        recreatePlayer();
    }

    void recreatePlayer() {
        player_ = MidiClipPlayer::create(notes_, nullptr, kPlayer, &router);
        player_->prepare(PrepareInfo{kRate, kMaxBlock, 0, 0});
    }

    Transport& transport() { return transport_; }

    void playAndRecord() {
        transport_.setRecording(true);
        transport_.play();
        (void)router.prepare(kRate);
    }

    // One block; `host` is the cycle's start (0: synthetic time derived from the render position,
    // so anchors keep moving like a real device's).
    std::vector<Ev> block(uint32_t n = kBlock, uint64_t host = 0) {
        if (host == 0) host = hostTicks(double(rendered_) / kRate + 1.0);
        rendered_ += n;
        NodeIO io;
        std::vector<MidiEvent> storage(GraphBuilder::kMidiCapacity);
        io.midiOut = MidiEventWriter(storage.data(), static_cast<uint32_t>(storage.size()));
        {
            RtScope scope;
            const TransportBlock& b = transport_.advance(tempo_, n);
            router.beginBlock(transport_, n, kRate, host);
            ProcessContext ctx{n, kRate, b, params_};
            player_->process(ctx, io);
            router.endBlock();
            violations += scope.violations();
        }
        std::vector<Ev> out;
        for (const MidiEvent& e : io.midiOut.written()) {
            if (e.size == 3 && e.data[1] == 123 && (e.data[0] & 0xF0) == kCC) continue;  // a new player's announcement
            out.push_back({e.frameOffset, e.data[0], e.data[1], e.size > 2 ? e.data[2] : uint8_t(0)});
        }
        return out;
    }

    // Blocks until the transport's next block starts at `sample`.
    void runTo(int64_t sample) {
        for (int i = 0; i < 100000 && transportPosition() < sample; ++i) block();
    }
    int64_t transportPosition() {
        return transport_.block().numSegments > 0
                   ? transport_.block().seg[0].startSample + transport_.block().seg[0].numFrames
                   : 0;
    }

    MidiInputRouter router;
    uint64_t violations = 0;

private:
    std::vector<NoteDesc> notes_;
    Transport transport_;
    TempoMap tempo_;
    ParamSlotTable params_;
    std::unique_ptr<MidiClipPlayer> player_;
    uint64_t rendered_ = 0;
};

void inject(MidiInputRouter& router, int64_t atSample, uint8_t status, uint8_t d1, uint8_t d2) {
    const uint8_t bytes[3] = {status, d1, d2};
    (void)router.inject(atSample, false, bytes, 3);
}

const RecordedMidiNote* noteWithPitch(const std::vector<RecordedMidiNote>& notes, uint8_t pitch) {
    for (const RecordedMidiNote& n : notes)
        if (n.pitch == pitch) return &n;
    return nullptr;
}

} // namespace

// MARK: REC-010

CheckResult midiHostTimeConversion() {
    CheckResult checks;
    Rig rig;
    rig.router.setArmed(kTrack, kPlayer, true);
    rig.playAndRecord();

    // Blocks at a synthetic device clock: block i starts at 2 s + i blocks.
    const auto hostAt = [](double seconds) { return hostTicks(2.0 + seconds); };
    for (int i = 0; i < 10; ++i) (void)rig.block(kBlock, hostAt(double(i * kBlock) / kRate));

    // The anchor is block 9: its host time ↔ render sample 9 × 512.
    const int64_t anchorSample = 9 * kBlock;
    const double anchorSec = double(9 * kBlock) / kRate;
    for (const double delta : {0.0, 0.0105, -0.01, 0.5, -0.025}) {
        const int64_t got = rig.router.sampleTimeOfHost(hostAt(anchorSec + delta));
        DAW_CHECK(std::abs(got - (anchorSample + std::llround(delta * kRate))) <= 1);
    }
    // Before the first block there is no anchor: render clock 0.
    MidiInputRouter fresh;
    DAW_CHECK(fresh.sampleTimeOfHost(12345) == 0);

    // A received event struck inside block 5 (100 frames in) is recorded where it was struck,
    // although the audio thread sees it blocks later (REC-012).
    const int slot = rig.router.openInput();
    DAW_CHECK(slot >= 0);
    const uint8_t on[3] = {kOn, 60, 100};
    const uint8_t off[3] = {kOff, 60, 0};
    DAW_CHECK(rig.router.receive(slot, hostAt(double(5 * kBlock + 100) / kRate), on, 3));
    (void)rig.block(kBlock, hostAt(double(10 * kBlock) / kRate));
    DAW_CHECK(rig.router.receive(slot, hostAt(double(10 * kBlock + 40) / kRate), off, 3));
    (void)rig.block(kBlock, hostAt(double(11 * kBlock) / kRate));
    const auto takes = rig.router.finalize();
    DAW_CHECK(takes.size() == 1);
    if (takes.size() == 1) {
        const RecordedMidiNote* note = noteWithPitch(takes[0].notes, 60);
        DAW_CHECK(note != nullptr);
        if (note) {
            DAW_CHECK(note->start == 5 * kBlock + 100);
            DAW_CHECK(note->end == 10 * kBlock + 40);
        }
    }
    DAW_CHECK(rig.violations == 0);
    return checks;
}

// MARK: REC-011/012 placement

CheckResult midiBlockBoundaryPlacement() {
    CheckResult checks;
    constexpr uint32_t kLatency = 300;
    Rig rig(kLatency);
    rig.router.setArmed(kTrack, kPlayer, true);
    rig.playAndRecord();
    (void)rig.block();  // transport at 512

    // Scheduled a block or more ahead: exact placement.
    const int64_t boundary = 8 * kBlock;  // the first frame of block 8
    inject(rig.router, boundary - 1, kOn, 60, 90);   // last frame of block 7
    inject(rig.router, boundary, kOn, 62, 91);       // first frame of block 8
    inject(rig.router, boundary + 5, kOff, 60, 0);
    inject(rig.router, 9 * kBlock, kOff, 62, 0);     // first frame of block 9

    rig.runTo(7 * kBlock);
    DAW_CHECK(rig.block() == (std::vector<Ev>{{kBlock - 1, kOn, 60, 90}}));  // block 7
    DAW_CHECK(rig.block() == (std::vector<Ev>{{0, kOn, 62, 91}, {5, kOff, 60, 64}}));  // block 8
    DAW_CHECK(rig.block() == (std::vector<Ev>{{0, kOff, 62, 64}}));  // block 9
    (void)rig.block();

    const auto takes = rig.router.finalize();
    DAW_CHECK(takes.size() == 1);
    if (takes.size() != 1) return checks;
    const FinalizedMidiTake& take = takes[0];
    DAW_CHECK(take.track == kTrack && take.sampleRate == kRate);
    DAW_CHECK(take.startSample == -int64_t{kLatency});  // the compensated record start
    DAW_CHECK(take.endSample == 11 * kBlock - int64_t{kLatency});
    DAW_CHECK(take.notes.size() == 2);
    const RecordedMidiNote* a = noteWithPitch(take.notes, 60);
    const RecordedMidiNote* b = noteWithPitch(take.notes, 62);
    DAW_CHECK(a != nullptr && b != nullptr);
    if (a && b) {
        DAW_CHECK(a->start == boundary - 1 - kLatency && a->end == boundary + 5 - kLatency && a->velocity == 90);
        DAW_CHECK(b->start == boundary - kLatency && b->end == 9 * kBlock - kLatency && b->velocity == 91);
    }
    // Past-due events play at frame 0 of the next block, in order.
    inject(rig.router, 100, kOn, 70, 80);
    DAW_CHECK(rig.block() == (std::vector<Ev>{{0, kOn, 70, 80}}));
    DAW_CHECK(rig.violations == 0);
    return checks;
}

CheckResult midiPairsNotesOnStop() {
    CheckResult checks;
    {
        // Paired, unpaired, a stray off, and a repeated on from the same input.
        Rig rig(50);
        rig.router.setArmed(kTrack, kPlayer, true);
        rig.playAndRecord();
        (void)rig.block();
        inject(rig.router, 2000, kOn, 60, 100);
        inject(rig.router, 2100, kOn, 60, 40);    // same key again: not a new note
        inject(rig.router, 3000, kOff, 60, 0);
        inject(rig.router, 3500, kOff, 90, 0);    // an off with no on: ignored
        inject(rig.router, 4000, kOn, 64, 110);   // never released
        rig.runTo(6000);
        const auto takes = rig.router.finalize();
        DAW_CHECK(takes.size() == 1 && takes[0].notes.size() == 2);
        if (takes.size() == 1 && takes[0].notes.size() == 2) {
            const RecordedMidiNote* note = noteWithPitch(takes[0].notes, 60);
            DAW_CHECK(note && note->start == 2000 - 50 && note->end == 3000 - 50 && note->velocity == 100);
            const RecordedMidiNote* open = noteWithPitch(takes[0].notes, 64);
            DAW_CHECK(open && open->start == 4000 - 50 && open->end == takes[0].endSample);
        }
        DAW_CHECK(!rig.router.capturing());
    }
    {
        // Nothing played: no take, no clip, no undo entry. A note played before the take isn't
        // part of it.
        Rig rig;
        rig.router.setArmed(kTrack, kPlayer, true);
        (void)rig.block();
        inject(rig.router, 0, kOn, 60, 100);
        (void)rig.block();  // heard while stopped (played through, not recorded)
        rig.playAndRecord();
        rig.runTo(4096);
        DAW_CHECK(rig.router.finalize().empty());
    }
    {
        // Disabled transport record: played through, nothing recorded.
        Rig rig;
        rig.router.setArmed(kTrack, kPlayer, true);
        rig.transport().play();
        (void)rig.router.prepare(kRate);
        (void)rig.block();
        inject(rig.router, 2048, kOn, 60, 100);
        rig.runTo(4096);
        DAW_CHECK(rig.router.finalize().empty());
    }
    {
        // A note held across the wrap, offs in pass 1.
        Rig rig;
        rig.router.setArmed(kTrack, kPlayer, true);
        rig.transport().setLoop(true, 0, 1920);  // 48000 samples
        rig.playAndRecord();
        // Wrap happens at block 93.75… (48000 / 512); drive it with frames-from-now injections.
        for (int i = 0; i < 93; ++i) (void)rig.block();
        const uint8_t on[3] = {kOn, 72, 100};
        const uint8_t off[3] = {kOff, 72, 0};
        (void)rig.router.inject(100, true, on, 3);   // near the end of pass 0
        (void)rig.block();  // block 93 wraps
        (void)rig.block();  // now well into pass 1
        (void)rig.router.inject(100, true, off, 3);
        (void)rig.block();
        (void)rig.block();
        const auto takes = rig.router.finalize();
        DAW_CHECK(takes.size() == 1 && takes[0].notes.size() == 1);
        if (takes.size() == 1 && takes[0].notes.size() == 1) {
            DAW_CHECK(takes[0].notes[0].start > 47000 && takes[0].notes[0].start < 48000);
            DAW_CHECK(takes[0].notes[0].end == 48000);  // the end of the pass, not before its start
        }
    }
    return checks;
}

CheckResult midiMergesInputs() {
    CheckResult checks;
    Rig rig;
    rig.router.setArmed(kTrack, kPlayer, true);
    const int a = rig.router.openInput();
    const int b = rig.router.openInput();
    DAW_CHECK(a >= 0 && b >= 0 && a != b);

    // In time order across inputs, and one key held twice sounds once.
    const uint8_t on60[3] = {kOn, 60, 100}, off60[3] = {kOff, 60, 0};
    const uint8_t on64[3] = {kOn, 64, 100}, cc123[3] = {kCC, 123, 0};
    (void)rig.block();
    DAW_CHECK(rig.router.receive(a, 0, on60, 3));
    DAW_CHECK(rig.router.receive(b, 0, on60, 3));
    DAW_CHECK(rig.router.receive(b, 0, on64, 3));
    DAW_CHECK(rig.block() == (std::vector<Ev>{{0, kOn, 60, 100}, {0, kOn, 64, 100}}));

    // First release doesn't end it; the panic from input b ends only b's notes.
    DAW_CHECK(rig.router.receive(a, 0, off60, 3));
    DAW_CHECK(rig.block().empty());
    DAW_CHECK(rig.router.receive(b, 0, cc123, 3));
    DAW_CHECK(rig.block() == (std::vector<Ev>{{0, kOff, 60, 64}, {0, kOff, 64, 64}}));
    DAW_CHECK(rig.violations == 0);
    return checks;
}

// MARK: hanging notes

CheckResult midiNeverHangs() {
    CheckResult checks;
    {
        // Disarm with a note and the pedal down: they end at frame 0, once.
        Rig rig;
        rig.router.setArmed(kTrack, kPlayer, true);
        (void)rig.block();
        inject(rig.router, 0, kOn, 60, 100);
        inject(rig.router, 0, kCC, 64, 127);
        inject(rig.router, 0, 0xE1, 0, 90);  // a bend on channel 2
        (void)rig.block();  // heard, armed
        rig.router.setArmed(kTrack, kPlayer, false);
        const auto released = rig.block();
        DAW_CHECK(released.size() == 3);
        DAW_CHECK(std::count(released.begin(), released.end(), Ev{0, kOff, 60, 64}) == 1);
        DAW_CHECK(std::count(released.begin(), released.end(), Ev{0, kCC, 64, 0}) == 1);
        DAW_CHECK(std::count(released.begin(), released.end(), Ev{0, 0xE1, 0, 64}) == 1);
        DAW_CHECK(rig.block().empty());
        // Disarmed: the input no longer reaches the player.
        inject(rig.router, 0, kOn, 62, 100);
        DAW_CHECK(rig.block().empty());
        DAW_CHECK(rig.violations == 0);
    }
    {
        // An input that disappears with notes down gets their offs, and its pedal up.
        Rig rig;
        rig.router.setArmed(kTrack, kPlayer, true);
        const int input = rig.router.openInput();
        DAW_CHECK(input >= 0);
        const uint8_t on[3] = {kOn, 67, 100}, pedal[3] = {kCC, 64, 127};
        (void)rig.block();
        DAW_CHECK(rig.router.receive(input, 0, on, 3) && rig.router.receive(input, 0, pedal, 3));
        (void)rig.block();
        rig.router.closeInput(input);
        const auto after = rig.block();
        DAW_CHECK(std::count(after.begin(), after.end(), Ev{0, kOff, 67, 64}) == 1);
        DAW_CHECK(std::count(after.begin(), after.end(), Ev{0, kCC, 64, 0}) == 1);
        // A slot that was seen closing is reusable.
        DAW_CHECK(rig.router.openInput() == input);
        DAW_CHECK(rig.violations == 0);
    }
    {
        // A note edit re-creates the player while a key is held: All Notes Off, then the held
        // note sounds again on the new instance, and its off still ends it.
        Rig rig;
        rig.router.setArmed(kTrack, kPlayer, true);
        (void)rig.block();
        inject(rig.router, 0, kOn, 60, 100);
        DAW_CHECK(rig.block() == (std::vector<Ev>{{0, kOn, 60, 100}}));
        rig.recreatePlayer();
        DAW_CHECK(rig.block() == (std::vector<Ev>{{0, kOn, 60, 100}}));
        inject(rig.router, 0, kOff, 60, 0);
        DAW_CHECK(rig.block() == (std::vector<Ev>{{0, kOff, 60, 64}}));
        DAW_CHECK(rig.violations == 0);
    }
    {
        // Export: live input is off, so held notes end and nothing new is played.
        Rig rig;
        rig.router.setArmed(kTrack, kPlayer, true);
        (void)rig.block();
        inject(rig.router, 0, kOn, 60, 100);
        (void)rig.block();
        rig.router.setLiveEnabled(false);
        const auto released = rig.block();
        DAW_CHECK(std::count(released.begin(), released.end(), Ev{0, kOff, 60, 64}) == 1);
        rig.router.setLiveEnabled(true);
    }
    return checks;
}

// MARK: REC-011 into the player

CheckResult midiMergesIntoPlayerOutput() {
    CheckResult checks;
    {
        // Only an armed player gets input.
        Rig rig;
        (void)rig.block();
        inject(rig.router, 0, kOn, 60, 100);
        DAW_CHECK(rig.block().empty());
        rig.router.setArmed(kTrack, kPlayer, true);
        inject(rig.router, 0, kOn, 61, 100);
        DAW_CHECK(rig.block() == (std::vector<Ev>{{0, kOn, 61, 100}}));
    }
    {
        // Live and clip notes come out in frame order (T-045's MIDI path, the player's midiOut).
        // Clip note at tick 480 → sample 12000; the live note a little after it in the same block.
        std::vector<NoteDesc> notes{NoteDesc{kPlayer, 480, 1920, 40, 100, 0}};
        Rig rig(0, notes);
        rig.router.setArmed(kTrack, kPlayer, true);
        rig.transport().play();
        (void)rig.router.prepare(kRate);
        (void)rig.block();
        // Block starting at 11776 contains 12000 (frame 224); the live note lands at frame 300,
        // and a pitch bend at frame 100, before the clip note.
        rig.runTo(11776);
        inject(rig.router, 11876, 0xE0, 0, 70);  // frame 100
        inject(rig.router, 12076, kOn, 77, 90);  // frame 300
        const auto out = rig.block();
        DAW_CHECK(out == (std::vector<Ev>{{100, 0xE0, 0, 70}, {224, kOn, 40, 100}, {300, kOn, 77, 90}}));
    }
    {
        // Pre-roll chunks process the node without a real block: live events wait for the real one.
        Rig rig;
        rig.router.setArmed(kTrack, kPlayer, true);
        (void)rig.block();
        inject(rig.router, 0, kOn, 60, 100);
        DAW_CHECK(!rig.router.blockActive());  // between blocks: no live span
        DAW_CHECK(rig.router.events().empty());
        DAW_CHECK(rig.block() == (std::vector<Ev>{{0, kOn, 60, 100}}));
    }
    return checks;
}

// MARK: Overflow

CheckResult midiOverflowIsCounted() {
    CheckResult checks;
    {
        // A queue no one drains: the first kQueueSize events fit, the rest are counted, and the
        // audio thread ends what the input had down, so the lost off can't hang a note.
        Rig rig;
        rig.router.setArmed(kTrack, kPlayer, true);
        const int input = rig.router.openInput();
        DAW_CHECK(input >= 0);
        const uint8_t on[3] = {kOn, 60, 100};
        (void)rig.block();
        DAW_CHECK(rig.router.receive(input, 0, on, 3));
        DAW_CHECK(rig.block() == (std::vector<Ev>{{0, kOn, 60, 100}}));  // the note is on
        for (std::size_t i = 0; i < MidiInputRouter::kQueueSize + 10; ++i)
            (void)rig.router.receive(input, 0, on, 3);
        DAW_CHECK(rig.router.droppedEvents() == 10);
        std::vector<Ev> all;
        for (int i = 0; i < 40; ++i) {  // a few blocks: 256 events per block, then the recovery
            const auto out = rig.block();
            all.insert(all.end(), out.begin(), out.end());
        }
        DAW_CHECK(std::count(all.begin(), all.end(), Ev{0, kOff, 60, 64}) == 1);
        DAW_CHECK(rig.violations == 0);
    }
    {
        // A full record buffer drops notes, counts them, and leaves the playback alone.
        Rig rig;
        rig.router.setArmed(kTrack, kPlayer, true);
        rig.playAndRecord();
        (void)rig.block();
        const int input = rig.router.openInput();
        const uint8_t on[3] = {kOn, 50, 100}, off[3] = {kOff, 50, 0};
        // 2 × 128 events per block, 200k+ events past the capacity.
        for (uint32_t block = 0; block < (MidiInputRouter::kMaxRecordEvents + 2048) / 256 + 2; ++block) {
            for (int i = 0; i < 128; ++i) {
                DAW_CHECK(rig.router.receive(input, 0, on, 3) && rig.router.receive(input, 0, off, 3));
            }
            (void)rig.block();
        }
        const auto takes = rig.router.finalize();
        DAW_CHECK(takes.size() == 1);
        if (takes.size() == 1) DAW_CHECK(takes[0].droppedEvents > 0 && !takes[0].notes.empty());
        DAW_CHECK(rig.router.droppedEvents() > 0);
        DAW_CHECK(rig.violations == 0);
    }
    return checks;
}

// MARK: End to end

CheckResult midiThroughFacade() {
    CheckResult checks;
    TempDir dir;
    std::vector<float> sine(2 * 48000);
    for (size_t i = 0; i < sine.size(); ++i)
        sine[i] = 0.5f * static_cast<float>(std::sin(2.0 * std::numbers::pi * 440.0 * static_cast<double>(i) / kRate));
    const auto file = dir.path() / "sine440.wav";
    DAW_CHECK(writeTestFile(file, "wav-f32", kRate, Channels{sine}).ok());

    DriverConfigPOD config;
    config.driver = DeviceDriverKind::fake;
    config.sampleRate = kRate;
    config.bufferFrames = 256;
    EngineFacade* facade = EngineFacade::create(EngineMode::realtime, config);
    DAW_CHECK(facade != nullptr);
    if (!facade) return checks;
    struct Release {
        EngineFacade* f;
        ~Release() { releaseFacade(f); }
    } release{facade};

    const JobID load = facade->loadAsset(7, file.string());
    DAW_CHECK(eventually([&] {
        const JobState s = facade->pollJob(load).state;
        return s == JobState::succeeded || s == JobState::failed;
    }));
    const ParamID strip = facade->allocateParams(4);
    facade->setParam(strip + 0, 1.0f);
    facade->setParam(strip + 1, 0.0f);
    GraphDescriptionBuilder b;
    b.addNode(1, NodeKind::master, 1, 0, 0, "");
    b.addNode(2, NodeKind::midiClipPlayer, 1, 0, 0, "");
    b.addNode(3, NodeKind::sampler, 1, 0, 0, R"({"zones": [{"assetID": 7, "rootKey": 69}]})");
    b.addNode(4, NodeKind::channelStrip, 1, strip, 4, "");
    b.addEdge(10, 2, 3, EdgeKind::midi, 0);
    b.addEdge(11, 3, 4, EdgeKind::audio, 0);
    b.addEdge(12, 4, 1, EdgeKind::audio, 0);
    b.setTempo(0, 120.0);
    b.setTimeSignature(0, 4, 4);
    b.setMaster(1);
    const uint64_t version = facade->applyGraph(b.description());
    DAW_CHECK(facade->waitForGraph(version, 5000).publishedVersion == version);

    auto level = [&] { return facade->meter(4).peak; };
    auto sounds = [&] { return eventually([&] { return level() > 0.1f; }); };
    auto silent = [&] { return eventually([&] { return level() < 1e-4f; }); };
    constexpr uint8_t kNote = 69;
    DAW_CHECK(silent());
    DAW_CHECK(facade->midiInputs().empty());  // the fake device has no CoreMIDI

    // Not armed: nothing plays through.
    DAW_CHECK(facade->injectMidi(0, true, kOn, kNote, 127, 3).ok());
    std::this_thread::sleep_for(50ms);
    DAW_CHECK(level() < 1e-4f);
    DAW_CHECK(facade->injectMidi(0, true, kOff, kNote, 0, 3).ok());

    // Armed: heard through the instrument, transport stopped; every monitoring mode (T-053).
    facade->armMidiInput(5, 2, true);
    DAW_CHECK(facade->telemetry().armedMidiTracks == 1);
    DAW_CHECK(facade->injectMidi(0, true, kOn, kNote, 127, 3).ok());
    DAW_CHECK(sounds());
    DAW_CHECK(facade->injectMidi(0, true, kOff, kNote, 0, 3).ok());
    DAW_CHECK(silent());

    // Disarm with a held key: no hanging note.
    DAW_CHECK(facade->injectMidi(0, true, kOn, kNote, 127, 3).ok());
    DAW_CHECK(sounds());
    facade->armMidiInput(5, 2, false);
    DAW_CHECK(silent());
    facade->armMidiInput(5, 2, true);

    // Record: notes scheduled ahead on the transport timeline land at sample − output latency.
    const TelemetryPOD before = facade->telemetry();
    DAW_CHECK(before.deviceOutputLatency > 0);
    const int64_t latency = before.deviceOutputLatency;
    facade->setRecording(true);
    facade->play();
    // Absolute positions mean something once the transport moves; well ahead, so scheduling is
    // exact however the machine is loaded.
    DAW_CHECK(eventually([&] { return facade->transport().playing && facade->transport().sample > 256; }));
    const int64_t s1 = facade->transport().sample + 24000, s2 = s1 + 10000;
    DAW_CHECK(facade->injectMidi(s1, false, kOn, 60, 100, 3).ok());
    DAW_CHECK(facade->injectMidi(s2, false, kOff, 60, 0, 3).ok());
    DAW_CHECK(eventually([&] { return facade->transport().sample > s2 + 4800; }));
    facade->stop();

    std::vector<EngineEventPOD> events;
    DAW_CHECK(eventually([&] {
        EngineEventPOD batch[8];
        size_t n = facade->pollEvents(batch, 8);
        for (size_t i = 0; i < n; ++i)
            if (batch[i].type == EngineEventType::recordingFinalized) events.push_back(batch[i]);
        return !events.empty();
    }));
    DAW_CHECK(events.size() == 1);
    if (events.size() == 1) {
        const RecordingPOD& r = events[0].recording;
        DAW_CHECK(r.midi && r.track == 5 && r.file.empty() && events[0].subject == 5);
        DAW_CHECK(r.startSample == -latency);
        DAW_CHECK(r.sampleRate == kRate);
        DAW_CHECK(r.notes.size() == 1);
        if (r.notes.size() == 1) {
            DAW_CHECK(r.notes[0].start == s1 - latency);
            DAW_CHECK(r.notes[0].end == s2 - latency);
            DAW_CHECK(r.notes[0].pitch == 60 && r.notes[0].velocity == 100);
        }
    }
    const TelemetryPOD after = facade->telemetry();
    DAW_CHECK(after.midiInputDrops == 0);
    DAW_CHECK(after.rtViolations == 0);

    // Offline: no input at all.
    {
        DriverConfigPOD offlineConfig;
        offlineConfig.sampleRate = kRate;
        EngineFacade* offline = EngineFacade::create(EngineMode::offline, offlineConfig);
        DAW_CHECK(offline != nullptr);
        if (offline) {
            DAW_CHECK(offline->injectMidi(0, true, kOn, 60, 100, 3).code == FacadeErrorCode::unsupported);
            releaseFacade(offline);
        }
    }
    DAW_CHECK(facade->injectMidi(0, true, 0x12, 60, 100, 3).code == FacadeErrorCode::invalidArgument);
    return checks;
}

// MARK: Real CoreMIDI

CheckResult midiCoreMidiVirtualSource() {
    CheckResult checks;
    if (std::getenv("DAW_SKIP_DEVICE_TESTS") != nullptr) return checks;

    auto rig = std::make_unique<Rig>();
    rig->router.setArmed(kTrack, kPlayer, true);
    CoreMidiInput input(rig->router);
    DAW_CHECK(input.waitUntilReady(10000));
    if (!input.available()) return checks;  // no MIDI server here: nothing to test against

    MIDIClientRef client = 0;
    if (MIDIClientCreateWithBlock(CFSTR("Ember Test Client"), &client, nil) != noErr) return checks;
    MIDIEndpointRef source = 0;
    const CFStringRef name = CFSTR("Ember Test Source T-053");
    if (MIDISourceCreateWithProtocol(client, name, kMIDIProtocol_1_0, &source) != noErr) {
        MIDIClientDispose(client);
        return checks;
    }

    bool seen = false;
    int32_t uniqueID = 0;
    (void)MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uniqueID);
    DAW_CHECK(eventually([&] {
        input.rescan();
        for (const MidiSourceInfo& s : input.sources())
            if (s.uniqueID == uniqueID && s.connected) seen = true;
        return seen;
    }));

    // A note through a real MIDIEventList: a universal MIDI packet (type 2, channel voice).
    (void)rig->block();
    MIDIEventList list{};
    MIDIEventPacket* packet = MIDIEventListInit(&list, kMIDIProtocol_1_0);
    const UInt32 noteOn = (0x2u << 28) | (uint32_t{kOn} << 16) | (60u << 8) | 100u;
    packet = MIDIEventListAdd(&list, sizeof(list), packet, mach_absolute_time(), 1, &noteOn);
    DAW_CHECK(packet != nullptr);
    DAW_CHECK(MIDIReceivedEventList(source, &list) == noErr);
    bool on = false;
    DAW_CHECK(eventually([&] {
        for (const Ev& e : rig->block())
            if (e.status == kOn && e.d1 == 60) on = true;
        return on;
    }));

    // The source goes away with the key down: its note-off is synthesized.
    MIDIEndpointDispose(source);
    bool off = false;
    DAW_CHECK(eventually([&] {
        input.rescan();
        for (const Ev& e : rig->block())
            if (e.status == kOff && e.d1 == 60) off = true;
        return off;
    }));
    MIDIClientDispose(client);
    DAW_CHECK(rig->violations == 0);
    return checks;
}

} // namespace daw::testing
