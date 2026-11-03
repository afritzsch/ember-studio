// T-045 checks for MIDI edge routing (DW-099). Run from Tests/DAWEngineTests/MidiRoutingTests.swift;
// see MidiRoutingChecks.h for why they're C++.

#include "MidiRoutingChecks.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <complex>
#include <cstring>
#include <memory>
#include <numbers>
#include <random>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "ExportTestSupport.h"
#include "NodeTestHarness.h"
#include "TestAudio.h"
#include "TestNodes.h"
#include "core/Engine.h"
#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ProcessContext.h"
#include "core/Realtime.h"
#include "core/RenderGraph.h"
#include "core/RtTrap.h"
#include "daw/EngineFacade.h"
#include "daw/GraphDescription.h"
#include "graph/GraphBuilder.h"
#include "graph/NodeRegistry.h"

using namespace daw;
using namespace daw::testing::nodes;
using namespace std::chrono_literals;

namespace daw::testing {

namespace {

// MARK: MidiProbe

// An instrument stand-in (registered under NodeKind::sampler). It records every event of its
// midiIn with the absolute frame it arrived at (frames processed since prepare + frameOffset),
// keeps the last block's midiIn, counts held notes per channel and key (CC 123 clears a
// channel; an off with nothing held is a stray), and writes audio: channel 0 passes its main
// input's channel 0, channel 1 is 1.0 on the frame of every note-on. All storage is
// preallocated; process() is RT.
class MidiProbe final : public Node {
public:
    struct Record {
        uint64_t frame;
        MidiEvent event;
    };
    static constexpr std::size_t kMaxRecords = 1u << 20;
    static constexpr std::size_t kMaxBlockEvents = 1u << 14;

    MidiProbe() : records_(kMaxRecords), last_(kMaxBlockEvents), held_(16 * 128, 0) {}

    void prepare(const PrepareInfo&) override {}

    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        lastInData_ = io.midiIn.data();
        numLast_ = 0;
        uint32_t prev = 0;
        for (const MidiEvent& e : io.midiIn) {
            if (e.frameOffset < prev || (ctx.numFrames > 0 && e.frameOffset >= ctx.numFrames)) ++disorder_;
            prev = e.frameOffset;
            if (numLast_ < last_.size()) last_[numLast_++] = e;
            if (numRecords_ < records_.size()) records_[numRecords_++] = Record{frame_ + e.frameOffset, e};
            else ++overflow_;
            const uint8_t status = e.data[0] & 0xF0, channel = e.data[0] & 0x0F;
            const std::size_t key = std::size_t{channel} * 128 + (e.data[1] & 0x7F);
            if (status == 0x90 && e.data[2] > 0) {
                ++held_[key];
                ++ons_;
            } else if (status == 0x80 || status == 0x90) {
                if (held_[key] > 0) --held_[key];
                else ++strays_;
            } else if (status == 0xB0 && e.data[1] == 123) {
                for (std::size_t k = 0; k < 128; ++k) held_[std::size_t{channel} * 128 + k] = 0;
            }
        }
        const AudioBufferView& out = io.audioOut;
        for (uint32_t c = 0; c < out.numChannels; ++c)
            std::memset(out.channels[c], 0, std::size_t{out.numFrames} * sizeof(float));
        if (out.numChannels >= 2) {
            if (io.audioIn.numChannels > 0)
                std::memcpy(out.channels[0], io.audioIn.channels[0], std::size_t{out.numFrames} * sizeof(float));
            for (const MidiEvent& e : io.midiIn)
                if ((e.data[0] & 0xF0) == 0x90 && e.data[2] > 0 && e.frameOffset < out.numFrames)
                    out.channels[1][e.frameOffset] = 1.0f;
        }
        frame_ += ctx.numFrames;
    }

