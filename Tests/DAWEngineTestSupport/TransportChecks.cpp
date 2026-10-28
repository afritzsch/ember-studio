// T-008 checks for Transport, TransportBlock segments, TransportSegments.h and the playhead. Run
// from Tests/DAWEngineTests/TransportTests.swift; see TransportChecks.h for why they're C++.

#include "TransportChecks.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <random>
#include <thread>
#include <utility>
#include <vector>

#include "core/AudioBufferPool.h"
#include "core/Engine.h"
#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ProcessContext.h"
#include "core/Realtime.h"
#include "core/RenderGraph.h"
#include "core/RtTrap.h"
#include "time/TempoMap.h"
#include "time/Transport.h"
#include "time/TransportBlock.h"
#include "time/TransportSegments.h"

using namespace daw;

namespace daw::testing {

namespace {

// MARK: Harness

constexpr PrepareInfo kInfo{48000.0, kMaxBlock, 2, 2};

TempoMap makeMap(const TempoEventList& tempos, const TimeSigEventList& sigs = {{0, 4, 4}},
                 double sampleRate = 48000.0) {
    return std::move(TempoMap::make(tempos, sigs, sampleRate)).value();
}

// Runs the RT side of the transport inside its own RtScope and keeps that scope's count.
struct RtAdvance {
    uint64_t violations = 0;

    const TransportBlock& operator()(Transport& transport, const TempoMap& tempo, uint32_t n) {
        RtScope scope;
        const TransportBlock& block = transport.advance(tempo, n);
        // Read through the node helpers in the same scope, so they're covered too.
        if (block.numSegments > 0) {
            volatile Tick sink = blockStartTick(block) + segmentFrames(block);
            volatile double bpm = tempoAtStart(block);
            (void)sink;
            (void)bpm;
        }
        violations += scope.violations();
        return block;
    }
};

// Independent model of the timeline, one frame at a time: the sample each played frame shows
// and whether the loop wrapped right before it. A wrap happens only when playback reaches the
// loop end from before it.
struct TimelineModel {
    SamplePos pos;
    bool looping;
    SamplePos loopStart, loopEnd;
    bool cameFromBelow;

    TimelineModel(SamplePos start, bool loop, SamplePos ls, SamplePos le)
        : pos(start), looping(loop && le > ls), loopStart(ls), loopEnd(le),
          cameFromBelow(start < le) {}

    // Returns the frame's sample; `wrapped` says whether it is the first after a wrap.
    SamplePos next(bool& wrapped) {
        wrapped = false;
        if (looping && pos == loopEnd && cameFromBelow) {
            pos = loopStart;
            wrapped = true;
        }
        if (pos < loopEnd) cameFromBelow = true;
        return pos++;
    }
};

// Checks one segment's tick range straight against the TempoMap: exactly the ticks whose
// sample lands in the segment, clamped to `minTick` (the loop start) after a wrap.
void checkSegmentTicks(CheckResult& checks, const TempoMap& map, const TransportSegment& seg,
                       Tick minTick) {
    const SamplePos end = seg.startSample + seg.numFrames;
    DAW_CHECK(seg.startTick <= seg.endTick);
    if (!seg.afterWrap || seg.startTick > minTick) {
        DAW_CHECK(map.tickToSample(seg.startTick - 1) < seg.startSample);
    } else {
        DAW_CHECK(seg.startTick == minTick);
    }
    DAW_CHECK(map.tickToSample(seg.startTick) >= seg.startSample);
    DAW_CHECK(map.tickToSample(seg.endTick) >= end);
    if (seg.endTick > seg.startTick) DAW_CHECK(map.tickToSample(seg.endTick - 1) < end);
}

// Owns the channel memory a RenderTarget points at.
struct Target {
    explicit Target(uint32_t frames) : data(2, std::vector<float>(frames, 0.0f)) {
        for (auto& channel : data) ptrs.push_back(channel.data());
        target.output = AudioBufferView{ptrs.data(), 2, frames};
    }
    std::vector<std::vector<float>> data;
    std::vector<float*> ptrs;
    RenderTarget target;
};

uint64_t renderCounted(Engine& engine, RenderTarget& target, uint32_t numFrames) {
    RtScope scope;
    engine.render(target, numFrames);
    return scope.violations();
}

struct GraphStep {
    std::shared_ptr<Node> node;
    bool resetOnLocate = false;  // TIME-008: a timeline node
};

// One step per node, each writing its own buffer; the first is the master. The graph owns
// `tempo` (TIME-003) and runs at its sample rate.
std::unique_ptr<RenderGraph> makeGraph(std::vector<GraphStep> steps, const TempoMap& tempo) {
    RenderGraphDesc desc;
    desc.sampleRate = tempo.sampleRate();
    desc.tempo = tempo;
    desc.buffers =
        std::move(AudioBufferPool::create(static_cast<uint32_t>(steps.size()), 2, kMaxBlock))
            .value();
    for (std::size_t i = 0; i < steps.size(); ++i) {
        RenderStepDesc step;
        step.node = std::move(steps[i].node);
        step.output = static_cast<uint32_t>(i);
        step.resetOnLocate = steps[i].resetOnLocate;
        desc.steps.push_back(std::move(step));
    }
    desc.master = 0;
    return std::move(RenderGraph::create(std::move(desc))).value();
}

std::shared_ptr<Node> put(Engine& engine, NodeID id, std::unique_ptr<Node> node) {
    return std::move(engine.nodes().put(id, std::move(node), kInfo)).value();
}

// MARK: Test nodes (TEST-004 style; test builds only)

// TIME-006 reference timeline node: writes 1.0 at the frame of every event tick it plays, 0
// elsewhere. Keeps a cursor into its sorted events and re-seeks it only when the segment jumps,
// as a MIDI or clip player would.
class TickImpulseNode final : public Node {
public:
    explicit TickImpulseNode(std::vector<Tick> events) : events_(std::move(events)) {
        std::sort(events_.begin(), events_.end());
    }

