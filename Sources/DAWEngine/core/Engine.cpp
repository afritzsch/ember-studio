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
    const uint64_t startTicks = Telemetry::clockTicks();  // ENG-051: nonblocking
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
        // T-008 (ENG-041 "advance transport"): transport_ = transport.advance(n) goes here.
        ProcessContext ctx{n, graph->sampleRate(), transport_, params_};
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

    // ENG-041 "publish telemetry", ENG-050/051. DW-037: an oversize block rendered silence
    // above; a full RetireQueue means RT retire() calls are failing this block.
    if (graph != nullptr && n > graph->maxBlock()) telemetry_.countOversizeBlock();
    if (reclaimer_.rtQueue().sizeApprox() >= RetireQueue::kCapacity)
        telemetry_.countRetireQueueFull();
    // DW-024: this block's own RtScope count, not the process-wide RtTrap::violationCount().
    // The end tick is taken last, so the render time includes the telemetry work.
    const uint64_t violations = rtScope.violations();
    const uint64_t renderNanos = telemetry_.ticksToNanos(Telemetry::clockTicks() - startTicks);
    telemetry_.recordBlock(renderNanos, n, graph != nullptr ? graph->sampleRate() : 0.0,
                           violations, epoch + 2);

    // ENG-012: the block is done with `graph`.
    renderEpoch_.store(epoch + 2, std::memory_order_seq_cst);
}

} // namespace daw
