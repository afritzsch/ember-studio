// T-040 checks for the MidiClipPlayer. Run from Tests/DAWEngineTests/MidiClipPlayerTests.swift;
// see MidiClipPlayerChecks.h for why they're C++ and how they drive the player.

#include "MidiClipPlayerChecks.h"

#include <algorithm>
#include <cstdint>
#include <memory>
#include <random>
#include <span>
#include <tuple>
#include <utility>
#include <vector>

#include "core/Engine.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/ProcessContext.h"
#include "core/RtTrap.h"
#include "daw/GraphDescription.h"
#include "graph/GraphBuilder.h"
#include "graph/NodeRegistry.h"
#include "nodes/BuiltinNodes.h"
#include "nodes/MidiClipPlayer.h"
#include "time/TempoMap.h"
#include "time/Transport.h"

using namespace daw;

namespace daw::testing {

namespace {

// At 120 bpm and 48 kHz one tick is exactly 25 samples.
constexpr double kRate = 48000.0;
constexpr uint32_t kCapacity = 1024;

// One event at an absolute output frame (the sum of the frames of every block before it).
struct Ev {
    int64_t frame;
    uint8_t status, d1, d2;
    bool operator==(const Ev&) const = default;
};

Ev on(int64_t frame, uint8_t pitch, uint8_t velocity, uint8_t channel = 0) {
    return {frame, uint8_t(MidiClipPlayer::kNoteOn | channel), pitch, velocity};
}
Ev off(int64_t frame, uint8_t pitch, uint8_t channel = 0) {
    return {frame, uint8_t(MidiClipPlayer::kNoteOff | channel), pitch, MidiClipPlayer::kReleaseVelocity};
}
bool isNote(const Ev& e) { return (e.status & 0xE0) == 0x80; }  // 0x8n or 0x9n

std::vector<Ev> notesOnly(const std::vector<Ev>& events) {
    std::vector<Ev> out;
    for (const Ev& e : events)
        if (isNote(e)) out.push_back(e);
    return out;
}

// Order-free form for comparing against an oracle: by frame, offs first, then channel, pitch.
std::vector<Ev> canonical(std::vector<Ev> events) {
    std::sort(events.begin(), events.end(), [](const Ev& a, const Ev& b) {
        return std::tie(a.frame, a.status, a.d1, a.d2) < std::tie(b.frame, b.status, b.d1, b.d2);
    });
    return events;
}

NoteDesc note(Tick start, Tick length, uint8_t pitch, uint8_t velocity = 100, uint8_t channel = 0,
              NodeID player = 0) {
    return NoteDesc{player, start, length, pitch, velocity, channel};
}

TempoMap makeTempo(TempoEventList tempos = {{0, 120.0}}) {
    return std::move(TempoMap::make(tempos, {{0, 4, 4}}, kRate)).value();
}

// Runs a MidiClipPlayer the way Engine::render runs a timeline node: advance the transport,
// reset() on a locate while playing, process() — all in one RtScope per block.
class Driver {
public:
    Driver(std::span<const NoteDesc> notes, TempoMap tempo, uint32_t capacity = kCapacity)
        : player_(MidiClipPlayer::create(notes)), tempo_(std::move(tempo)), storage_(capacity) {
        player_->prepare(PrepareInfo{kRate, kMaxBlock, 0, 0});
    }

    Transport& transport() { return transport_; }
    const TempoMap& tempo() const { return tempo_; }
    MidiClipPlayer& player() { return *player_; }

    // Renders one block of `n` frames and appends its events to events().
    void render(uint32_t n) {
        NodeIO io;
        io.midiOut = MidiEventWriter(storage_.data(), static_cast<uint32_t>(storage_.size()));
        {
            RtScope scope;
            const TransportBlock& block = transport_.advance(tempo_, n);
            if (transport_.locatedWhilePlaying()) player_->reset();  // TIME-008
            ProcessContext ctx{n, kRate, block, params_};
            player_->process(ctx, io);
            violations_ += scope.violations();
        }
        block_ = transport_.block();
        blockEvents_.clear();
        uint32_t last = 0;
        for (const MidiEvent& e : io.midiOut.written()) {
            // In frame order, inside the block, three bytes.
            if (e.frameOffset >= n || e.frameOffset < last || e.size != 3) ++badEvents_;
            last = e.frameOffset;
            blockEvents_.push_back({frame_ + e.frameOffset, e.data[0], e.data[1], e.data[2]});
        }
        events_.insert(events_.end(), blockEvents_.begin(), blockEvents_.end());
        frame_ += n;
        lastFrames_ = n;
    }
    void renderFrames(int64_t total, uint32_t blockSize) {
        for (int64_t done = 0; done < total; done += blockSize)
            render(static_cast<uint32_t>(std::min<int64_t>(blockSize, total - done)));
    }