    void prepare(const PrepareInfo&) override {}
    void reset() DAW_RT override {
        continuity_.forget();
        resets.fetch_add(1, std::memory_order_relaxed);
    }

    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        // Step 1: clear; frames outside every segment stay silent.
        for (uint32_t c = 0; c < io.audioOut.numChannels; ++c)
            for (uint32_t f = 0; f < ctx.numFrames; ++f) io.audioOut.channels[c][f] = 0.0f;
        const TransportBlock& block = ctx.transport;
        forEachSegment(block, [&](const TransportSegment& seg) DAW_RT {
            if (continuity_.jumped(seg)) cursor_ = seek(seg.startTick);  // step 3
            for (; cursor_ < events_.size() && events_[cursor_] < seg.endTick; ++cursor_) {
                if (!segmentContains(seg, events_[cursor_])) continue;
                const uint32_t frame = frameOfTick(block, seg, events_[cursor_]);
                for (uint32_t c = 0; c < io.audioOut.numChannels; ++c)
                    io.audioOut.channels[c][frame] += 1.0f;
            }
        });
    }

    std::atomic<int> resets{0};

private:
    // First event at or after `tick` (binary search, bounded by log2 of the event count).
    std::size_t seek(Tick tick) const DAW_RT {
        std::size_t lo = 0, hi = events_.size();
        while (lo < hi) {
            const std::size_t mid = lo + (hi - lo) / 2;
            if (events_[mid] < tick) lo = mid + 1; else hi = mid;
        }
        return lo;
    }

    std::vector<Tick> events_;
    std::size_t cursor_ = 0;
    SegmentContinuity continuity_;
};

// Records what the Engine handed it in ProcessContext::transport.
class TransportProbe final : public Node {
public:
    void prepare(const PrepareInfo&) override {}
    void reset() DAW_RT override {
        resets.fetch_add(1, std::memory_order_relaxed);
        resetPending_ = true;
    }
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override {
        const TransportBlock& block = ctx.transport;
        tempo = block.tempo;
        sawNullTempo = sawNullTempo || block.tempo == nullptr;
        if (block.tempo != nullptr) {
            bpm = tempoAtStart(block);
            startSample = blockStartSample(block);
        }
        playing = block.playing;
        numSegments = block.numSegments;
        frames = segmentFrames(block);
        if (resetPending_) {  // the block a reset() came before
            resetBefore = blockStartSample(block);
            resetPending_ = false;
        }
        for (uint32_t c = 0; c < io.audioOut.numChannels; ++c)
            for (uint32_t f = 0; f < ctx.numFrames; ++f) io.audioOut.channels[c][f] = 0.0f;
    }

    std::atomic<int> resets{0};
    SamplePos resetBefore = -1;  // start of the block processed right after the last reset()
    const TempoMap* tempo = nullptr;
    bool sawNullTempo = false;
    bool playing = false;
    double bpm = 0;
    SamplePos startSample = -1;
    uint8_t numSegments = 99;
    uint32_t frames = 0;

private:
    bool resetPending_ = false;
};

} // namespace

// MARK: TIME-004

CheckResult transportCommandsApplyAtBlockStart() {
    CheckResult checks;
    RtAdvance advance;
    const TempoMap map;  // 120 bpm at 48 kHz: 25 samples per tick
    Transport t;

    DAW_CHECK(t.play());
    DAW_CHECK(t.locate(960));
    DAW_CHECK(t.setLoop(true, 960, 2 * 960));
    DAW_CHECK(t.setRecording(true));
    // Nothing applies until the audio thread starts a block.
    DAW_CHECK(!t.playing() && t.samplePos() == 0 && !t.loopEnabled() && !t.recording());
    DAW_CHECK(!t.playhead().playing);

    const TransportBlock& b = advance(t, map, 100);
    DAW_CHECK(b.playing && b.recording);
    DAW_CHECK(b.numSegments == 1 && b.seg[0].startSample == 24000);  // located before laying out
    DAW_CHECK(t.loopEnabled() && t.loopStart() == 960 && t.loopEnd() == 1920);
    DAW_CHECK(t.samplePos() == 24100);
    DAW_CHECK(t.commandsApplied() == 4);
    DAW_CHECK(t.locatedWhilePlaying());  // play was applied before the locate

    // Invalid loops are refused at the call and never queued.
    DAW_CHECK(!t.setLoop(true, 10, 10));
    DAW_CHECK(!t.setLoop(true, 20, 10));
    DAW_CHECK(t.setLoop(false, 20, 10));  // disabled: kept for readout only
    advance(t, map, 0);
    DAW_CHECK(!t.loopEnabled() && t.loopStart() == 20 && t.loopEnd() == 10);
    DAW_CHECK(t.commandsApplied() == 5);

    // Order within one block: the last command wins.
    DAW_CHECK(t.stop() && t.play());
    DAW_CHECK(advance(t, map, 10).playing);
    DAW_CHECK(t.play() && t.stop());
    const SamplePos before = t.samplePos();
    const TransportBlock& stopped = advance(t, map, 10);
    DAW_CHECK(!stopped.playing && stopped.numSegments == 0);
    DAW_CHECK(t.samplePos() == before);  // stop keeps the position
    DAW_CHECK(advance(t, map, 4096).numSegments == 0 && t.samplePos() == before);

    // A full queue refuses commands without dropping the queued ones.
    std::size_t accepted = 0;
    for (std::size_t i = 0; i < Transport::kCommandCapacity + 10; ++i)
        accepted += t.locate(static_cast<Tick>(i)) ? 1 : 0;
    DAW_CHECK(accepted == Transport::kCommandCapacity);
    advance(t, map, 0);
    DAW_CHECK(t.samplePos() == map.tickToSample(Transport::kCommandCapacity - 1));
    DAW_CHECK(t.locate(5));  // room again
    advance(t, map, 0);
    DAW_CHECK(t.samplePos() == 125);

    DAW_CHECK(advance.violations == 0);
    return checks;
}

