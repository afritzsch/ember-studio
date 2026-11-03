// T-043 checks for preview notes (UI-021). Run from Tests/DAWEngineTests/PreviewNoteTests.swift;
// see PreviewNoteChecks.h.

#include "PreviewNoteChecks.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <memory>
#include <numbers>
#include <random>
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
#include "nodes/MidiClipPlayer.h"
#include "time/TempoMap.h"
#include "time/Transport.h"

using namespace daw;
using namespace std::chrono_literals;

namespace daw::testing {

namespace {

constexpr double kRate = 48000.0;
constexpr uint8_t kOn = MidiClipPlayer::kNoteOn;   // channel 1
constexpr uint8_t kOff = MidiClipPlayer::kNoteOff;

struct Ev {
    uint32_t frame;
    uint8_t status, d1, d2;
    bool operator==(const Ev&) const = default;
};

TempoMap makeTempo() { return std::move(TempoMap::make({{0, 120.0}}, {{0, 4, 4}}, kRate)).value(); }

// Runs one MidiClipPlayer the way Engine::render runs a timeline node (advance, reset on a
// locate while playing, process), each block in its own RtScope.
class Driver {
public:
    Driver(MidiPreviewInbox& inbox, NodeID id, std::vector<NoteDesc> notes = {}, uint32_t capacity = 1024)
        : inbox_(inbox), id_(id), notes_(std::move(notes)), tempo_(makeTempo()), storage_(capacity) {
        recreate();
    }

    // A new instance with the same NodeID, as a note edit makes (DW-051).
    void recreate() {
        player_ = MidiClipPlayer::create(notes_, &inbox_, id_);
        player_->prepare(PrepareInfo{kRate, kMaxBlock, 0, 0});
    }

    Transport& transport() { return transport_; }

    std::vector<Ev> render(uint32_t n) {
        NodeIO io;
        io.midiOut = MidiEventWriter(storage_.data(), static_cast<uint32_t>(storage_.size()));
        {
            RtScope scope;
            const TransportBlock& block = transport_.advance(tempo_, n);
            if (transport_.locatedWhilePlaying()) player_->reset();
            ProcessContext ctx{n, kRate, block, params_};
            player_->process(ctx, io);
            violations_ += scope.violations();
        }
        std::vector<Ev> out;
        uint32_t last = 0;
        for (const MidiEvent& e : io.midiOut.written()) {
            if (e.frameOffset >= n || e.frameOffset < last || e.size != 3) ++badEvents_;
            last = e.frameOffset;
            out.push_back({e.frameOffset, e.data[0], e.data[1], e.data[2]});
        }
        return out;
    }
    // The first block of a new instance: its All Notes Off goes, the rest is returned.
    std::vector<Ev> renderAfterAnnounce(uint32_t n) {
        std::vector<Ev> out = render(n);
        std::erase_if(out, [](const Ev& e) { return (e.status & 0xF0) == 0xB0 && e.d1 == MidiClipPlayer::kAllNotesOff; });
        return out;
    }

    uint64_t violations() const { return violations_; }
    int badEvents() const { return badEvents_; }

private:
    MidiPreviewInbox& inbox_;
    NodeID id_;
    std::vector<NoteDesc> notes_;
    TempoMap tempo_;
    Transport transport_;
    ParamSlotTable params_{16};
    std::vector<MidiEvent> storage_;
    std::unique_ptr<MidiClipPlayer> player_;
    uint64_t violations_ = 0;
    int badEvents_ = 0;
};

std::vector<Ev> notes(const std::vector<Ev>& events) {
    std::vector<Ev> out;
    for (const Ev& e : events)
        if ((e.status & 0xE0) == 0x80) out.push_back(e);
    return out;
}

template <class F>
bool eventually(F done, std::chrono::milliseconds timeout = 5000ms) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (!done()) {
        if (std::chrono::steady_clock::now() > deadline) return false;
        std::this_thread::sleep_for(2ms);
    }
    return true;
}

} // namespace

