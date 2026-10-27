#pragma once
// The immutable render plan the audio thread executes (02 Concepts, D-05). GraphBuilder (05,
// MIX-001) is its only producer in the engine; tests assemble one directly with create().
//
// Shape (T-004 minimum; T-012/T-021 extend it):
//   - steps in topological order, each with a node pointer, an output buffer and two input
//     ports (main audio, sidechain);
//   - an input port lists the buffers whose contents are summed into its own gather buffer
//     before the node runs (MIX-004; PDC delay lines, MIX-021, plug in at that point later);
//   - all buffers live in the graph's own AudioBufferPool (ENG-061), indexed by uint32_t;
//   - the master buffer is copied to the RenderTarget after the last step.
// MIDI routing isn't modelled yet: nodes get an empty midiIn and a writer that accepts nothing.
//
// Lifetime: the graph co-owns its nodes (shared_ptr, see NodePool) so a node outlives every
// snapshot that uses it, but the audio thread only ever sees raw pointers. Graphs are destroyed
// on daw.reclaim (ENG-012), which is also where a node's last reference is usually dropped.

#include <cstdint>
#include <limits>
#include <memory>
#include <vector>

#include "core/AudioBufferPool.h"
#include "core/AudioBufferView.h"
#include "core/Node.h"
#include "core/Realtime.h"
#include "core/Result.h"

namespace daw {

struct ProcessContext;

inline constexpr uint32_t kNoBuffer = std::numeric_limits<uint32_t>::max();

// One input port as GraphBuilder describes it. `buffer` is where `sources` are summed; it must
// be set (and differ from every source) whenever `sources` is non-empty.
struct RenderPortDesc {
    std::vector<uint32_t> sources;
    uint32_t buffer = kNoBuffer;
};

struct RenderStepDesc {
    std::shared_ptr<Node> node;  // prepared (ENG-013), normally from the NodePool
    RenderPortDesc input;
    RenderPortDesc sidechain;
    uint32_t output = kNoBuffer; // kNoBuffer: the node writes nothing (e.g. a pure MIDI sink)
};

struct RenderGraphDesc {
    double sampleRate = 48000.0;
    uint32_t maxBlock = kMaxBlock;  // the largest numFrames the nodes were prepared for
    AudioBufferPool buffers;        // maxFrames >= maxBlock
    std::vector<RenderStepDesc> steps;  // topological order
    uint32_t master = kNoBuffer;    // kNoBuffer: the graph outputs silence
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
    };
    struct Step {
        Node* node;
        Port input;
        Port sidechain;
        uint32_t output;
    };

    RenderGraph() = default;
    AudioBufferView gather(const Port& port, uint32_t numFrames) const DAW_RT;

    double sampleRate_ = 0;
    uint32_t maxBlock_ = 0;
    uint32_t master_ = kNoBuffer;
    AudioBufferPool buffers_;
    std::vector<Step> steps_;
    std::vector<uint32_t> sources_;
    std::vector<std::shared_ptr<Node>> owned_;
};

} // namespace daw