CheckResult transportCommandsFromManyThreads() {
    CheckResult checks;
    constexpr int kProducers = 4;
    constexpr int kPerProducer = 3000;
    const TempoMap map;
    Transport t;

    std::atomic<bool> producing{true};
    std::atomic<uint64_t> rtViolations{0};
    std::thread audio([&] {
        uint64_t violations = 0;
        auto blocks = [&] {
            RtScope scope;
            for (int i = 0; i < 64; ++i) t.advance(map, 64);
            violations += scope.violations();
        };
        while (producing.load(std::memory_order_acquire)) blocks();
        blocks();  // drain the rest
        rtViolations = violations;
    });

    std::vector<std::thread> producers;
    for (int p = 0; p < kProducers; ++p) {
        producers.emplace_back([&, p] {
            for (int i = 0; i < kPerProducer; ++i) {
                bool ok = false;
                switch (i % 4) {
                case 0: ok = t.play(); break;
                case 1: ok = t.locate(p * 100000 + i); break;
                case 2: ok = t.setLoop(i % 8 == 2, i, i + 960); break;
                default: ok = t.stop(); break;
                }
                while (!ok) {  // queue full: let the audio thread drain, then resend
                    std::this_thread::yield();
                    ok = t.locate(p * 100000 + i);
                }
            }
        });
    }
    for (auto& thread : producers) thread.join();
    producing = false;
    audio.join();

    DAW_CHECK(t.commandsApplied() == uint64_t{kProducers} * kPerProducer);
    DAW_CHECK(rtViolations.load() == 0);
    return checks;
}

// MARK: TIME-005

CheckResult transportLinearSegments() {
    CheckResult checks;
    RtAdvance advance;
    const TempoMap map;
    Transport t;

    // Stopped: no segment, but seg[0] carries the position and the tempo map is set.
    const TransportBlock& stopped = advance(t, map, 512);
    DAW_CHECK(!stopped.playing && stopped.numSegments == 0 && stopped.tempo == &map);
    DAW_CHECK(blockStartSample(stopped) == 0 && stopped.seg[0].numFrames == 0);

    DAW_CHECK(t.locate(10) && t.play());
    Tick nextTick = -1;
    SamplePos nextSample = 250;
    for (uint32_t n : {512u, 1u, 0u, 4096u, 13u, 0u, 777u}) {
        const TransportBlock& b = advance(t, map, n);
        DAW_CHECK(b.playing && b.tempo == &map);
        DAW_CHECK(blockStartSample(b) == nextSample);
        if (n == 0) {
            DAW_CHECK(b.numSegments == 0);
            continue;
        }
        DAW_CHECK(b.numSegments == 1);
        const TransportSegment& s = b.seg[0];
        DAW_CHECK(s.startSample == nextSample && s.frameOffset == 0 && s.numFrames == n);
        DAW_CHECK(!s.afterWrap);
        if (nextTick >= 0) DAW_CHECK(s.startTick == nextTick);  // ticks tile
        checkSegmentTicks(checks, map, s, 0);
        DAW_CHECK(blockStartTick(b) == map.sampleToTick(nextSample));
        DAW_CHECK(tempoAtStart(b) == 120.0);
        nextTick = s.endTick;
        nextSample += n;
        DAW_CHECK(t.samplePos() == nextSample);
    }
    DAW_CHECK(advance.violations == 0);
    return checks;
}

CheckResult transportLoopWrapMidBlock() {
    CheckResult checks;
    RtAdvance advance;
    const TempoMap map;  // 25 samples per tick
    Transport t;
    // Loop ticks 960..1920 = samples 24000..48000. Start 100 samples before the end.
    DAW_CHECK(t.setLoop(true, 960, 1920));
    DAW_CHECK(t.locate(1916) && t.play());  // sample 47900

    const TransportBlock& b = advance(t, map, 512);
    DAW_CHECK(b.numSegments == 2);
    const TransportSegment& s0 = b.seg[0];
    const TransportSegment& s1 = b.seg[1];
    DAW_CHECK(s0.startSample == 47900 && s0.frameOffset == 0 && s0.numFrames == 100);
    DAW_CHECK(s0.startTick == 1916 && s0.endTick == 1920 && !s0.afterWrap);
    DAW_CHECK(s1.startSample == 24000 && s1.frameOffset == 100 && s1.numFrames == 412);
    // 24000 + 412 = 24412 → ticks 960..976 (tick 976 is at 24400 < 24412; 977 at 24425).
    DAW_CHECK(s1.startTick == 960 && s1.endTick == 977 && s1.afterWrap);
    DAW_CHECK(segmentFrames(b) == 512);
    DAW_CHECK(t.samplePos() == 24412);
    // Events at the loop end's tick are outside the loop; at its start, inside the second pass.
    DAW_CHECK(!segmentContains(s0, 1920) && segmentContains(s1, 960));
    DAW_CHECK(frameOfTick(b, s0, 1919) == 75 && frameOfTick(b, s1, 960) == 100);
    checkSegmentTicks(checks, map, s0, 0);
    checkSegmentTicks(checks, map, s1, 960);

    // The next block continues the second pass, no longer marked.
    const TransportBlock& next = advance(t, map, 64);
    DAW_CHECK(next.numSegments == 1 && next.seg[0].startSample == 24412);
    DAW_CHECK(!next.seg[0].afterWrap && next.seg[0].startTick == 977);
    DAW_CHECK(advance.violations == 0);
    return checks;
}

