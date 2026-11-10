#pragma once
// The immutable render plan the audio thread executes (02 Concepts, D-05). GraphBuilder (05,
// MIX-001) is its only producer in the engine; tests assemble one directly with create().
//
// Shape:
//   - steps in topological order, each with a node pointer, an output buffer and two input
//     ports (main audio, sidechain);
//   - all buffers live in the graph's own AudioBufferPool (ENG-061), indexed by uint32_t;
//   - the master buffer is copied to the RenderTarget after the last step (MIX-009);
//   - the TempoMap the graph was built with (TIME-003); Engine points TransportBlock.tempo at it.
//
// Inputs are pushed (T-012; DW-052 removed T-004's pull path, where a port summed its sources
// right before its node ran). Earlier steps write into a port's buffer right after they process
// (RenderFeedDesc: the first feed into a buffer copies, later ones add, MIX-004), so a producer's
// output buffer is free again as soon as it has fed its consumers, and live buffers stay near the
// graph's depth instead of its fan-in (MIX-003). A port whose only producer feeds nothing else
// simply names that producer's output buffer, with no copy at all.
//
// PDC (MIX-021/022, T-021): a feed may go through a DelayLine, so every arrival at a merge point
// lines up with the latest one. Delay lines are preallocated on daw.compile and co-owned like
// nodes: GraphBuilder hands the same DelayLine to the next graph for an unchanged edge (keyed by
// edge ID), so its contents carry over a rebuild without any copy. Only one graph renders per
// block, so the line's state is touched by one thread at a time.
//
// Latency compensation at the source (MIX-023): the graph knows its total latency (the master's
// path latency); Engine::render gives the steps flagged `timeline` a TransportBlock that many
// samples ahead of the one the other steps get. See Engine.h.
// MIDI (T-045, DW-099) is pulled, not pushed: a step whose node writes MIDI owns fixed storage of
// `midiCapacity` events (0: its writer accepts nothing), allocated in create() and never resized,
// so a node that keeps room for its note-offs (MidiClipPlayer) can rely on it. A consumer's
// midiIn is gathered right before it runs: with one undelayed MIDI input it points straight at
// the upstream writer's written() span (no copy); with several it is their k-way merge in frame
// order (stable: equal frames keep input order) in the step's own merge storage, sized for the
// sum of its inputs, so a merge never drops anything. A delayed MIDI input (MIX-021) goes through
// a MidiDelayLine first, co-owned and carried over by edge ID like a DelayLine.
//
// Lifetime: the graph co-owns its nodes (shared_ptr, see NodePool) so a node outlives every
// snapshot that uses it, but the audio thread only ever sees raw pointers. Graphs are destroyed
// on daw.reclaim (ENG-012), which is also where a node's last reference is usually dropped.

#include <atomic>
#include <cstdint>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <vector>

#include "automation/AutomationSet.h"
#include "core/AudioBufferPool.h"
#include "core/AudioBufferView.h"
#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/Realtime.h"
#include "core/Result.h"
#include "core/Telemetry.h"
#include "time/TempoMap.h"

namespace daw {

struct ProcessContext;

inline constexpr uint32_t kNoBuffer = std::numeric_limits<uint32_t>::max();

// One input port: `buffer` already holds the input when the step runs, written by earlier steps'
// feeds or as a producer's own output (kNoBuffer: no input). It must differ from the step's
// output.
struct RenderPortDesc {
    uint32_t buffer = kNoBuffer;
};

// MIX-021/022: a fixed delay for one edge's audio, stereo (or `numChannels`), preallocated. It
// holds up to maxDelay() frames of history plus one block, so a feed of n <= maxBlock frames
// writes its input and then reads n frames `delay` behind it. Non-RT to create; process() is RT
// and called by one graph at a time. Contents survive from graph to graph (see above).
class DelayLine {
public:
    // Capacity is the next power of two >= maxDelay + maxBlock, so maxDelay() may exceed
    // `maxDelay` and a later, slightly longer delay can keep the same line.
    DelayLine(uint32_t numChannels, uint32_t maxDelay, uint32_t maxBlock);
    DelayLine(const DelayLine&) = delete;
    DelayLine& operator=(const DelayLine&) = delete;

    uint32_t numChannels() const DAW_RT { return numChannels_; }
    uint32_t maxDelay() const DAW_RT { return mask_ + 1 - maxBlock_; }
    uint32_t maxBlock() const DAW_RT { return maxBlock_; }