    // Test thread, between renders.
    std::vector<Record> records() const { return {records_.begin(), records_.begin() + numRecords_}; }
    std::vector<MidiEvent> lastBlock() const { return {last_.begin(), last_.begin() + numLast_}; }
    const MidiEvent* lastInData() const { return lastInData_; }
    uint32_t heldNotes() const {
        uint32_t n = 0;
        for (uint32_t h : held_) n += h;
        return n;
    }
    uint64_t strays() const { return strays_; }
    uint64_t disorder() const { return disorder_; }
    uint64_t overflow() const { return overflow_; }
    uint64_t ons() const { return ons_; }

private:
    std::vector<Record> records_;
    std::size_t numRecords_ = 0;
    std::vector<MidiEvent> last_;
    std::size_t numLast_ = 0;
    const MidiEvent* lastInData_ = nullptr;
    std::vector<uint32_t> held_;
    uint64_t strays_ = 0, disorder_ = 0, overflow_ = 0, ons_ = 0;
    uint64_t frame_ = 0;
};

void registerProbe(NodeRegistry& registry) {
    (void)registry.set(NodeKind::sampler, {[](const NodeCreateInfo&) -> Result<std::unique_ptr<Node>> {
        return std::unique_ptr<Node>(new MidiProbe);
    }});
}

MidiProbe* probe(Rig& rig, NodeID id) {
    auto node = rig.engine().nodes().get(id);
    return static_cast<MidiProbe*>(node.get());  // only probes are registered as samplers here
}

// The step that renders node `id` in `graph`, or numSteps().
uint32_t stepOf(Rig& rig, const RenderGraph& graph, NodeID id) {
    auto node = rig.engine().nodes().get(id);
    for (uint32_t s = 0; s < graph.numSteps(); ++s)
        if (graph.node(s) == node.get()) return s;
    return graph.numSteps();
}

NodeDesc nodeDesc(NodeID id, NodeKind kind, uint32_t configVersion = 1) {
    return NodeDesc{id, kind, configVersion, 0, 0, {}};
}

bool isNoteOn(const MidiEvent& e) { return (e.data[0] & 0xF0) == 0x90 && e.data[2] > 0; }
bool isNoteOff(const MidiEvent& e) {
    return (e.data[0] & 0xF0) == 0x80 || ((e.data[0] & 0xF0) == 0x90 && e.data[2] == 0);
}
bool sameEvent(const MidiEvent& a, const MidiEvent& b) {
    return a.frameOffset == b.frameOffset && a.size == b.size && std::memcmp(a.data, b.data, 3) == 0;
}

// Publishes `desc` and returns the graph (owned by the engine from then on), or null.
const RenderGraph* publish(Rig& rig, const GraphDescription& desc) {
    auto built = rig.build(desc);
    if (!built) return nullptr;
    const RenderGraph* graph = built.value().get();
    rig.engine().publish(std::move(built).value());
    return graph;
}

// MARK: Facade helpers

template <class F>
bool eventually(F done, std::chrono::milliseconds timeout = 5000ms) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (!done()) {
        if (std::chrono::steady_clock::now() > deadline) return false;
        std::this_thread::sleep_for(1ms);
    }
    return true;
}

// Radix-2 FFT, in place (as in SamplerChecks.cpp).
void fft(std::vector<std::complex<double>>& a) {
    const size_t n = a.size();
    for (size_t i = 1, j = 0; i < n; ++i) {
        size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std::swap(a[i], a[j]);
    }
    for (size_t len = 2; len <= n; len <<= 1) {
        const double angle = -2.0 * std::numbers::pi / static_cast<double>(len);
        const std::complex<double> wl(std::cos(angle), std::sin(angle));
        for (size_t i = 0; i < n; i += len) {
            std::complex<double> w(1.0);
            for (size_t k = 0; k < len / 2; ++k, w *= wl) {
                const auto u = a[i + k], v = a[i + k + len / 2] * w;
                a[i + k] = u + v;
                a[i + k + len / 2] = u - v;
            }
        }
    }
}

// The strongest frequency in x[offset, offset + n) (n a power of two), Hann window plus a
// parabolic peak fit on log magnitudes.
double peakFrequency(const std::vector<float>& x, size_t offset, size_t n, double rate) {
    std::vector<std::complex<double>> a(n);
    for (size_t i = 0; i < n; ++i) {
        const double w = 0.5 - 0.5 * std::cos(2.0 * std::numbers::pi * static_cast<double>(i) / static_cast<double>(n));
        a[i] = w * x[offset + i];
    }
    fft(a);
    size_t peak = 1;
    for (size_t k = 1; k < n / 2; ++k)
        if (std::abs(a[k]) > std::abs(a[peak])) peak = k;
    const double l = std::log(std::abs(a[peak - 1])), c = std::log(std::abs(a[peak])), r = std::log(std::abs(a[peak + 1]));
    const double delta = 0.5 * (l - r) / (l - 2.0 * c + r);
    return (static_cast<double>(peak) + delta) * rate / static_cast<double>(n);
}

double rms(const std::vector<float>& x, size_t from, size_t to) {
    double sum = 0;
    for (size_t i = from; i < to; ++i) sum += double{x[i]} * x[i];
    return to > from ? std::sqrt(sum / static_cast<double>(to - from)) : 0.0;
}

} // namespace