CheckResult transportLoopWrapAtBlockBoundary() {
    CheckResult checks;
    RtAdvance advance;
    const TempoMap map;
    Transport t;
    DAW_CHECK(t.setLoop(true, 960, 1920));
    DAW_CHECK(t.locate(1900) && t.play());  // sample 47500, 500 before the end

    const TransportBlock& b = advance(t, map, 500);
    DAW_CHECK(b.numSegments == 1);
    DAW_CHECK(b.seg[0].startSample == 47500 && b.seg[0].numFrames == 500);
    DAW_CHECK(b.seg[0].endTick == 1920 && !b.seg[0].afterWrap);
    DAW_CHECK(t.samplePos() == 24000);  // already wrapped

    // A 0-frame block in between doesn't consume the wrap.
    DAW_CHECK(advance(t, map, 0).numSegments == 0);

    const TransportBlock& after = advance(t, map, 256);
    DAW_CHECK(after.numSegments == 1);
    DAW_CHECK(after.seg[0].startSample == 24000 && after.seg[0].frameOffset == 0);
    DAW_CHECK(after.seg[0].startTick == 960 && after.seg[0].afterWrap);
    DAW_CHECK(!advance(t, map, 256).seg[0].afterWrap);

    // A locate clears a pending wrap: the next segment is a jump, but not a wrap.
    DAW_CHECK(t.locate(1900));
    advance(t, map, 0);
    advance(t, map, 500);
    DAW_CHECK(t.locate(0));
    const TransportBlock& located = advance(t, map, 64);
    DAW_CHECK(located.seg[0].startSample == 0 && !located.seg[0].afterWrap);
    DAW_CHECK(advance.violations == 0);
    return checks;
}

CheckResult transportRandomBlockSizes() {
    CheckResult checks;
    RtAdvance advance;
    std::mt19937 rng(8008);
    std::uniform_int_distribution<uint32_t> blockSize(0, kMaxBlock);

    struct Case {
        TempoMap map;
        Tick loopStart, loopEnd, start;
    };
    std::vector<Case> cases;
    // 120 bpm, 48 kHz: 25 samples per tick. Start before the loop.
    cases.push_back({TempoMap(), 3840, 3840 + 4 * 960, 0});
    // 44.1 kHz, tempo changes inside the loop, 7/8: non-integer samples per tick.
    cases.push_back({makeMap({{0, 97.0}, {5000, 143.5}, {7000, 61.25}}, {{0, 7, 8}}, 44100.0),
                     4000, 9000, 4500});
    // Start inside the loop, at a tick that isn't on the sample grid.
    cases.push_back({makeMap({{0, 133.0}}, {{0, 4, 4}}, 96000.0), 100, 100 + 3 * 960, 777});

    for (const Case& c : cases) {
        Transport t;
        DAW_CHECK(t.setLoop(true, c.loopStart, c.loopEnd) && t.locate(c.start) && t.play());
        const SamplePos ls = c.map.tickToSample(c.loopStart);
        const SamplePos le = c.map.tickToSample(c.loopEnd);
        DAW_CHECK(le - ls > SamplePos{kMaxBlock});  // so segments always cover the block
        TimelineModel model(c.map.tickToSample(c.start), true, ls, le);

        int wraps = 0;
        Tick nextTick = firstTickAtOrAfter(c.map, model.pos);
        for (int block = 0; block < 400; ++block) {
            const uint32_t n = blockSize(rng);
            const TransportBlock& b = advance(t, c.map, n);
            DAW_CHECK(b.playing && b.tempo == &c.map);
            DAW_CHECK(b.numSegments <= 2 && segmentFrames(b) == n);
            DAW_CHECK(n > 0 || b.numSegments == 0);

            uint32_t frame = 0;
            for (uint8_t i = 0; i < b.numSegments; ++i) {
                const TransportSegment& s = b.seg[i];
                DAW_CHECK(s.numFrames > 0 && s.frameOffset == frame);
                for (uint32_t f = 0; f < s.numFrames; ++f) {
                    bool wrapped = false;
                    const SamplePos expected = model.next(wrapped);
                    if (expected != s.startSample + f) {
                        DAW_CHECK(expected == s.startSample + f);
                        return checks;
                    }
                    // Only a segment's first frame can follow a wrap.
                    DAW_CHECK(wrapped == (f == 0 && s.afterWrap));
                    wraps += wrapped ? 1 : 0;
                }
                checkSegmentTicks(checks, c.map, s, c.loopStart);
                if (s.afterWrap) {
                    DAW_CHECK(s.startTick == c.loopStart || s.startTick ==
                              firstTickAtOrAfter(c.map, ls));
                } else {
                    DAW_CHECK(s.startTick == nextTick);  // ticks tile across blocks
                }
                DAW_CHECK(s.endTick <= c.loopEnd || s.startSample >= le);
                nextTick = s.endTick;
                frame += s.numFrames;
            }
        }
        DAW_CHECK(wraps >= 3);
    }
    DAW_CHECK(advance.violations == 0);
    return checks;
}