CheckResult previewInboxDeliversToItsPlayer() {
    CheckResult checks;
    MidiPreviewInbox inbox;
    Driver a(inbox, 2), b(inbox, 5);
    (void)a.renderAfterAnnounce(64);
    (void)b.renderAfterAnnounce(64);
    DAW_CHECK(a.render(64).empty());  // nothing posted, nothing played

    DAW_CHECK(inbox.post(2, 60, 100, true));
    DAW_CHECK(inbox.heldCount(2) == 1);
    DAW_CHECK(b.render(64).empty());  // not B's
    DAW_CHECK((a.render(64) == std::vector<Ev>{{0, kOn, 60, 100}}));
    DAW_CHECK(a.render(64).empty());  // once

    // An on for a held pitch retriggers it; an off for a pitch that isn't held is dropped.
    DAW_CHECK(inbox.post(2, 60, 90, true));
    DAW_CHECK(inbox.post(2, 61, 0, false));
    DAW_CHECK((a.render(64) == std::vector<Ev>{{0, kOff, 60, 64}, {0, kOn, 60, 90}}));
    DAW_CHECK(inbox.heldCount(2) == 1);
    DAW_CHECK(inbox.post(2, 60, 0, false));
    DAW_CHECK((a.render(64) == std::vector<Ev>{{0, kOff, 60, 64}}));
    DAW_CHECK(inbox.heldCount(2) == 0);

    // Velocity is clamped (a velocity-0 on would be an off); bad posts are refused.
    DAW_CHECK(inbox.post(2, 70, 0, true) && inbox.post(2, 71, 200, true));
    DAW_CHECK((a.render(64) == std::vector<Ev>{{0, kOn, 70, 1}, {0, kOn, 71, 127}}));
    DAW_CHECK(!inbox.post(2, 128, 100, true));
    DAW_CHECK(!inbox.post(0, 60, 100, true));

    // Each player gets its own; releaseAll ends every held note of every player.
    DAW_CHECK(inbox.post(5, 64, 100, true));
    DAW_CHECK((b.render(64) == std::vector<Ev>{{0, kOn, 64, 100}}));
    inbox.releaseAll();
    DAW_CHECK(inbox.heldCount(2) == 0 && inbox.heldCount(5) == 0);
    auto offsA = a.render(64);
    std::sort(offsA.begin(), offsA.end(), [](const Ev& x, const Ev& y) { return x.d1 < y.d1; });
    DAW_CHECK((offsA == std::vector<Ev>{{0, kOff, 70, 64}, {0, kOff, 71, 64}}));
    DAW_CHECK((b.render(64) == std::vector<Ev>{{0, kOff, 64, 64}}));

    // Playing: previews sound at frame 0, before the clip's own events, in frame order.
    MidiPreviewInbox inbox2;
    Driver c(inbox2, 9, {NoteDesc{9, 0, 960, 48, 80, 0}});
    (void)c.renderAfterAnnounce(0);
    c.transport().play();
    DAW_CHECK(inbox2.post(9, 72, 100, true));
    const auto playing = notes(c.render(256));
    DAW_CHECK(playing.size() == 2);
    if (playing.size() == 2) {
        DAW_CHECK((playing[0] == Ev{0, kOn, 72, 100}));
        DAW_CHECK((playing[1] == Ev{0, kOn, 48, 80}));
    }
    DAW_CHECK(inbox2.post(9, 72, 0, false));
    DAW_CHECK((notes(c.render(256)) == std::vector<Ev>{{0, kOff, 72, 64}}));
    DAW_CHECK(a.violations() == 0 && b.violations() == 0 && c.violations() == 0);
    DAW_CHECK(a.badEvents() == 0 && b.badEvents() == 0 && c.badEvents() == 0);
    return checks;
}

CheckResult previewNotesSurviveRecreatedPlayer() {
    CheckResult checks;
    MidiPreviewInbox inbox;
    Driver a(inbox, 3);
    (void)a.renderAfterAnnounce(64);
    DAW_CHECK(inbox.post(3, 62, 110, true));
    DAW_CHECK((a.render(64) == std::vector<Ev>{{0, kOn, 62, 110}}));

    // A note edit re-creates the player: All Notes Off, then the held preview again.
    a.recreate();
    const auto first = a.render(64);
    DAW_CHECK(first.size() == 17);
    if (first.size() == 17) {
        for (int ch = 0; ch < 16; ++ch)
            DAW_CHECK((first[size_t(ch)] == Ev{0, uint8_t(0xB0 | ch), MidiClipPlayer::kAllNotesOff, 0}));
        DAW_CHECK((first[16] == Ev{0, kOn, 62, 110}));
    }
    DAW_CHECK(inbox.post(3, 62, 0, false));
    DAW_CHECK((a.render(64) == std::vector<Ev>{{0, kOff, 62, 64}}));

    // The on still queued when the new instance starts sounds once, not twice.
    DAW_CHECK(inbox.post(3, 65, 90, true));
    a.recreate();
    DAW_CHECK((a.renderAfterAnnounce(64) == std::vector<Ev>{{0, kOn, 65, 90}}));
    DAW_CHECK(inbox.post(3, 65, 0, false));
    DAW_CHECK((a.render(64) == std::vector<Ev>{{0, kOff, 65, 64}}));

    // No instrument: no MIDI storage, so nothing is written or held.
    Driver none(inbox, 4, {}, 0);
    DAW_CHECK(none.render(64).empty());
    DAW_CHECK(inbox.post(4, 60, 100, true));
    DAW_CHECK(none.render(64).empty());
    DAW_CHECK(inbox.post(4, 60, 0, false));
    DAW_CHECK(none.render(64).empty());
    DAW_CHECK(a.violations() == 0 && none.violations() == 0 && a.badEvents() == 0);
    return checks;
}