// MARK: Player → instrument

CheckResult midiRoutingPlayerToInstrument() {
    CheckResult checks;
    Rig rig(registerProbe);
    // master 1 ← probe 3 ← player 2 → probe 4 → master (fan-out).
    GraphDescription d = baseDescription();
    d.nodes.push_back(nodeDesc(2, NodeKind::midiClipPlayer));
    d.nodes.push_back(nodeDesc(3, NodeKind::sampler));
    d.nodes.push_back(nodeDesc(4, NodeKind::sampler));
    d.edges.push_back(EdgeDesc{10, 2, 3, EdgeKind::midi, 0});
    d.edges.push_back(EdgeDesc{11, 3, 1, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{12, 2, 4, EdgeKind::midi, 0});
    d.edges.push_back(EdgeDesc{13, 4, 1, EdgeKind::audio, 0});
    struct N { Tick start, length; uint8_t pitch, velocity, channel; };
    const std::vector<N> notes = {{0, 480, 60, 100, 0}, {100, 50, 64, 90, 1}, {480, 480, 62, 80, 0},
                                  {1000, 7, 67, 127, 15}, {1913, 1000, 72, 1, 3}};
    for (const N& n : notes) d.notes.push_back(NoteDesc{2, n.start, n.length, n.pitch, n.velocity, n.channel});

    const RenderGraph* graph = publish(rig, d);
    DAW_CHECK(graph != nullptr);
    if (!graph) return checks;
    const uint32_t playerStep = stepOf(rig, *graph, 2), probeStep = stepOf(rig, *graph, 3);
    DAW_CHECK(playerStep < graph->numSteps() && probeStep < graph->numSteps());
    if (playerStep >= graph->numSteps() || probeStep >= graph->numSteps()) return checks;
    DAW_CHECK(graph->midiCapacity(playerStep) == GraphBuilder::kMidiCapacity);
    DAW_CHECK(graph->midiCapacity(probeStep) == 0);  // no outgoing MIDI edge

    DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
    std::mt19937 rng(45);
    std::uniform_int_distribution<uint32_t> block(0, 1500);
    rig.renderFrames(3000 * kSamplesPerTick, [&] { return block(rng); });
    DAW_CHECK(rig.violations() == 0);

    // The instrument reads the player's own storage: no copy for a single undelayed edge.
    MidiProbe* a = probe(rig, 3);
    MidiProbe* b = probe(rig, 4);
    DAW_CHECK(a->lastInData() == graph->midiOutput(playerStep).data());
    DAW_CHECK(b->lastInData() == graph->midiOutput(playerStep).data());

    // Expected: CC 123 on all channels at frame 0 (a new instance, DSP-003), then every on and
    // off at its tick's sample, offs before ons on a tie.
    struct Expect { uint64_t frame; MidiEvent event; };
    std::vector<Expect> expected;
    for (uint8_t ch = 0; ch < 16; ++ch) expected.push_back({0, MidiEvent{0, 3, {uint8_t(0xB0 | ch), 123, 0}}});
    std::vector<Expect> notesExpected;
    for (const N& n : notes) {
        notesExpected.push_back({uint64_t(n.start * kSamplesPerTick), MidiEvent{0, 3, {uint8_t(0x90 | n.channel), n.pitch, n.velocity}}});
        notesExpected.push_back({uint64_t((n.start + n.length) * kSamplesPerTick), MidiEvent{0, 3, {uint8_t(0x80 | n.channel), n.pitch, 64}}});
    }
    std::stable_sort(notesExpected.begin(), notesExpected.end(), [](const Expect& x, const Expect& y) {
        if (x.frame != y.frame) return x.frame < y.frame;
        return isNoteOff(x.event) && !isNoteOff(y.event);
    });
    expected.insert(expected.end(), notesExpected.begin(), notesExpected.end());
    for (MidiProbe* p : {a, b}) {
        const auto got = p->records();
        DAW_CHECK(got.size() == expected.size());
        bool same = got.size() == expected.size();
        for (size_t i = 0; same && i < got.size(); ++i)
            same = got[i].frame == expected[i].frame && got[i].event.size == 3 &&
                   std::memcmp(got[i].event.data, expected[i].event.data, 3) == 0;
        DAW_CHECK(same);
        DAW_CHECK(p->disorder() == 0 && p->strays() == 0 && p->heldNotes() == 0);
    }
    return checks;
}

// MARK: Merge

CheckResult midiRoutingMergesInFrameOrder() {
    CheckResult checks;
    for (int order = 0; order < 2; ++order) {
        Rig rig(registerProbe);
        GraphDescription d = baseDescription();
        d.nodes.push_back(nodeDesc(2, NodeKind::midiClipPlayer));
        d.nodes.push_back(nodeDesc(3, NodeKind::midiClipPlayer));
        d.nodes.push_back(nodeDesc(4, NodeKind::sampler));
        const EdgeDesc fromA{10, 2, 4, EdgeKind::midi, 0}, fromB{11, 3, 4, EdgeKind::midi, 0};
        d.edges.push_back(order == 0 ? fromA : fromB);
        d.edges.push_back(order == 0 ? fromB : fromA);
        d.edges.push_back(EdgeDesc{12, 4, 1, EdgeKind::audio, 0});
        // Random notes on a coarse grid, so the two players often share frames. None at tick 0:
        // there each new player's CC 123 would end the other's notes (MIDI 1.0, per channel).
        std::mt19937 rng(4500 + order);
        std::uniform_int_distribution<int> grid(1, 400), len(1, 40), pitch(0, 127), ch(0, 15);
        for (NodeID player : {NodeID{2}, NodeID{3}})
            for (int i = 0; i < 300; ++i)
                d.notes.push_back(NoteDesc{player, Tick{grid(rng)} * 10, Tick{len(rng)} * 10,
                                           uint8_t(pitch(rng)), 100, uint8_t(ch(rng))});

        const RenderGraph* graph = publish(rig, d);
        DAW_CHECK(graph != nullptr);
        if (!graph) return checks;
        const uint32_t stepA = stepOf(rig, *graph, 2), stepB = stepOf(rig, *graph, 3);
        DAW_CHECK(stepA < graph->numSteps() && stepB < graph->numSteps());
        if (stepA >= graph->numSteps() || stepB >= graph->numSteps()) return checks;
        MidiProbe* p = probe(rig, 4);

        DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
        std::uniform_int_distribution<uint32_t> block(0, 4096);
        uint64_t total = 0, ties = 0;
        bool allMatch = true;
        for (int64_t done = 0; done < 4500 * kSamplesPerTick;) {
            const uint32_t n = block(rng);
            rig.render(n);
            done += n;
            // The first edge in the description wins ties (std::merge is stable).
            const MidiEventSpan first = graph->midiOutput(order == 0 ? stepA : stepB);
            const MidiEventSpan second = graph->midiOutput(order == 0 ? stepB : stepA);
            std::vector<MidiEvent> expect(first.size() + second.size());
            std::merge(first.begin(), first.end(), second.begin(), second.end(), expect.begin(),
                       [](const MidiEvent& x, const MidiEvent& y) { return x.frameOffset < y.frameOffset; });
            const auto got = p->lastBlock();
            bool match = got.size() == expect.size();
            for (size_t i = 0; match && i < got.size(); ++i) match = sameEvent(got[i], expect[i]);
            allMatch = allMatch && match;
            total += got.size();
            for (const MidiEvent& x : first)
                for (const MidiEvent& y : second)
                    if (x.frameOffset == y.frameOffset && std::memcmp(x.data, y.data, 3) != 0) ++ties;
        }
        DAW_CHECK(allMatch);
        DAW_CHECK(rig.violations() == 0);
        DAW_CHECK(ties > 0);           // the tie order was actually exercised
        DAW_CHECK(total >= 2 * 2 * 300);  // every note of both players: on + off
        DAW_CHECK(p->disorder() == 0 && p->strays() == 0 && p->heldNotes() == 0);
    }
    return checks;
}

// MARK: No hanging notes across snapshot swaps

CheckResult midiRoutingNoHangingNotesAcrossSwaps() {
    CheckResult checks;
    Rig rig(registerProbe);
    std::mt19937 rng(450);
    // 20000 notes over 4000 ticks: thousands held at once, far more than one block's writer.
    auto describe = [&](uint64_t version, uint32_t configVersion) {
        GraphDescription d = baseDescription();
        d.version = version;
        d.nodes.push_back(nodeDesc(2, NodeKind::midiClipPlayer, configVersion));
        d.nodes.push_back(nodeDesc(3, NodeKind::sampler));
        d.edges.push_back(EdgeDesc{10, 2, 3, EdgeKind::midi, 0});
        d.edges.push_back(EdgeDesc{11, 3, 1, EdgeKind::audio, 0});
        std::mt19937 notes(7);
        std::uniform_int_distribution<int> start(0, 4000), len(1, 300), pitch(0, 127), ch(0, 15);
        for (int i = 0; i < 20000; ++i)
            d.notes.push_back(NoteDesc{2, start(notes), len(notes), uint8_t(pitch(notes)), 100, uint8_t(ch(notes))});
        return d;
    };
    uint64_t version = 1;
    uint32_t configVersion = 1;
    const RenderGraph* graph = publish(rig, describe(version, configVersion));
    DAW_CHECK(graph != nullptr);
    DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
    std::uniform_int_distribution<uint32_t> block(0, 4096);
    std::uniform_int_distribution<int> roll(0, 99), tick(0, 4200);
    bool capacityFixed = true;
    int swaps = 0, recreated = 0;
    for (int i = 0; i < 1500; ++i) {
        const int r = roll(rng);
        if (r < 15) {
            // A rebuild: same instance unless configVersion bumps (then CC 123 from the new one).
            if (r < 2) {
                ++configVersion;
                ++recreated;
            }
            graph = publish(rig, describe(++version, configVersion));
            DAW_CHECK(graph != nullptr);
            if (graph) {
                const uint32_t s = stepOf(rig, *graph, 2);
                capacityFixed = capacityFixed && s < graph->numSteps() &&
                                graph->midiCapacity(s) == GraphBuilder::kMidiCapacity;
            }
            ++swaps;
        } else if (r < 20) {
            DAW_CHECK(rig.transport().locate(tick(rng)));
        } else if (r < 23) {
            DAW_CHECK(rig.transport().stop());
        } else if (r < 28) {
            DAW_CHECK(rig.transport().play());
        } else if (r < 30) {
            const Tick a = tick(rng);
            DAW_CHECK(rig.transport().setLoop(roll(rng) < 50, a, a + 1 + tick(rng) / 4));
        }
        rig.render(block(rng));
        rig.clearOutput();
    }
    DAW_CHECK(swaps > 50 && recreated > 0);
    DAW_CHECK(capacityFixed);
    DAW_CHECK(rig.transport().stop());
    rig.render(256);
    DAW_CHECK(rig.violations() == 0);
    MidiProbe* p = probe(rig, 3);
    DAW_CHECK(p->disorder() == 0);
    DAW_CHECK(p->strays() == 0);     // no off without its on
    DAW_CHECK(p->heldNotes() == 0);  // nothing hangs after a stop
    DAW_CHECK(p->ons() > 0);
    return checks;
}

// MARK: PDC

namespace {

// master 1 ← probe 5 ←audio— latency 3 (1000) ←audio— clip player 2 (impulse at tick 1920)
//                    ←midi—  player 4 (note at tick 1920)
GraphDescription pdcGraph(uint64_t version, uint64_t midiEdgeID) {
    GraphDescription d = baseDescription();
    d.version = version;
    d.nodes.push_back(nodeDesc(2, NodeKind::audioClipPlayer));
    d.nodes.push_back(nodeDesc(3, NodeKind::eq));
    d.nodes.push_back(nodeDesc(4, NodeKind::midiClipPlayer));
    d.nodes.push_back(nodeDesc(5, NodeKind::sampler));
    d.edges.push_back(EdgeDesc{10, 2, 3, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{11, 3, 5, EdgeKind::audio, 0});
    d.edges.push_back(EdgeDesc{midiEdgeID, 4, 5, EdgeKind::midi, 0});
    d.edges.push_back(EdgeDesc{13, 5, 1, EdgeKind::audio, 0});
    d.audioClips.push_back(clip(2, 20, 1920, 480, 7));
    d.notes.push_back(NoteDesc{4, 1920, 480, 60, 100, 0});
    return d;
}

void registerPdcNodes(NodeRegistry& registry) {
    registerProbe(registry);
    (void)registry.set(NodeKind::eq, {[](const NodeCreateInfo&) -> Result<std::unique_ptr<Node>> {
        return std::unique_ptr<Node>(new FakeLatencyNode(1000));
    }});
}

// Renders 2.5 s of pdcGraph in 500-frame blocks; `rebuildEdge` (0: none) republishes with that
// MIDI edge ID once the note-on is in flight (output frame 47500, the player emitted it at 47000).
std::vector<float> renderPdc(CheckResult& checks, uint64_t rebuildEdge) {
    Rig rig(registerPdcNodes);
    rig.addAsset(makeAsset(7, 1, 100, [](uint32_t, int64_t i) { return i == 0 ? 1.0f : 0.0f; }));
    DAW_CHECK(publish(rig, pdcGraph(1, 12)) != nullptr);
    DAW_CHECK(rig.transport().locate(0) && rig.transport().play());
    for (int b = 0; b < 240; ++b) {
        if (b == 95 && rebuildEdge != 0) DAW_CHECK(publish(rig, pdcGraph(2, rebuildEdge)) != nullptr);
        rig.render(500);
    }
    DAW_CHECK(rig.violations() == 0);
    std::vector<float> out = rig.left();
    out.insert(out.end(), rig.right().begin(), rig.right().end());  // left then right
    return out;
}

} // namespace

CheckResult midiRoutingPdcDelaysMidiEdges() {
    CheckResult checks;
    {
        Rig rig(registerPdcNodes);
        auto graph = rig.build(pdcGraph(1, 12));
        DAW_CHECK(graph.ok() && graph.value()->latency() == 1000);
    }
    const std::vector<float> plain = renderPdc(checks, 0);
    const size_t n = plain.size() / 2;
    DAW_CHECK(n == 120000);
    if (n != 120000) return checks;
    auto hits = [&](const std::vector<float>& x, size_t channel) {
        std::vector<size_t> at;
        for (size_t i = 0; i < n; ++i)
            if (x[channel * n + i] != 0.0f) at.push_back(i);
        return at;
    };
    // Both arrive at the instrument on the same frame and leave at the timeline sample (MIX-023):
    // tick 1920 = sample 48000. Without the MIDI delay the note would be 1000 frames early.
    DAW_CHECK(hits(plain, 0) == std::vector<size_t>{48000});
    DAW_CHECK(hits(plain, 1) == std::vector<size_t>{48000});

    // MIX-022 for MIDI: the in-flight note-on survives a rebuild with the same edge ID...
    const std::vector<float> rebuilt = renderPdc(checks, 12);
    DAW_CHECK(rebuilt == plain);
    // ...and is lost with a new one (a new, empty line), which shows the carry-over is real.
    const std::vector<float> fresh = renderPdc(checks, 99);
    DAW_CHECK(hits(fresh, 0) == std::vector<size_t>{48000});
    DAW_CHECK(hits(fresh, 1).empty());
    return checks;
}

// MARK: MidiDelayLine

namespace {

MidiEvent ev(uint32_t frame, uint8_t status, uint8_t d1, uint8_t d2) { return MidiEvent{frame, 3, {status, d1, d2}}; }

// Runs one block through `line` inside an RtScope and returns the output with absolute frames.
struct LineRun {
    explicit LineRun(MidiDelayLine& l) : line(l) {}
    MidiDelayLine& line;
    uint64_t now = 0;
    uint64_t violations = 0;
    std::vector<std::pair<uint64_t, MidiEvent>> out;

    void block(const std::vector<MidiEvent>& in, uint32_t delay, uint32_t numFrames) {
        MidiEventSpan got;
        {
            RtScope scope;
            got = line.process(MidiEventSpan(in.data(), in.size()), delay, numFrames);
            violations += scope.violations();
        }
        for (const MidiEvent& e : got) out.emplace_back(now + e.frameOffset, e);
        now += numFrames;
    }
};

} // namespace

CheckResult midiDelayLineSemantics() {
    CheckResult checks;
    std::mt19937 rng(4545);

    // Exact delay in random block sizes; pitch bends (no reserve involved), each with an id.
    {
        MidiDelayLine line(4096, 1024);
        LineRun run(line);
        std::vector<std::pair<uint64_t, uint32_t>> sent;  // (frame + delay, id)
        std::uniform_int_distribution<uint32_t> size(0, 600), count(0, 5);
        uint32_t id = 0;
        for (int b = 0; b < 2000; ++b) {
            const uint32_t n = size(rng);
            std::vector<MidiEvent> in;
            if (n > 0) {
                std::uniform_int_distribution<uint32_t> at(0, n - 1);
                std::vector<uint32_t> frames(count(rng));
                for (auto& f : frames) f = at(rng);
                std::sort(frames.begin(), frames.end());
                for (uint32_t f : frames) {
                    in.push_back(ev(f, 0xE0, uint8_t(id & 0x7F), uint8_t((id >> 7) & 0x7F)));
                    sent.emplace_back(run.now + f + 777, id++);
                }
            }
            run.block(in, 777, n);
        }
        run.block({}, 777, 4096);
        DAW_CHECK(run.violations == 0);
        DAW_CHECK(run.out.size() == sent.size());
        bool exact = run.out.size() == sent.size();
        for (size_t i = 0; exact && i < sent.size(); ++i)
            exact = run.out[i].first == sent[i].first &&
                    (run.out[i].second.data[1] | (uint32_t(run.out[i].second.data[2]) << 7)) == (sent[i].second & 0x3FFF);
        DAW_CHECK(exact);
        DAW_CHECK(line.dropped() == 0 && line.queued() == 0);
    }

    // Delay changes: shrinking and growing keep order and lose nothing.
    {
        MidiDelayLine line(4096, 1024);
        LineRun run(line);
        uint32_t id = 0;
        const uint32_t delays[] = {500, 100, 0, 2000, 1};
        for (uint32_t delay : delays)
            for (int b = 0; b < 20; ++b) {
                std::vector<MidiEvent> in;
                for (uint32_t f = 0; f < 64; f += 16) in.push_back(ev(f, 0xE0, uint8_t(id++ & 0x7F), 0));
                run.block(in, delay, 64);
            }
        for (int b = 0; b < 40; ++b) run.block({}, 1, 128);
        DAW_CHECK(run.violations == 0 && run.out.size() == id);
        bool ordered = true;
        for (size_t i = 0; i < run.out.size(); ++i) {
            ordered = ordered && run.out[i].second.data[1] == (i & 0x7F);
            if (i > 0) ordered = ordered && run.out[i].first >= run.out[i - 1].first;
        }
        DAW_CHECK(ordered);
    }

    // maxOut: at most 4 per block, the rest late (frame 0 onwards) and in order.
    {
        MidiDelayLine line(64, 4);
        LineRun run(line);
        std::vector<MidiEvent> in;
        for (uint8_t i = 0; i < 10; ++i) in.push_back(ev(10, 0xE0, i, 0));
        run.block(in, 0, 100);
        DAW_CHECK(run.out.size() == 4);
        run.block({}, 0, 100);
        run.block({}, 0, 100);
        DAW_CHECK(run.out.size() == 10);
        bool ok = run.out.size() == 10;
        for (size_t i = 0; ok && i < 10; ++i) ok = run.out[i].second.data[1] == i;
        DAW_CHECK(ok);
        DAW_CHECK(run.out.size() == 10 && run.out[3].first == 10 && run.out[4].first == 100 && run.out[8].first == 200);
    }

    // Overflow: capacity 16 and a long delay. Ons go in only with room for their offs.
    {
        MidiDelayLine line(16, 64);
        LineRun run(line);
        std::vector<MidiEvent> ons;
        for (uint8_t k = 0; k < 12; ++k) ons.push_back(ev(0, 0x90, k, 100));
        run.block(ons, 10000, 10);
        DAW_CHECK(line.queued() == 8 && line.reserved() == 8 && line.dropped() == 4);
        run.block({ev(0, 0xE0, 0, 64)}, 10000, 10);  // would eat the reserve: dropped
        DAW_CHECK(line.dropped() == 5);
        std::vector<MidiEvent> offs;
        for (uint8_t k = 0; k < 12; ++k) offs.push_back(ev(0, 0x80, k, 64));
        run.block(offs, 10000, 10);
        DAW_CHECK(line.queued() == 16 && line.reserved() == 0 && line.dropped() == 9);  // offs of dropped ons go too
        for (int b = 0; b < 4; ++b) run.block({}, 10000, 4096);
        DAW_CHECK(run.violations == 0 && run.out.size() == 16);
        bool paired = run.out.size() == 16;
        for (size_t i = 0; paired && i < 8; ++i)
            paired = isNoteOn(run.out[i].second) && run.out[i].second.data[1] == i &&
                     isNoteOff(run.out[8 + i].second) && run.out[8 + i].second.data[1] == i;
        DAW_CHECK(paired);
    }

    // A note-on with velocity 0 is an off; pedal down reserves its up; CC 123 frees the reserve.
    {
        MidiDelayLine line(16, 64);
        LineRun run(line);
        run.block({ev(0, 0x91, 60, 100), ev(1, 0x91, 60, 0)}, 5000, 10);
        DAW_CHECK(line.reserved() == 0 && line.queued() == 2);
        run.block({ev(0, 0xB2, 64, 127)}, 5000, 10);
        DAW_CHECK(line.reserved() == 1);
        std::vector<MidiEvent> ons;
        for (uint8_t k = 0; k < 6; ++k) ons.push_back(ev(0, 0x92, k, 100));
        run.block(ons, 5000, 10);
        DAW_CHECK(line.queued() == 9 && line.reserved() == 7);
        run.block({ev(0, 0xB2, 123, 0)}, 5000, 10);  // the channel's notes end: 6 fewer reserved
        DAW_CHECK(line.queued() == 10 && line.reserved() == 1);
        run.block({ev(0, 0xB2, 64, 0)}, 5000, 10);
        DAW_CHECK(line.queued() == 11 && line.reserved() == 0 && line.dropped() == 0);
        for (int b = 0; b < 3; ++b) run.block({}, 5000, 4096);
        DAW_CHECK(run.violations == 0 && run.out.size() == 11 && line.queued() == 0);
    }
    return checks;
}

// MARK: End to end through the facade

CheckResult midiTrackWithSamplerThroughFacade() {
    CheckResult checks;
    constexpr double rate = 48000.0;
    TempDir dir;
    DriverConfigPOD config;
    config.sampleRate = rate;
    EngineFacade* facade = EngineFacade::create(EngineMode::offline, config);
    DAW_CHECK(facade != nullptr);
    if (!facade) return checks;
    struct Release {
        EngineFacade* f;
        ~Release() { releaseFacade(f); }
    } release{facade};

    // Two seconds of a 440 Hz sine, mono (the sampler zone's asset).
    std::vector<float> sine(2 * 48000);
    for (size_t i = 0; i < sine.size(); ++i)
        sine[i] = 0.5f * static_cast<float>(std::sin(2.0 * std::numbers::pi * 440.0 * static_cast<double>(i) / rate));
    const auto file = dir.path() / "sine440.wav";
    DAW_CHECK(writeTestFile(file, "wav-f32", rate, Channels{sine}).ok());
    const JobID load = facade->loadAsset(7, file.string());
    JobStatus loaded;
    DAW_CHECK(eventually([&] {
        loaded = facade->pollJob(load);
        return loaded.state == JobState::succeeded || loaded.state == JobState::failed;
    }));
    DAW_CHECK(loaded.state == JobState::succeeded);

    const ParamID strip = facade->allocateParams(4);
    facade->setParam(strip + 0, 1.0f);  // gain
    facade->setParam(strip + 1, 0.0f);  // pan centre
    // master 1 ← strip 4 ← sampler 3 ←midi— player 2: A5 (81) on an A4-rooted zone, beat 2..4.
    GraphDescriptionBuilder b;
    b.addNode(1, NodeKind::master, 1, 0, 0, "");
    b.addNode(2, NodeKind::midiClipPlayer, 1, 0, 0, "");
    b.addNode(3, NodeKind::sampler, 1, 0, 0, R"({"zones": [{"assetID": 7, "rootKey": 69}]})");
    b.addNode(4, NodeKind::channelStrip, 1, strip, 4, "");
    b.addEdge(10, 2, 3, EdgeKind::midi, 0);
    b.addEdge(11, 3, 4, EdgeKind::audio, 0);
    b.addEdge(12, 4, 1, EdgeKind::audio, 0);
    b.addNote(2, kPPQ, 2 * kPPQ, 81, 127, 0);  // 0.5 s .. 1.5 s at 120 bpm
    b.setTempo(0, 120.0);
    b.setTimeSignature(0, 4, 4);
    b.setMaster(1);
    const uint64_t version = facade->applyGraph(b.description());
    const GraphStatusPOD status = facade->waitForGraph(version, 5000);
    DAW_CHECK(status.publishedVersion == version && status.lastError.ok());

    ExportSpecPOD spec;
    spec.path = (dir.path() / "out.wav").string();
    spec.tailEnabled = false;
    const JobID job = facade->renderOffline(0, 4 * kPPQ, spec);  // 2 s
    JobStatus done;
    DAW_CHECK(eventually([&] {
        done = facade->pollJob(job);
        return done.state == JobState::succeeded || done.state == JobState::failed;
    }, 20000ms));
    DAW_CHECK(done.state == JobState::succeeded);
    DAW_CHECK(done.render.rtViolations == 0);

    auto back = readBack(spec.path, rate);
    DAW_CHECK(back.ok());
    if (!back || back->size() != 2 || (*back)[0].size() != 96000) {
        DAW_CHECK(false);
        return checks;
    }
    const auto& left = (*back)[0];
    DAW_CHECK(rms(left, 0, 23000) == 0.0);          // before the note
    DAW_CHECK(rms(left, 26000, 70000) > 0.1);        // the note sounds
    DAW_CHECK(std::abs(peakFrequency(left, 30000, 32768, rate) - 880.0) <= 1.0);  // A5 = 2 × A4
    DAW_CHECK(rms(left, 90000, 96000) < 1e-4);       // released (0.2 s) after 1.5 s
    return checks;
}

} // namespace daw::testing