CheckResult transportLoopEdgeCases() {
    CheckResult checks;
    RtAdvance advance;
    const TempoMap map;  // 25 samples per tick
    {
        // Past the loop end: plays on.
        Transport t;
        DAW_CHECK(t.setLoop(true, 0, 960) && t.locate(960) && t.play());
        const TransportBlock& b = advance(t, map, 4096);
        DAW_CHECK(b.numSegments == 1 && b.seg[0].startSample == 24000 && !b.seg[0].afterWrap);
        DAW_CHECK(t.samplePos() == 24000 + 4096);
    }
    {
        // Disabling the loop mid-play: no wrap.
        Transport t;
        DAW_CHECK(t.setLoop(true, 0, 960) && t.locate(950) && t.play());
        advance(t, map, 100);
        DAW_CHECK(t.setLoop(false, 0, 960));
        const TransportBlock& b = advance(t, map, 4096);
        DAW_CHECK(b.numSegments == 1 && t.samplePos() == 23750 + 100 + 4096);
    }
    {
        // Enabling it ahead of the playhead: wraps when it gets there.
        Transport t;
        DAW_CHECK(t.play());
        advance(t, map, 1000);
        DAW_CHECK(t.setLoop(true, 0, 80));  // samples 0..2000
        const TransportBlock& b = advance(t, map, 1500);
        DAW_CHECK(b.numSegments == 2 && b.seg[0].numFrames == 1000 && b.seg[1].numFrames == 500);
        DAW_CHECK(b.seg[1].startSample == 0 && b.seg[1].afterWrap);
    }
    {
        // A loop shorter than the block plays once, then a gap; the next block wraps again.
        Transport t;
        DAW_CHECK(t.setLoop(true, 0, 40) && t.locate(20) && t.play());  // samples 0..1000
        const TransportBlock& b = advance(t, map, 4096);
        DAW_CHECK(b.numSegments == 2);
        DAW_CHECK(b.seg[0].startSample == 500 && b.seg[0].numFrames == 500);
        DAW_CHECK(b.seg[1].startSample == 0 && b.seg[1].frameOffset == 500);
        DAW_CHECK(b.seg[1].numFrames == 1000 && b.seg[1].endTick == 40);
        DAW_CHECK(segmentFrames(b) == 1500);
        DAW_CHECK(t.samplePos() == 0);
        const TransportBlock& next = advance(t, map, 4096);
        DAW_CHECK(next.numSegments == 2 && next.seg[0].startSample == 0 && next.seg[0].afterWrap);
        DAW_CHECK(next.seg[0].numFrames == 1000 && next.seg[1].numFrames == 1000);
    }
    {
        // A tick shorter than a sample (1 kHz, 1000 bpm: 16 ticks per sample). Ticks that round
        // onto the loop start's sample but lie before the loop aren't replayed after a wrap.
        const TempoMap fast = makeMap({{0, 1000.0}}, {{0, 4, 4}}, 1000.0);
        Transport t;
        DAW_CHECK(t.setLoop(true, 1601, 9600) && t.locate(9000) && t.play());
        const SamplePos ls = fast.tickToSample(1601);
        DAW_CHECK(fast.sampleToTick(ls - 1) + 1 < 1601);  // the case being tested
        const TransportBlock& b = advance(t, fast, 100);
        DAW_CHECK(b.numSegments == 2 && b.seg[1].startSample == ls);
        DAW_CHECK(b.seg[1].startTick == 1601);
        checkSegmentTicks(checks, fast, b.seg[1], 1601);
    }
    DAW_CHECK(advance.violations == 0);
    return checks;
}

// MARK: TIME-006

CheckResult timelineNodeHonorsSegments() {
    CheckResult checks;
    Engine engine;
    // The graph's own map (TIME-003): a tempo change inside the loop.
    const TempoMap map = makeMap({{0, 97.0}, {3000, 143.5}});

    // Events every 37 ticks, plus ones on the loop's start and end ticks.
    constexpr Tick kLoopStart = 1000, kLoopEnd = 1000 + 4 * 960;
    std::vector<Tick> events{kLoopStart, kLoopEnd};
    for (Tick tick = 0; tick < 3 * kLoopEnd; tick += 37) events.push_back(tick);
    std::vector<SamplePos> eventSamples;
    for (Tick tick : events) eventSamples.push_back(map.tickToSample(tick));
    std::sort(eventSamples.begin(), eventSamples.end());

    auto node = put(engine, 1, std::make_unique<TickImpulseNode>(events));
    engine.publish(makeGraph({{node, true}}, map));
    DAW_CHECK(engine.transport().setLoop(true, kLoopStart, kLoopEnd));
    DAW_CHECK(engine.transport().locate(200) && engine.transport().play());

    TimelineModel model(map.tickToSample(200), true, map.tickToSample(kLoopStart),
                        map.tickToSample(kLoopEnd));
    Target out(kMaxBlock);
    std::mt19937 rng(6006);
    std::uniform_int_distribution<uint32_t> blockSize(0, kMaxBlock);
    uint64_t violations = 0;
    int impulses = 0, wraps = 0;
    for (int block = 0; block < 300; ++block) {
        const uint32_t n = blockSize(rng);
        violations += renderCounted(engine, out.target, n);
        for (uint32_t f = 0; f < n; ++f) {
            bool wrapped = false;
            const SamplePos sample = model.next(wrapped);
            wraps += wrapped ? 1 : 0;
            const auto range = std::equal_range(eventSamples.begin(), eventSamples.end(), sample);
            const auto count = range.second - range.first;
            if (out.data[0][f] != static_cast<float>(count) || out.data[1][f] != out.data[0][f]) {
                DAW_CHECK(out.data[0][f] == static_cast<float>(count));
                return checks;
            }
            impulses += static_cast<int>(count);
        }
    }
    DAW_CHECK(wraps >= 3 && impulses > 100);
    DAW_CHECK(violations == 0);
    return checks;
}

