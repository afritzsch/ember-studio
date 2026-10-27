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
// An input port gets its samples one of two ways (MIX-004, edges into one port are summed):
//   - pull (T-004): `sources` are summed into the port's own buffer right before the node runs.
//     Every source must stay live until then, so a merge holds all of its inputs at once.
//   - push (T-012, what GraphBuilder emits): the port is `fed`. Earlier steps write into its
//     buffer right after they process (RenderFeedDesc: the first feed copies, later ones add), so
//     a producer's output buffer is free again as soon as it has fed its consumers, and live buffers stay near
//     the graph's depth instead of its fan-in (MIX-003). A fed port whose only producer feeds
//     nothing else simply names that producer's output buffer, with no copy at all.
//   PDC delay lines (MIX-021, T-021) plug in where a feed or a pull source is summed.
// MIDI routing isn't modelled yet: nodes get an empty midiIn and a writer that accepts nothing.
//
// Lifetime: the graph co-owns its nodes (shared_ptr, see NodePool) so a node outlives every
// snapshot that uses it, but the audio thread only ever sees raw pointers. Graphs are destroyed
// on daw.reclaim (ENG-012), which is also where a node's last reference is usually dropped.

#include <cstdint>
#include <limits>
#include <memory>
#include <optional>
#include <vector>

#include "core/AudioBufferPool.h"
#include "core/AudioBufferView.h"
#include "core/Node.h"
#include "core/Realtime.h"
#include "core/Result.h"
#include "time/TempoMap.h"

namespace daw {

struct ProcessContext;

inline constexpr uint32_t kNoBuffer = std::numeric_limits<uint32_t>::max();

// One input port. Pull: `buffer` is where `sources` are summed; it must be set (and differ from
// every source) whenever `sources` is non-empty. Push (`fed`): `buffer` already holds the input,
// written by earlier steps' feeds, and `sources` must be empty. Either way `buffer` must differ
// from the step's output.
struct RenderPortDesc {
    std::vector<uint32_t> sources;
    uint32_t buffer = kNoBuffer;
    bool fed = false;
};

// After its node processes, a step copies (`add` false) or adds its output into `buffer`. The
// builder makes the first feed into a buffer in each block a copy, so nothing needs clearing.
struct RenderFeedDesc {
    uint32_t buffer = kNoBuffer;
    bool add = false;
};

struct RenderStepDesc {
    std::shared_ptr<Node> node;  // prepared (ENG-013), normally from the NodePool
    RenderPortDesc input;
    RenderPortDesc sidechain;
    uint32_t output = kNoBuffer; // kNoBuffer: the node writes nothing (e.g. a pure MIDI sink)
    std::vector<RenderFeedDesc> feeds;  // requires an output
    // TIME-008 (T-008): the node reads the timeline (clip players), so a locate or loop jump
    // must reset() it before the next block. GraphBuilder sets it from NodeKind
    // (audioClipPlayer, midiClipPlayer); see RenderGraph::resetTimelineNodes().
    bool resetOnLocate = false;
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

    // TIME-003: the graph's tempo map, immutable for its lifetime. Engine::render points
    // TransportBlock.tempo at it (T-008), so a tempo edit takes effect with the next snapshot.
    const TempoMap& tempoMap() const DAW_RT { return tempo_; }

    // TIME-008: whether step `step` holds a timeline node that a locate must reset.
    bool resetsOnLocate(uint32_t step) const DAW_RT { return steps_[step].resetOnLocate; }
    // TIME-008: calls reset() on every step flagged resetOnLocate, in step order. For Engine to
    // call (audio thread) after a locate or loop jump, before processing the block.
    void resetTimelineNodes() const DAW_RT;

    // ENG-041, the per-node part of a block: for each step in order, gather its inputs, then
    // process. Requires ctx.numFrames <= maxBlock().
    void process(ProcessContext& ctx) const DAW_RT;

    // The master bus for the block just processed; empty when the graph has none.
    AudioBufferView master(uint32_t numFrames) const DAW_RT;

private:
    struct Port {
        uint32_t buffer = kNoBuffer;
        uint32_t firstSource = 0;  // into sources_
        uint32_t numSources = 0;
        bool fed = false;
    };
    struct Step {
        Node* node;
        Port input;
        Port sidechain;
        uint32_t output;
        uint32_t firstFeed;  // into feeds_
        uint32_t numFeeds;
        bool resetOnLocate;
    };

    RenderGraph() = default;
    AudioBufferView gather(const Port& port, uint32_t numFrames) const DAW_RT;
    void feed(const Step& step, uint32_t numFrames) const DAW_RT;

    double sampleRate_ = 0;
    uint32_t maxBlock_ = 0;
    uint32_t master_ = kNoBuffer;
    uint64_t version_ = 0;
    AudioBufferPool buffers_;
    TempoMap tempo_;
    std::vector<Step> steps_;
    std::vector<uint32_t> sources_;
    std::vector<RenderFeedDesc> feeds_;
    std::vector<std::shared_ptr<Node>> owned_;
};

} // namespace daw