    // Pushes `in` (silence for channels it lacks) and copies (`add` false) or adds the input from
    // `delay` frames ago into `out`; channels of `out` beyond numChannels() are zeroed on a copy.
    // Requires delay <= maxDelay(), numFrames <= maxBlock(), and `in` not aliasing `out`.
    void process(const AudioBufferView& in, const AudioBufferView& out, uint32_t delay,
                 bool add, uint32_t numFrames) DAW_RT;

private:
    uint32_t numChannels_;
    uint32_t maxBlock_;
    uint32_t mask_ = 0;      // capacity − 1
    uint32_t write_ = 0;     // next frame to write; audio thread only
    std::unique_ptr<float[]> samples_;  // numChannels × capacity
};

// MIX-021 for MIDI edges (T-045): a fixed delay for one edge's MIDI. Events are queued with the
// frame they are due at (block start + frameOffset + delay, never earlier than the event queued
// before them, so the queue stays in order) and leave in the block that frame falls in. Non-RT
// to create; process() is RT, called once per block by the one graph rendering it, so contents
// carry over a rebuild when the next graph gets the same line (keyed by edge ID, GraphBuilder).
// Its capacity bounds events in flight, not the delay, so one line serves any delay: a changed
// delay keeps the line and its queue (events already queued keep their due frame; new ones may
// wait behind them, so a shrinking delay plays a few late, never reordered or lost).
//
// Overflow policy (05 "MIDI routing"): the queue never drops a note-off or a pedal-up for a note
// or pedal it let through. It counts the notes (per channel and key) and sustain pedals (CC 64)
// whose on/down it queued and whose off/up it hasn't seen yet, and keeps that many slots free:
// a note-on or pedal-down is queued only if room stays for itself and its own release, and any
// other event only if it leaves the reserve intact. Dropped events are counted (dropped()). CC
// 120/123 (All Sound/Notes Off) clear the channel's held notes; CC 121 clears its pedal.
// At most maxOut() events leave per block; the rest stay queued and leave at frame 0 of the next
// block (late, never lost), so a consumer's merge storage can be sized from maxOut().
class MidiDelayLine {
public:
    static constexpr uint32_t kMaxCapacity = 1u << 16;

    // `capacity` (1...kMaxCapacity) is rounded up to a power of two; maxOut >= 1.
    MidiDelayLine(uint32_t capacity, uint32_t maxOut);
    MidiDelayLine(const MidiDelayLine&) = delete;
    MidiDelayLine& operator=(const MidiDelayLine&) = delete;

    uint32_t capacity() const DAW_RT { return mask_ + 1; }
    uint32_t maxOut() const DAW_RT { return maxOut_; }

    // Queues `in` (frame offsets into this block, in frame order) `delay` frames later and returns
    // the events due in this block's `numFrames` frames, in order, with frame offsets into this
    // block. The span is valid until the next process().
    MidiEventSpan process(MidiEventSpan in, uint32_t delay, uint32_t numFrames) DAW_RT;

    // Events the overflow policy dropped so far (any thread).
    uint64_t dropped() const { return dropped_.load(std::memory_order_relaxed); }
    // Diagnostics and tests, not while a block renders: events queued, and notes/pedals the
    // queue keeps room for.
    uint32_t queued() const { return count_; }
    uint32_t reserved() const { return numHeld_ + numPedals_; }

private:
    struct Pending {
        int64_t due;
        MidiEvent event;
    };
    bool admit(const MidiEvent& e) DAW_RT;  // applies the overflow policy; true: queue it
    void drain(uint32_t numFrames) DAW_RT;  // moves due events into out_