CheckResult segmentContinuity() {
    CheckResult checks;
    SegmentContinuity c;
    auto seg = [](SamplePos start, uint32_t n, bool afterWrap = false) {
        return TransportSegment{start, 0, 0, 0, n, afterWrap};
    };
    DAW_CHECK(c.jumped(seg(100, 10)));    // first segment
    DAW_CHECK(!c.jumped(seg(110, 10)));   // continues
    DAW_CHECK(!c.jumped(seg(120, 5)));
    DAW_CHECK(c.jumped(seg(0, 10)));      // a locate
    DAW_CHECK(c.jumped(seg(10, 10, true)));  // a wrap is a jump even if contiguous
    DAW_CHECK(!c.jumped(seg(20, 10)));
    c.forget();
    DAW_CHECK(c.jumped(seg(30, 10)));     // after reset()
    return checks;
}

// MARK: TIME-007

CheckResult tempoChangeInsideBlock() {
    CheckResult checks;
    RtAdvance advance;
    // 120 bpm → 60 bpm at tick 960 (sample 24000); after it, 50 samples per tick.
    const TempoMap map = makeMap({{0, 120.0}, {960, 60.0}});
    Transport t;
    DAW_CHECK(t.locate(900) && t.play());  // sample 22500
    const TransportBlock& b = advance(t, map, 4096);  // up to 26596
    DAW_CHECK(b.numSegments == 1);
    // The block is processed at the tempo at its start…
    DAW_CHECK(tempoAtStart(b) == 120.0);
    // …but its tick range is exact: 960 + ceil(2596 / 50) = 1012, where extrapolating 120 bpm
    // would give 900 + ceil(4096 / 25) = 1064.
    DAW_CHECK(b.seg[0].startTick == 900 && b.seg[0].endTick == 1012);
    // An event after the change sounds where the tempo map puts it.
    DAW_CHECK(segmentContains(b.seg[0], 1000) && frameOfTick(b, b.seg[0], 1000) == 3500);
    DAW_CHECK(segmentContains(b.seg[0], 1011) && !segmentContains(b.seg[0], 1012));
    // The next block starts after the change.
    DAW_CHECK(tempoAtStart(advance(t, map, 64)) == 60.0);
    DAW_CHECK(advance.violations == 0);
    return checks;
}

// MARK: TIME-003

CheckResult tempoMapPerBlock() {
    CheckResult checks;
    RtAdvance advance;
    const TempoMap slow = makeMap({{0, 60.0}});   // 50 samples per tick
    const TempoMap fast = makeMap({{0, 120.0}});  // 25 samples per tick
    Transport t;
    DAW_CHECK(t.setLoop(true, 960, 1920) && t.locate(100) && t.play());

    const TransportBlock& a = advance(t, slow, 1000);
    DAW_CHECK(a.tempo == &slow && a.seg[0].startSample == 5000);  // locate through `slow`
    DAW_CHECK(tempoAtStart(a) == 60.0);

    // A tempo edit is a new snapshot with a new map: the next block uses it. The position stays
    // put in samples; the ticks under it change.
    const TransportBlock& b = advance(t, fast, 1000);
    DAW_CHECK(b.tempo == &fast && b.seg[0].startSample == 6000);
    DAW_CHECK(b.seg[0].startTick == 240 && blockStartTick(b) == 240);
    DAW_CHECK(tempoAtStart(b) == 120.0);

    // The loop resolves through the current map: its end is at 1920 * 25 = 48000 now, not
    // 1920 * 50.
    DAW_CHECK(t.locate(1910));
    const TransportBlock& c = advance(t, fast, 1000);
    DAW_CHECK(c.numSegments == 2 && c.seg[0].numFrames == 250 && c.seg[1].startSample == 24000);
    DAW_CHECK(c.tempo == &fast);
    DAW_CHECK(advance.violations == 0);
    return checks;
}

