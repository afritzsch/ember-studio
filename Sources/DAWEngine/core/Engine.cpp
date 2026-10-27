#include "core/Engine.h"

#include <cstring>
#include <utility>

#include "core/Denormals.h"
#include "core/ProcessContext.h"
#include "core/RtTrap.h"

namespace daw {

namespace {

void silence(const AudioBufferView& out, uint32_t numFrames) DAW_RT {
    for (uint32_t c = 0; c < out.numChannels; ++c)
        std::memset(out.channels[c], 0, std::size_t{numFrames} * sizeof(float));
}

// TIME-008: a locate while playing resets the timeline nodes (clip and MIDI players), so they
// drop voices and tails from the old position; effects keep their tails.
void resetTimelineNodes(const RenderGraph& graph) DAW_RT {
    // T-012 seam: needs RenderGraph's per-step resetOnLocate flag (set from NodeKind). Until it
    // exists no step is known to be a timeline node, so none is reset.
    (void)graph;
}

} // namespace

Engine::Engine() {
    // DW-011, ENG-033: hooks go in before the first render; only render()'s own RtScope is
    // checked, so CoreAudio's allocations during device start don't count.
    (void)RtTrap::install();
}

Engine::~Engine() {
    // Hand everything to daw.reclaim; the reclaimer's destructor frees all of it there. Nothing
    // renders any more, so the graph is retired as if at an idle (even) epoch.
    reclaimer_.retireGraph(std::unique_ptr<RenderGraph>(current_.exchange(nullptr)), 0);
    nodes_.clear();
}

void Engine::publish(std::unique_ptr<RenderGraph> graph) {
    // ENG-010/012: swap, then read the epoch; seq_cst pairs with render() (Reclaimer.h).
    RenderGraph* previous = current_.exchange(graph.release(), std::memory_order_seq_cst);
    const uint64_t epoch = renderEpoch_.load(std::memory_order_seq_cst);
    reclaimer_.retireGraph(std::unique_ptr<RenderGraph>(previous), epoch);
}

void Engine::render(RenderTarget& target, uint32_t numFrames) DAW_RT {
    RtScope rtScope;              // ENG-030, DW-011
    ScopedFlushDenormals ftz;     // ENG-042

    // ENG-012: odd while a block runs. One render() at a time, so a plain increment is enough.
    const uint64_t epoch = renderEpoch_.load(std::memory_order_relaxed);
    renderEpoch_.store(epoch + 1, std::memory_order_seq_cst);

    // ENG-011: one load per block; this graph is used for the whole block.
    const RenderGraph* graph = current_.load(std::memory_order_seq_cst);

    const AudioBufferView& out = target.output;
    const uint32_t n = numFrames < out.numFrames ? numFrames : out.numFrames;

    if (graph == nullptr || n > graph->maxBlock()) {
        silence(out, n);  // ENG-015
    } else {
        // ENG-041 "advance transport": queued commands apply from this block's first frame
        // (TIME-004), then the block is laid out on the timeline (TIME-005).
        // T-012 seam: fallbackTempo_ becomes graph->tempoMap() (TIME-003).
        const TransportBlock& block = transport_.advance(fallbackTempo_, n);
        if (transport_.locatedWhilePlaying()) resetTimelineNodes(*graph);  // TIME-008
        ProcessContext ctx{n, graph->sampleRate(), block, params_};
        graph->process(ctx);

        // ENG-041: write master to the target.
        const AudioBufferView master = graph->master(n);
        for (uint32_t c = 0; c < out.numChannels; ++c) {
            if (c < master.numChannels)
                std::memcpy(out.channels[c], master.channels[c], std::size_t{n} * sizeof(float));
            else
                std::memset(out.channels[c], 0, std::size_t{n} * sizeof(float));
        }
    }

    // T-006 (ENG-041 "publish telemetry", ENG-050/051) goes here.

    // ENG-012: the block is done with `graph`.
    renderEpoch_.store(epoch + 2, std::memory_order_seq_cst);
}

} // namespace daw