    uint32_t mask_ = 0;
    uint32_t maxOut_;
    std::unique_ptr<Pending[]> queue_;
    std::unique_ptr<MidiEvent[]> out_;
    // Audio thread only.
    uint32_t head_ = 0, count_ = 0, numOut_ = 0;
    int64_t now_ = 0;      // frames processed so far
    int64_t lastDue_ = 0;  // due frame of the last event queued
    uint32_t lastOutFrame_ = 0;
    uint32_t numHeld_ = 0, numPedals_ = 0;
    std::unique_ptr<uint16_t[]> held_;  // [channel × 128 + key]
    bool pedal_[16] = {};
    std::atomic<uint64_t> dropped_{0};
};

// One MIDI input of a step: the events step `fromStep` (earlier in the order) wrote this block,
// through `delayLine` when there is one (required when delay > 0; a line serves one input per
// graph). GraphBuilder keeps a MIDI edge's line once it has one, even at delay 0, so events still
// in flight after a latency change are delivered.
struct RenderMidiInputDesc {
    uint32_t fromStep = 0;
    uint32_t delay = 0;
    std::shared_ptr<MidiDelayLine> delayLine = nullptr;
};

// After its node processes, a step copies (`add` false) or adds its output into `buffer`. The
// builder makes the first feed into a buffer in each block a copy, so nothing needs clearing.
// MIX-021: with `delay` > 0 the output goes through `delayLine` (required then, with
// delay <= its maxDelay()); a line serves one feed per graph.
struct RenderFeedDesc {
    uint32_t buffer = kNoBuffer;
    bool add = false;
    uint32_t delay = 0;
    std::shared_ptr<DelayLine> delayLine = nullptr;
};

struct RenderStepDesc {
    std::shared_ptr<Node> node;  // prepared (ENG-013), normally from the NodePool
    RenderPortDesc input;
    RenderPortDesc sidechain;
    uint32_t output = kNoBuffer; // kNoBuffer: the node writes nothing (e.g. a pure MIDI sink)
    std::vector<RenderFeedDesc> feeds;  // requires an output
    // TIME-008 (T-008): the node reads the timeline (clip players), so a locate while playing
    // must reset() it before the next block. Loop wraps don't reset it: they can fall mid-block,
    // and the node handles them per segment (TIME-006, DW-062). GraphBuilder sets it from NodeKind
    // (audioClipPlayer, midiClipPlayer); see RenderGraph::resetTimelineNodes().
    bool resetOnLocate = false;
    // MIX-023 (T-021): the node reads the timeline, so it is scheduled `latency` samples early:
    // process() hands it the latency-compensated TransportBlock. GraphBuilder sets it for
    // audioClipPlayer, midiClipPlayer and metronome.
    bool timeline = false;
    // T-045: room for this many MIDI events per block in NodeIO::midiOut (0: none), and the
    // MIDI inputs gathered into NodeIO::midiIn, merged in this order on equal frames.
    uint32_t midiCapacity = 0;
    std::vector<RenderMidiInputDesc> midiInputs;
};

struct RenderGraphDesc {
    double sampleRate = 48000.0;
    uint32_t maxBlock = kMaxBlock;  // the largest numFrames the nodes were prepared for
    AudioBufferPool buffers;        // maxFrames >= maxBlock
    std::vector<RenderStepDesc> steps;  // topological order
    uint32_t master = kNoBuffer;    // kNoBuffer: the graph outputs silence
    // TIME-003: must be at `sampleRate`. Unset: 120 bpm, 4/4 at `sampleRate`.
    std::optional<TempoMap> tempo;
    uint64_t version = 0;           // GraphDescription::version it was built from
    // MIX-020/023: the master's path latency, i.e. how far timeline steps run ahead, and the
    // nodes with a nonzero latencySamples() (for Telemetry::publishNodeLatencies).
    uint32_t latency = 0;
    std::vector<NodeLatency> nodeLatencies;
    // AUTO-001 (T-074): the description's enabled lanes, compiled (null: none). Engine::render
    // applies them before the nodes run (AutomationSet.h).
    std::unique_ptr<AutomationSet> automation;
};

class RenderGraph {
public:
    // Non-RT. Checks that every buffer index is in range and every port is well formed;
    // topological order is the builder's responsibility.
    static Result<std::unique_ptr<RenderGraph>> create(RenderGraphDesc desc);

    RenderGraph(const RenderGraph&) = delete;
    RenderGraph& operator=(const RenderGraph&) = delete;
    ~RenderGraph();  // non-RT (daw.reclaim)

    double sampleRate() const DAW_RT { return sampleRate_; }
    uint32_t maxBlock() const DAW_RT { return maxBlock_; }
    uint32_t numSteps() const DAW_RT { return static_cast<uint32_t>(steps_.size()); }
    Node* node(uint32_t step) const DAW_RT { return steps_[step].node; }
    const AudioBufferPool& buffers() const DAW_RT { return buffers_; }
    uint64_t version() const DAW_RT { return version_; }
    // Unique per RenderGraph created in this process (1, 2, …), unlike version(), which a rebuild
    // of the same description repeats. Engine uses it to notice a new graph.
    uint64_t serial() const DAW_RT { return serial_; }

    // MIX-023: total graph latency in samples (the master's path latency, MIX-020).
    uint32_t latency() const DAW_RT { return latency_; }
    // MIX-020: nodes with nonzero latency, in step order. Absent nodes have latency 0.
    std::span<const NodeLatency> nodeLatencies() const DAW_RT { return nodeLatencies_; }
    bool readsTimeline(uint32_t step) const DAW_RT { return steps_[step].timeline; }