CheckResult previewInboxMailboxesAreReused() {
    CheckResult checks;
    MidiPreviewInbox inbox;
    constexpr uint32_t n = MidiPreviewInbox::kMailboxes;
    std::vector<std::unique_ptr<Driver>> players;
    for (uint32_t i = 0; i < n; ++i) {
        players.push_back(std::make_unique<Driver>(inbox, NodeID(100 + i)));
        (void)players.back()->renderAfterAnnounce(32);
        DAW_CHECK(inbox.post(100 + i, 60, 100, true));
    }
    // Every mailbox holds a note: one more player is refused.
    DAW_CHECK(!inbox.post(999, 60, 100, true));
    for (auto& p : players) DAW_CHECK((p->render(32) == std::vector<Ev>{{0, kOn, 60, 100}}));
    // Player 100 lets go; its mailbox is handed on once its queue is drained.
    DAW_CHECK(inbox.post(100, 60, 0, false));
    DAW_CHECK(!inbox.post(999, 60, 100, true));  // its off is still queued
    DAW_CHECK((players[0]->render(32) == std::vector<Ev>{{0, kOff, 60, 64}}));
    Driver late(inbox, 999);
    (void)late.renderAfterAnnounce(32);
    DAW_CHECK(inbox.post(999, 61, 100, true));
    DAW_CHECK(players[0]->render(32).empty());  // not the old owner's any more
    DAW_CHECK((late.render(32) == std::vector<Ev>{{0, kOn, 61, 100}}));
    // Player 100 is refused now, the others keep their mailboxes.
    DAW_CHECK(!inbox.post(100, 60, 100, true));
    DAW_CHECK(inbox.post(101, 60, 0, false));
    DAW_CHECK((players[1]->render(32) == std::vector<Ev>{{0, kOff, 60, 64}}));
    uint64_t violations = late.violations();
    for (auto& p : players) violations += p->violations();
    DAW_CHECK(violations == 0);
    return checks;
}

CheckResult previewNotesNeverHang() {
    CheckResult checks;
    std::mt19937 rng(43);
    for (int run = 0; run < 20; ++run) {
        MidiPreviewInbox inbox;
        // Dense notes on channel 1 so the clip and the previews share keys; a small writer.
        std::vector<NoteDesc> clip;
        for (int i = 0; i < 400; ++i)
            clip.push_back(NoteDesc{7, Tick(rng() % (16 * 960)), Tick(1 + rng() % 1920), uint8_t(40 + rng() % 40),
                                    uint8_t(1 + rng() % 127), uint8_t(rng() % 2)});
        Driver d(inbox, 7, clip, 24 + rng() % 40);
        std::vector<int> held(16 * 128, 0);
        int strays = 0;
        auto account = [&](const std::vector<Ev>& events) {
            for (const Ev& e : events) {
                const int ch = e.status & 0x0F, status = e.status & 0xF0;
                if (status == 0xB0 && e.d1 == MidiClipPlayer::kAllNotesOff) {
                    for (int k = 0; k < 128; ++k) held[size_t(ch * 128 + k)] = 0;
                } else if (status == 0x90) {
                    ++held[size_t(ch * 128 + e.d1)];
                } else if (status == 0x80) {
                    if (held[size_t(ch * 128 + e.d1)] > 0) --held[size_t(ch * 128 + e.d1)];
                    else ++strays;
                }
            }
        };
        for (int step = 0; step < 300; ++step) {
            switch (rng() % 12) {
            case 0: d.transport().play(); break;
            case 1: d.transport().stop(); inbox.releaseAll(); break;  // as EngineFacade::stop
            case 2: d.transport().locate(Tick(rng() % (16 * 960))); inbox.releaseAll(); break;
            case 3: d.recreate(); break;
            default: {
                const int posts = int(rng() % 4);
                for (int p = 0; p < posts; ++p)
                    (void)inbox.post(7, uint8_t(40 + rng() % 40), uint8_t(rng() % 128), rng() % 2 == 0);
            }
            }
            account(d.render(uint32_t(1 + rng() % 512)));
        }
        inbox.releaseAll();
        d.transport().stop();
        for (int i = 0; i < 3; ++i) account(d.render(64));
        int stillHeld = 0;
        for (int h : held) stillHeld += h;
        DAW_CHECK(stillHeld == 0);
        DAW_CHECK(strays == 0);
        DAW_CHECK(d.badEvents() == 0);
        DAW_CHECK(d.violations() == 0);
        DAW_CHECK(inbox.heldCount(7) == 0);
    }
    return checks;
}