CheckResult engineHandsNodesTheTransportBlock() {
    CheckResult checks;
    Engine engine;
    auto probe = std::make_shared<TransportProbe>();
    const TempoMap slow = makeMap({{0, 60.0}});   // 50 samples per tick
    const TempoMap fast = makeMap({{0, 120.0}});  // 25 samples per tick
    auto first = makeGraph({{probe}}, slow);
    const TempoMap* firstMap = &first->tempoMap();
    engine.publish(std::move(first));
    Target out(kMaxBlock);
    uint64_t violations = 0;

    violations += renderCounted(engine, out.target, 256);
    DAW_CHECK(!probe->playing && probe->numSegments == 0 && probe->startSample == 0);
    // TIME-003: the block points at the current graph's own map.
    DAW_CHECK(probe->tempo == firstMap && probe->bpm == 60.0);

    // Commands from this thread apply at the next render's first frame (TIME-004, ENG-041), and
    // the locate resolves through the graph's map.
    DAW_CHECK(engine.transport().locate(960) && engine.transport().play());
    DAW_CHECK(!engine.transport().playhead().playing);
    violations += renderCounted(engine, out.target, 256);
    DAW_CHECK(probe->playing && probe->numSegments == 1 && probe->frames == 256);
    DAW_CHECK(probe->startSample == 48000);
    DAW_CHECK(engine.transport().playhead().playing);
    DAW_CHECK(engine.transport().playhead().sample == 48000);
    DAW_CHECK(engine.transport().playhead().tick == 960);

    // TIME-003: a tempo edit is a new snapshot; the next block uses its map. The position keeps
    // its sample; the tick under it follows the new map.
    auto second = makeGraph({{probe}}, fast);
    const TempoMap* secondMap = &second->tempoMap();
    engine.publish(std::move(second));
    violations += renderCounted(engine, out.target, 128);
    DAW_CHECK(probe->tempo == secondMap && probe->bpm == 120.0);
    DAW_CHECK(probe->startSample == 48256);
    DAW_CHECK(engine.transport().playhead().tick == fast.sampleToTick(48256));
    DAW_CHECK(engine.transport().locate(960));
    violations += renderCounted(engine, out.target, 128);
    DAW_CHECK(probe->startSample == 24000);

    // Without a graph nothing renders and the transport stands still.
    engine.publish(nullptr);
    violations += renderCounted(engine, out.target, 128);
    engine.publish(makeGraph({{probe}}, fast));
    violations += renderCounted(engine, out.target, 128);
    DAW_CHECK(probe->startSample == 24128);
    DAW_CHECK(!probe->sawNullTempo);
    DAW_CHECK(violations == 0);
    return checks;
}

// MARK: TIME-008

CheckResult locateWhilePlayingFlagsReset() {
    CheckResult checks;
    RtAdvance advance;
    const TempoMap map;
    {
        Transport t;
        DAW_CHECK(t.locate(10));
        advance(t, map, 64);
        DAW_CHECK(!t.locatedWhilePlaying());  // stopped
        DAW_CHECK(t.play());
        advance(t, map, 64);
        DAW_CHECK(!t.locatedWhilePlaying());  // play alone isn't a locate
        DAW_CHECK(t.locate(500));
        advance(t, map, 64);
        DAW_CHECK(t.locatedWhilePlaying());
        advance(t, map, 64);
        DAW_CHECK(!t.locatedWhilePlaying());  // only for that block
        DAW_CHECK(t.stop() && t.locate(20));
        advance(t, map, 64);
        DAW_CHECK(!t.locatedWhilePlaying());  // the stop came first
        DAW_CHECK(t.locate(30) && t.play());
        advance(t, map, 64);
        DAW_CHECK(!t.locatedWhilePlaying());  // located, then started
        // A loop wrap isn't a locate.
        DAW_CHECK(t.setLoop(true, 0, 40) && t.locate(39));
        advance(t, map, 64);
        DAW_CHECK(t.locatedWhilePlaying());
        advance(t, map, 4096);
        DAW_CHECK(!t.locatedWhilePlaying());
    }
    {
        // Through the Engine, with a real graph: a timeline step (resetOnLocate) is reset once,
        // before the block at the new position; an effect step keeps its state.
        Engine engine;
        auto timeline = std::make_shared<TransportProbe>();
        auto effect = std::make_shared<TransportProbe>();
        engine.publish(makeGraph({{timeline, true}, {effect, false}}, map));
        Target out(kMaxBlock);
        uint64_t violations = 0;
        DAW_CHECK(engine.transport().play());
        violations += renderCounted(engine, out.target, 64);
        DAW_CHECK(timeline->resets.load() == 0);  // starting playback isn't a locate

        DAW_CHECK(engine.transport().locate(960));
        violations += renderCounted(engine, out.target, 64);
        DAW_CHECK(timeline->resets.load() == 1 && timeline->resetBefore == 24000);
        DAW_CHECK(effect->resets.load() == 0 && effect->startSample == 24000);
        violations += renderCounted(engine, out.target, 64);
        DAW_CHECK(timeline->resets.load() == 1);  // only that block

        // Loop wraps (mid-block and on a block boundary) don't reset: nodes handle them per
        // segment (TIME-006).
        DAW_CHECK(engine.transport().setLoop(true, 0, 40) && engine.transport().locate(30));
        violations += renderCounted(engine, out.target, 64);   // the locate: reset #2
        DAW_CHECK(timeline->resets.load() == 2 && timeline->resetBefore == 750);
        violations += renderCounted(engine, out.target, 186);  // ends on the loop end (1000)
        violations += renderCounted(engine, out.target, 600);  // starts after the wrap
        violations += renderCounted(engine, out.target, 4096);  // wraps mid-block
        DAW_CHECK(timeline->resets.load() == 2);

        // Stopped: a locate just moves the position.
        DAW_CHECK(engine.transport().stop());
        violations += renderCounted(engine, out.target, 64);
        DAW_CHECK(engine.transport().locate(0));
        violations += renderCounted(engine, out.target, 64);
        DAW_CHECK(timeline->resets.load() == 2 && effect->resets.load() == 0);
        DAW_CHECK(violations == 0);
    }
    DAW_CHECK(advance.violations == 0);
    return checks;
}

// MARK: TIME-009