    const std::vector<Ev>& events() const { return events_; }
    const std::vector<Ev>& blockEvents() const { return blockEvents_; }
    const TransportBlock& lastBlock() const { return block_; }
    int64_t frame() const { return frame_; }
    uint32_t lastFrames() const { return lastFrames_; }
    uint64_t violations() const { return violations_; }
    int badEvents() const { return badEvents_; }

private:
    std::unique_ptr<MidiClipPlayer> player_;
    TempoMap tempo_;
    Transport transport_;
    ParamSlotTable params_{16};
    std::vector<MidiEvent> storage_;
    TransportBlock block_{};
    std::vector<Ev> events_, blockEvents_;
    int64_t frame_ = 0;
    uint32_t lastFrames_ = 0;
    uint64_t violations_ = 0;
    int badEvents_ = 0;
};

// What a receiver would hold: notes on per (channel, key). An off for a key that isn't held is
// a stray (an off without its on).
class Keys {
public:
    void apply(const Ev& e) {
        const uint8_t type = e.status & 0xF0, ch = e.status & 0x0F;
        if (type == MidiClipPlayer::kNoteOn) ++held_[ch][e.d1];
        if (type == MidiClipPlayer::kNoteOff) {
            if (held_[ch][e.d1] == 0) ++strays_;
            else --held_[ch][e.d1];
        }
    }
    void apply(const std::vector<Ev>& events) {
        for (const Ev& e : events) apply(e);
    }
    int held(uint8_t ch, uint8_t key) const { return held_[ch][key]; }
    int total() const {
        int n = 0;
        for (const auto& ch : held_)
            for (int k : ch) n += k;
        return n;
    }
    int strays() const { return strays_; }

private:
    int held_[16][128] = {};
    int strays_ = 0;
};

} // namespace

CheckResult midiClipPlayerEmitsNotes() {
    CheckResult checks;
    const std::vector<NoteDesc> notes = {
        note(40, 80, 60, 100),      // samples [1000, 3000)
        note(50, 10, 64, 0, 9),     // velocity 0 → 1; channel 9; [1250, 1500)
        note(120, 40, 60, 90),      // starts where the first ends: off, then on, at 3000
        note(10, 0, 70),            // dropped: length 0
        note(10, 10, 128),          // dropped: pitch > 127
        note(10, 10, 70, 100, 16),  // dropped: channel > 15
    };
    const std::vector<Ev> expected = {on(1000, 60, 100), on(1250, 64, 1, 9), off(1500, 64, 9),
                                      off(3000, 60), on(3000, 60, 90), off(4000, 60)};

    for (uint32_t blockSize : {256u, 1u, 0u}) {  // 0: random sizes
        Driver d(notes, makeTempo());
        DAW_CHECK(d.player().notes().size() == 3);
        DAW_CHECK(d.transport().locate(0) && d.transport().play());
        std::mt19937 rng(blockSize + 7);
        std::uniform_int_distribution<uint32_t> size(0, 700);
        while (d.frame() < 5000) d.render(blockSize ? blockSize : size(rng));
        DAW_CHECK(notesOnly(d.events()) == expected);
        DAW_CHECK(d.badEvents() == 0);
        DAW_CHECK(d.violations() == 0);
    }
    return checks;
}

CheckResult midiClipPlayerMatchesOracle() {
    CheckResult checks;
    for (uint32_t seed = 1; seed <= 4; ++seed) {
        std::mt19937 rng(seed);
        auto uniform = [&](int64_t lo, int64_t hi) { return std::uniform_int_distribution<int64_t>(lo, hi)(rng); };
        std::vector<NoteDesc> notes;
        for (int i = 0; i < 300; ++i)
            notes.push_back(note(uniform(0, 30000), uniform(1, 3000), uint8_t(uniform(36, 48)),
                                 uint8_t(uniform(1, 127)), uint8_t(uniform(0, 3))));
        const TempoMap tempo = makeTempo({{0, 120.0}, {7680, 90.0}, {15360, 151.0}, {23040, 60.0}});

        std::vector<Ev> oracle;
        for (const NoteDesc& n : notes) {
            oracle.push_back(on(tempo.tickToSample(n.start), n.pitch, n.velocity, n.channel));
            oracle.push_back(off(tempo.tickToSample(n.start + n.length), n.pitch, n.channel));
        }
        const int64_t total = tempo.tickToSample(34000);

        Driver d(notes, tempo);
        DAW_CHECK(d.transport().locate(0) && d.transport().play());
        while (d.frame() < total) d.render(static_cast<uint32_t>(uniform(0, 900)));
        DAW_CHECK(canonical(notesOnly(d.events())) == canonical(oracle));
        Keys keys;
        keys.apply(d.events());  // in emitted order: every off after its on
        DAW_CHECK(keys.strays() == 0 && keys.total() == 0);
        DAW_CHECK(d.badEvents() == 0);
        DAW_CHECK(d.violations() == 0);
    }
    return checks;
}

CheckResult midiClipPlayerLoopWrap() {
    CheckResult checks;
    // Loop [1920, 3840) = samples [48000, 96000): the first pass plays from 0, later ones from
    // 48000, so pass k >= 1 starts at output frame 96000 + (k − 1) · 48000.
    const std::vector<NoteDesc> notes = {
        note(1800, 240, 60),  // [45000, 51000): before the loop start, so later passes don't chase it
        note(1920, 100, 64),  // [48000, 50500): on the loop start
        note(3700, 400, 62),  // [92500, 102500): hangs over the loop end
    };
    std::vector<Ev> expected = {on(45000, 60, 100), on(48000, 64, 100), off(50500, 64), off(51000, 60),
                                on(92500, 62, 100)};
    for (int64_t pass = 96000; pass < 96000 + 3 * 48000; pass += 48000) {
        // The wrap: the hanging note ends, then the new pass's ons, on the same frame.
        expected.push_back(off(pass, 62));
        expected.push_back(on(pass, 64, 100));
        expected.push_back(off(pass + 2500, 64));
        expected.push_back(on(pass + 44500, 62, 100));
    }

    for (uint32_t blockSize : {999u, 4096u, 0u}) {  // wraps mid-block; 0: random sizes
        Driver d(notes, makeTempo());
        DAW_CHECK(d.transport().setLoop(true, 1920, 3840) && d.transport().locate(0) && d.transport().play());
        std::mt19937 rng(blockSize + 3);
        std::uniform_int_distribution<uint32_t> size(0, 3000);
        const int64_t total = 96000 + 3 * 48000;
        while (d.frame() < total) {
            const auto left = static_cast<uint32_t>(total - d.frame());
            d.render(std::min(blockSize ? blockSize : size(rng), left));
        }
        DAW_CHECK(notesOnly(d.events()) == expected);
        Keys keys;
        keys.apply(d.events());
        DAW_CHECK(keys.strays() == 0 && keys.held(0, 62) == 1 && keys.total() == 1);
        DAW_CHECK(d.badEvents() == 0);
        DAW_CHECK(d.violations() == 0);
    }
    return checks;
}

CheckResult midiClipPlayerLocateAndStop() {
    CheckResult checks;
    // A long note at [0, 48000) and a short one at [2500, 3000).
    const std::vector<NoteDesc> notes = {note(0, 1920, 60), note(100, 20, 72)};
    Driver d(notes, makeTempo());
    DAW_CHECK(d.transport().locate(0) && d.transport().play());
    d.renderFrames(2048, 512);
    DAW_CHECK(notesOnly(d.events()) == std::vector<Ev>{on(0, 60, 100)});

    // Locate while playing: the held note ends at frame 0 of the next block, and isn't chased at
    // the new position, inside it.
    DAW_CHECK(d.transport().locate(960));
    d.render(512);
    DAW_CHECK(notesOnly(d.blockEvents()) == std::vector<Ev>{off(2048, 60)});
    d.renderFrames(48000, 512);  // past the long note's end: no off for a note that isn't on
    DAW_CHECK(notesOnly(d.events()).size() == 2);

    // Locate back to 0 (while playing): the note starts again on frame 0, after the release.
    DAW_CHECK(d.transport().locate(0));
    int64_t at = d.frame();
    d.render(4096);
    DAW_CHECK(notesOnly(d.blockEvents()) ==
              (std::vector<Ev>{on(at, 60, 100), on(at + 2500, 72, 100), off(at + 3000, 72)}));

    // Stop: everything ends at frame 0 of the stopped block; a second stopped block sends nothing.
    DAW_CHECK(d.transport().stop());
    at = d.frame();
    d.render(256);
    DAW_CHECK(notesOnly(d.blockEvents()) == std::vector<Ev>{off(at, 60)});
    d.render(256);
    DAW_CHECK(d.blockEvents().empty());

    // Play from where it stopped (inside the long note): not chased, and no off at its end.
    DAW_CHECK(d.transport().play());
    d.renderFrames(48000, 1000);
    // Locate while stopped, then play: starts on a fresh note.
    DAW_CHECK(d.transport().stop());
    d.render(64);
    DAW_CHECK(d.transport().locate(100) && d.transport().play());
    at = d.frame();
    d.render(1000);
    DAW_CHECK(notesOnly(d.blockEvents()) == (std::vector<Ev>{on(at, 72, 100), off(at + 500, 72)}));

    Keys keys;
    keys.apply(d.events());
    DAW_CHECK(keys.strays() == 0 && keys.total() == 0);
    DAW_CHECK(d.badEvents() == 0);
    DAW_CHECK(d.violations() == 0);
    return checks;
}

CheckResult midiClipPlayerNoStuckNotesFuzz() {
    CheckResult checks;
    int locates = 0, wraps = 0, stops = 0, ons = 0;
    for (uint32_t seed = 1; seed <= 24; ++seed) {
        std::mt19937 rng(seed);
        auto uniform = [&](int64_t lo, int64_t hi) { return std::uniform_int_distribution<int64_t>(lo, hi)(rng); };
        // Few keys, so notes on one key overlap and retrigger.
        std::vector<NoteDesc> notes;
        for (int i = 0; i < 150; ++i)
            notes.push_back(note(uniform(0, 20000), uniform(1, 2000), uint8_t(uniform(60, 63)), 100,
                                 uint8_t(uniform(0, 1))));
        const TempoMap tempo = makeTempo({{0, 120.0}, {5000, 97.0}, {12000, 173.0}});
        // A third of the runs get a writer too small for every event (ons must give way to offs).
        const uint32_t capacity = seed % 3 == 0 ? static_cast<uint32_t>(uniform(1, 6)) : kCapacity;

        // Sample range of each note under this (fixed) map.
        struct Span { SamplePos on, off; uint8_t ch, key; };
        std::vector<Span> spans;
        for (const NoteDesc& n : notes)
            spans.push_back({tempo.tickToSample(n.start), tempo.tickToSample(n.start + n.length), n.channel, n.pitch});

        Driver d(notes, tempo, capacity);
        Keys keys;
        DAW_CHECK(d.transport().locate(uniform(0, 20000)) && d.transport().play());
        for (int step = 0; step < 600; ++step) {
            const int64_t roll = uniform(0, 99);
            if (roll < 8) {
                // Often inside the loop, so it keeps wrapping.
                const Tick to = uniform(0, 1) ? uniform(-500, 23000)
                                              : uniform(d.transport().loopStart() - 200, d.transport().loopEnd());
                DAW_CHECK(d.transport().locate(to));
                ++locates;
            }
            else if (roll < 12) { DAW_CHECK(d.transport().stop()); ++stops; }
            else if (roll < 20) DAW_CHECK(d.transport().play());
            else if (roll < 25) {
                const Tick a = uniform(0, 20000);
                DAW_CHECK(d.transport().setLoop(true, a, a + uniform(1, 800)));
            } else if (roll < 27) DAW_CHECK(d.transport().setLoop(false, 0, 1));
            d.render(static_cast<uint32_t>(uniform(0, 3) == 0 ? uniform(0, 8) : uniform(0, 1024)));

            keys.apply(d.blockEvents());
            for (const Ev& e : d.blockEvents()) ons += (e.status & 0xF0) == MidiClipPlayer::kNoteOn;
            const TransportBlock& b = d.lastBlock();
            for (uint8_t i = 0; i < b.numSegments; ++i) wraps += b.seg[i].afterWrap;
            if (b.numSegments == 0) {
                if (d.lastFrames() > 0) DAW_CHECK(keys.total() == 0);  // a stopped block releases everything
                continue;
            }
            // No note is held past its end: at the last frame played, each key is held at most
            // as often as notes on it are sounding there.
            const TransportSegment& last = b.seg[b.numSegments - 1];
            const SamplePos s = last.startSample + last.numFrames - 1;
            for (uint8_t ch = 0; ch < 2; ++ch)
                for (uint8_t key = 60; key <= 63; ++key) {
                    int sounding = 0;
                    for (const Span& sp : spans) sounding += sp.ch == ch && sp.key == key && sp.on <= s && s < sp.off;
                    DAW_CHECK(keys.held(ch, key) <= sounding);
                }
        }
        DAW_CHECK(d.transport().stop());
        d.render(32);
        keys.apply(d.blockEvents());
        DAW_CHECK(keys.strays() == 0);
        DAW_CHECK(keys.total() == 0);
        DAW_CHECK(d.badEvents() == 0);
        DAW_CHECK(d.violations() == 0);
    }
    DAW_CHECK(locates > 100 && wraps > 50 && stops > 50 && ons > 1000);  // not vacuous
    return checks;
}

CheckResult midiClipPlayerAllNotesOffOnNewInstance() {
    CheckResult checks;
    const std::vector<NoteDesc> notes = {note(0, 100, 60)};
    Driver d(notes, makeTempo());
    DAW_CHECK(d.transport().play());
    d.render(0);  // no frame to put it on
    DAW_CHECK(d.events().empty());
    d.render(64);
    const std::vector<Ev>& first = d.blockEvents();
    DAW_CHECK(first.size() == 17);
    for (uint8_t ch = 0; ch < 16 && first.size() == 17; ++ch)
        DAW_CHECK((first[ch] == Ev{0, uint8_t(MidiClipPlayer::kControlChange | ch), MidiClipPlayer::kAllNotesOff, 0}));
    if (first.size() == 17) DAW_CHECK(first[16] == on(0, 60, 100));  // after the CC 123s
    d.render(64);
    DAW_CHECK(d.blockEvents().empty());
    DAW_CHECK(d.violations() == 0);
    return checks;
}

namespace {

// TEST-004: stands in for the Sampler (T-041) at NodeKind::sampler, so a MIDI track builds.
class SamplerStandIn final : public Node {
public:
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext&, NodeIO& io) DAW_RT override {
        for (uint32_t c = 0; c < io.audioOut.numChannels; ++c)
            for (uint32_t f = 0; f < io.audioOut.numFrames; ++f) io.audioOut.channels[c][f] = 0.0f;
    }
};

// The MIDI part of the midi_tempo fixture (Tests/Fixtures/graph_snapshots/midi_tempo.txt):
// player 2 ─midi→ sampler 4 → master, plus a second MIDI track (player 5 → sampler 6) whose
// note must not reach player 2.
GraphDescription midiTrackGraph(uint32_t playerVersion, std::vector<NoteDesc> playerNotes) {
    GraphDescription d{1, {}, {}, {}, {}, {{{0, 120.0}, {7680, 90.0}}, {{0, 4, 4}, {7680, 3, 4}}}, 1};
    d.nodes.push_back(NodeDesc{1, NodeKind::master, 1, 0, 0, {}});
    d.nodes.push_back(NodeDesc{2, NodeKind::midiClipPlayer, playerVersion, 0, 0, {}});
    d.nodes.push_back(NodeDesc{4, NodeKind::sampler, 1, 0, 0, {}});
    d.nodes.push_back(NodeDesc{5, NodeKind::midiClipPlayer, 1, 0, 0, {}});
    d.nodes.push_back(NodeDesc{6, NodeKind::sampler, 1, 0, 0, {}});
    d.edges.push_back(EdgeDesc{1, 2, 4, EdgeKind::midi, 0});
    d.edges.push_back(EdgeDesc{2, 4, 1, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{3, 5, 6, EdgeKind::midi, 0});
    d.edges.push_back(EdgeDesc{4, 6, 1, EdgeKind::audio, 0});
    d.notes = std::move(playerNotes);
    d.notes.push_back(note(0, 960, 48, 100, 0, 5));
    return d;
}

} // namespace

CheckResult midiClipPlayerThroughGraphBuilder() {
    CheckResult checks;
    Engine engine;
    NodeRegistry registry = NodeRegistry::withBuiltins();
    DAW_CHECK(registerBuiltinNodes(registry, {}, &engine.telemetry()).ok());
    const NodeKindInfo* kind = registry.find(NodeKind::midiClipPlayer);
    DAW_CHECK(kind != nullptr && !kind->audioOutput);
    DAW_CHECK(registry.set(NodeKind::sampler, {[](const NodeCreateInfo&) -> Result<std::unique_ptr<Node>> {
                  return std::unique_ptr<Node>(std::make_unique<SamplerStandIn>());
              }}).ok());
    GraphBuilder builder(registry, kRate, kMaxBlock);
    auto playerNotes = [&](NodeID id) -> std::vector<MidiClipPlayer::Note> {
        auto node = engine.nodes().get(id);
        if (!node) return {};
        auto n = static_cast<MidiClipPlayer&>(*node).notes();  // the kind registered at `id`
        return {n.begin(), n.end()};
    };

    const std::vector<NoteDesc> fixtureNotes = {note(3840, 480, 60, 100, 0, 2), note(4320, 480, 64, 80, 1, 2),
                                                note(5520, 240, 67, 100, 0, 2)};
    auto graph = builder.build(midiTrackGraph(1, fixtureNotes), engine.nodes(), engine.params());
    DAW_CHECK(graph.ok());
    if (!graph.ok()) return checks;
    engine.publish(std::move(graph).value());
    auto notes = playerNotes(2);
    DAW_CHECK(notes.size() == 3 && notes[0].pitch == 60 && notes[1].channel == 1 && notes[2].start == 5520);
    DAW_CHECK(playerNotes(5).size() == 1);

    // Renders through the Engine (MIDI isn't routed yet, so the player writes into an empty
    // writer) with 0 RT violations, across the tempo change.
    std::vector<float> l(512), r(512);
    float* ptrs[2] = {l.data(), r.data()};
    RenderTarget target;
    target.output = AudioBufferView{ptrs, 2, 512};
    DAW_CHECK(engine.transport().locate(0) && engine.transport().play());
    uint64_t violations = 0;
    for (int i = 0; i < 1000; ++i) {
        if (i == 400) DAW_CHECK(engine.transport().locate(3900));
        if (i == 700) DAW_CHECK(engine.transport().stop());
        RtScope scope;
        engine.render(target, 512);
        violations += scope.violations();
    }
    DAW_CHECK(violations == 0);

    // DW-051: notes are fixed per instance. A note edit without a configVersion bump keeps the
    // instance (and its notes); with the bump the player is re-created with the new ones.
    const std::shared_ptr<Node> before = engine.nodes().get(2);
    const std::vector<NoteDesc> edited = {note(0, 10, 61, 100, 0, 2)};
    auto same = builder.build(midiTrackGraph(1, edited), engine.nodes(), engine.params());
    DAW_CHECK(same.ok() && engine.nodes().get(2) == before && playerNotes(2).size() == 3);
    if (same.ok()) engine.publish(std::move(same).value());
    auto bumped = builder.build(midiTrackGraph(2, edited), engine.nodes(), engine.params());
    DAW_CHECK(bumped.ok() && engine.nodes().get(2) != before);
    notes = playerNotes(2);
    DAW_CHECK(notes.size() == 1 && notes[0].pitch == 61);
    if (bumped.ok()) engine.publish(std::move(bumped).value());

    // MIDI only: an audio edge out of the player is rejected.
    GraphDescription audioOut = midiTrackGraph(2, edited);
    audioOut.edges.push_back(EdgeDesc{9, 2, 1, EdgeKind::audio, 0});
    auto rejected = builder.build(audioOut, engine.nodes(), engine.params());
    DAW_CHECK(!rejected.ok() && rejected.error().code == ErrorCode::invalidArgument);
    return checks;
}

} // namespace daw::testing