    // TIME-003: the graph's tempo map, immutable for its lifetime. Engine::render points
    // TransportBlock.tempo at it (T-008), so a tempo edit takes effect with the next snapshot.
    const TempoMap& tempoMap() const DAW_RT { return tempo_; }

    // TIME-008: whether step `step` holds a timeline node that a locate must reset.
    bool resetsOnLocate(uint32_t step) const DAW_RT { return steps_[step].resetOnLocate; }
    // TIME-008: calls reset() on every step flagged resetOnLocate, in step order. For Engine to
    // call (audio thread) after a locate while playing, before processing the block; never on a
    // loop wrap (DW-062).
    void resetTimelineNodes() const DAW_RT;

    // ENG-041, the per-node part of a block: for each step in order, process, then feed its
    // output (through any PDC delay, MIX-021) to its consumers. Steps flagged `timeline` get
    // `timeline` (MIX-023), the others `ctx`; both must have the same numFrames <= maxBlock().
    void process(ProcessContext& ctx, ProcessContext& timeline) const DAW_RT;
    // Same, with no latency compensation (every step gets `ctx`).
    void process(ProcessContext& ctx) const DAW_RT { process(ctx, ctx); }

    // AUTO-001 (T-074): the graph's automation players, null without lanes. The set keeps
    // audio-thread state (cursors), so it is handed out mutable; only the render thread uses it.
    AutomationSet* automation() const DAW_RT { return automation_.get(); }

    // The master bus for the block just processed; empty when the graph has none.
    AudioBufferView master(uint32_t numFrames) const DAW_RT;

    // T-045: step `step`'s MIDI output capacity, and the events it wrote in the block just
    // processed (empty for a step without MIDI storage).
    uint32_t midiCapacity(uint32_t step) const DAW_RT { return steps_[step].midiCapacity; }
    MidiEventSpan midiOutput(uint32_t step) const DAW_RT;

private:
    struct Step {
        Node* node;
        uint32_t input;      // buffer or kNoBuffer
        uint32_t sidechain;  // buffer or kNoBuffer
        uint32_t output;
        uint32_t firstFeed;  // into feeds_
        uint32_t numFeeds;
        bool resetOnLocate;
        bool timeline;
        // T-045
        MidiEvent* midiOut;      // midiCapacity events, or null
        uint32_t midiCapacity;
        uint32_t firstMidiInput; // into midiInputs_
        uint32_t numMidiInputs;
        MidiEvent* midiMerge;    // mergeCapacity events when numMidiInputs > 1, else null
        uint32_t mergeCapacity;
    };
    struct MidiInput {
        uint32_t fromStep;
        uint32_t delay;
        MidiDelayLine* delayLine;  // co-owned through midiLines_, or null
    };
    struct Feed {
        uint32_t buffer;
        bool add;
        uint32_t delay;
        DelayLine* delayLine;  // co-owned through lines_
    };

    RenderGraph() = default;
    AudioBufferView input(uint32_t buffer, uint32_t numFrames) const DAW_RT;
    void feed(const Step& step, uint32_t numFrames) const DAW_RT;
    MidiEventSpan gatherMidi(const Step& step, uint32_t numFrames) const DAW_RT;

    double sampleRate_ = 0;
    uint32_t maxBlock_ = 0;
    uint32_t master_ = kNoBuffer;
    uint64_t version_ = 0;
    uint64_t serial_ = 0;
    uint32_t latency_ = 0;
    AudioBufferPool buffers_;
    TempoMap tempo_;
    std::vector<Step> steps_;
    std::vector<Feed> feeds_;
    std::vector<NodeLatency> nodeLatencies_;
    std::vector<std::shared_ptr<Node>> owned_;
    std::vector<std::shared_ptr<DelayLine>> lines_;
    // T-045: every step's MIDI output and merge storage, one allocation made in create(); the
    // events each step wrote this block (written on the audio thread, read by later steps);
    // scratch for one merge (max MIDI fan-in spans and cursors).
    std::vector<MidiInput> midiInputs_;
    std::vector<std::shared_ptr<MidiDelayLine>> midiLines_;
    std::unique_ptr<MidiEvent[]> midiStorage_;
    std::unique_ptr<uint32_t[]> midiSizes_;
    std::unique_ptr<MidiEventSpan[]> mergeSpans_;
    std::unique_ptr<uint32_t[]> mergeCursors_;
    std::unique_ptr<AutomationSet> automation_;  // AUTO-001 (T-074)
};

} // namespace daw