CheckResult playheadLatencyCompensation() {
    CheckResult checks;
    RtAdvance advance;
    const TempoMap map;  // 25 samples per tick
    Transport t;
    t.setOutputLatency(1000);
    DAW_CHECK(t.outputLatency() == 1000);

    // Stopped: nothing in flight, no compensation.
    DAW_CHECK(t.locate(400));  // sample 10000
    advance(t, map, 512);
    TransportPlayhead p = t.playhead();
    DAW_CHECK(!p.playing && p.sample == 10000 && p.tick == 400);

    // Playing: the first blocks clamp to where playback started…
    DAW_CHECK(t.play());
    advance(t, map, 512);
    p = t.playhead();
    DAW_CHECK(p.playing && p.sample == 10000);
    advance(t, map, 512);
    DAW_CHECK(t.playhead().sample == 10000);  // 10512 − 1000 is still before the start
    advance(t, map, 512);
    p = t.playhead();
    DAW_CHECK(p.sample == 10024 && p.tick == map.sampleToTick(10024));  // 11024 − 1000
    advance(t, map, 512);
    DAW_CHECK(t.playhead().sample == 10536);

    // …and the latency is a driver setting that takes effect on the next block.
    t.setOutputLatency(0);
    advance(t, map, 512);
    DAW_CHECK(t.playhead().sample == 12048);  // this block's first frame

    // After a wrap, the position before the run's start maps back to the end of the loop.
    t.setOutputLatency(300);
    DAW_CHECK(t.setLoop(true, 960, 1920) && t.locate(1900));  // loop 24000..48000, at 47500
    advance(t, map, 0);
    advance(t, map, 500);   // ends on the loop end; wrap pending
    advance(t, map, 200);   // first block after the wrap starts at 24000
    p = t.playhead();
    DAW_CHECK(p.sample == 48000 - 300);
    DAW_CHECK(p.loopEnabled && p.loopStart == 960 && p.loopEnd == 1920);
    advance(t, map, 200);   // starts at 24200: 23900 is before the run, so 47900
    DAW_CHECK(t.playhead().sample == 47900);
    advance(t, map, 200);   // starts at 24400: past the latency
    DAW_CHECK(t.playhead().sample == 24100);

    // A wrap mid-block takes effect for the playhead from the next block on.
    DAW_CHECK(t.locate(1916));  // 47900
    advance(t, map, 0);
    advance(t, map, 64);    // a locate while playing: clamps to 47900
    DAW_CHECK(t.playhead().sample == 47900);
    advance(t, map, 512);   // starts at 47964, wraps after 36 frames
    DAW_CHECK(t.playhead().sample == 47900);
    advance(t, map, 64);    // starts at 24476: 24176
    DAW_CHECK(t.playhead().sample == 24176);

    // Latency longer than the loop maps back modulo the loop length.
    t.setOutputLatency(0);
    DAW_CHECK(t.setLoop(true, 0, 4) && t.locate(0));  // samples 0..100
    advance(t, map, 0);
    advance(t, map, 100);   // wraps at the boundary
    t.setOutputLatency(250);
    advance(t, map, 10);    // starts at 0: 250 back = 50 into the loop, two passes back
    DAW_CHECK(t.playhead().sample == 50);

    // Recording shows in the readout.
    DAW_CHECK(t.setRecording(true));
    advance(t, map, 0);
    DAW_CHECK(t.playhead().recording);
    DAW_CHECK(advance.violations == 0);
    return checks;
}

CheckResult playheadIsConsistentAcrossThreads() {
    CheckResult checks;
    const TempoMap map = makeMap({{0, 97.0}, {9600, 151.0}});
    Transport t;
    t.setOutputLatency(333);
    DAW_CHECK(t.play());

    std::atomic<bool> running{true};
    std::atomic<uint64_t> rtViolations{0};
    std::atomic<uint64_t> blocks{0};
    std::thread audio([&] {
        RtScope scope;
        while (running.load(std::memory_order_acquire)) {
            t.advance(map, 128);
            blocks.fetch_add(1, std::memory_order_release);
        }
        rtViolations = scope.violations();
    });

    // DW-091: reads only test something while the audio thread publishes. Under load it can start
    // late enough that all the reads used to finish before its first block, which then never
    // came (running was already false) and the final `playing` check failed. So wait for the
    // first block, and keep reading until the writer has published plenty of blocks meanwhile.
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (blocks.load(std::memory_order_acquire) == 0 && std::chrono::steady_clock::now() < deadline)
        std::this_thread::yield();
    const uint64_t blocksBefore = blocks.load(std::memory_order_acquire);
    constexpr uint64_t kMinBlocks = 1000;

    // The writer publishes loops with end = start + 960 and the matching tick for each sample;
    // a torn read would mix fields from two blocks.
    int torn = 0, reads = 0;
    std::mt19937 rng(9009);
    for (int i = 0; i < 20000 || (blocks.load(std::memory_order_acquire) - blocksBefore < kMinBlocks &&
                                  std::chrono::steady_clock::now() < deadline);
         ++i) {
        if (i % 50 == 0) {
            const Tick start = static_cast<Tick>(rng() % 20000);
            (void)t.setLoop(i % 100 == 0, start, start + 960);
            (void)t.locate(static_cast<Tick>(rng() % 20000));
        }
        const TransportPlayhead p = t.playhead();
        ++reads;
        if (p.tick != map.sampleToTick(p.sample)) ++torn;
        if (p.loopEnd != p.loopStart + 960 && !(p.loopStart == 0 && p.loopEnd == 0)) ++torn;
    }
    const uint64_t blocksDuringReads = blocks.load(std::memory_order_acquire) - blocksBefore;
    running = false;
    audio.join();
    DAW_CHECK(blocksBefore > 0 && blocksDuringReads >= kMinBlocks);
    DAW_CHECK(reads >= 20000 && torn == 0);
    DAW_CHECK(t.playhead().playing);
    DAW_CHECK(rtViolations.load() == 0);
    return checks;
}

} // namespace daw::testing