CheckResult previewNoteThroughFacade() {
    CheckResult checks;
    TempDir dir;
    std::vector<float> sine(2 * 48000);
    for (size_t i = 0; i < sine.size(); ++i)
        sine[i] = 0.5f * static_cast<float>(std::sin(2.0 * std::numbers::pi * 440.0 * static_cast<double>(i) / kRate));
    const auto file = dir.path() / "sine440.wav";
    DAW_CHECK(writeTestFile(file, "wav-f32", kRate, Channels{sine}).ok());

    // master 1 ← strip 4 ← sampler 3 ←midi— player 2 (no notes): an A4-rooted sine zone.
    auto setUp = [&](EngineFacade& facade) {
        const JobID load = facade.loadAsset(7, file.string());
        DAW_CHECK(eventually([&] {
            const JobState s = facade.pollJob(load).state;
            return s == JobState::succeeded || s == JobState::failed;
        }));
        const ParamID strip = facade.allocateParams(4);
        facade.setParam(strip + 0, 1.0f);
        facade.setParam(strip + 1, 0.0f);
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
        const uint64_t version = facade.applyGraph(b.description());
        DAW_CHECK(facade.waitForGraph(version, 5000).publishedVersion == version);
    };

    {
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
        setUp(*facade);
        auto level = [&] { return facade->meter(4).peak; };
        auto sounds = [&] { return eventually([&] { return level() > 0.1f; }); };
        auto silent = [&] { return eventually([&] { return level() < 1e-4f; }); };
        DAW_CHECK(facade->telemetry().deviceRunning);
        DAW_CHECK(!facade->transport().playing);
        DAW_CHECK(silent());

        // Stopped transport: the preview sounds until its off (release 0.2 s).
        facade->previewNote(2, 69, 127, true);
        DAW_CHECK(sounds());
        std::this_thread::sleep_for(100ms);
        DAW_CHECK(level() > 0.1f);  // held, not a one-shot blip
        facade->previewNote(2, 69, 0, false);
        DAW_CHECK(silent());

        // Another source's preview doesn't reach this instrument.
        facade->previewNote(77, 69, 127, true);
        std::this_thread::sleep_for(50ms);
        DAW_CHECK(level() < 1e-4f);
        facade->previewNote(77, 69, 0, false);

        // stop() and locate() end a held preview.
        facade->previewNote(2, 69, 127, true);
        DAW_CHECK(sounds());
        facade->stop();
        DAW_CHECK(silent());
        facade->previewNote(2, 72, 127, true);
        DAW_CHECK(sounds());
        facade->locate(960);
        DAW_CHECK(silent());
        DAW_CHECK(facade->telemetry().rtViolations == 0);
    }
    {
        // Offline: a note-on is ignored, so the next export renders no preview.
        DriverConfigPOD config;
        config.sampleRate = kRate;
        EngineFacade* facade = EngineFacade::create(EngineMode::offline, config);
        DAW_CHECK(facade != nullptr);
        if (!facade) return checks;
        struct Release {
            EngineFacade* f;
            ~Release() { releaseFacade(f); }
        } release{facade};
        setUp(*facade);
        facade->previewNote(2, 69, 127, true);
        ExportSpecPOD spec;
        spec.path = (dir.path() / "offline.wav").string();
        spec.tailEnabled = false;
        const JobID job = facade->renderOffline(0, 960, spec);
        JobStatus done;
        DAW_CHECK(eventually([&] {
            done = facade->pollJob(job);
            return done.state == JobState::succeeded || done.state == JobState::failed;
        }, 20000ms));
        DAW_CHECK(done.state == JobState::succeeded && done.render.rtViolations == 0);
        auto back = readBack(spec.path, kRate);
        DAW_CHECK(back.ok());
        if (back && !back->empty()) {
            float peak = 0;
            for (float x : (*back)[0]) peak = std::max(peak, std::abs(x));
            DAW_CHECK(peak == 0.0f);
        }
        facade->previewNote(2, 69, 0, false);
    }
    return checks;
}

} // namespace daw::testing
