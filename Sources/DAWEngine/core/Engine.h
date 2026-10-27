#pragma once
// ENG-010..015, ENG-040..042: the engine. Non-RT threads publish immutable RenderGraphs; the
// audio thread renders whichever graph is current, one block per render() call.
//
// Threads: publish() from any non-RT thread; render() from one thread at a time (the device or
// offline driver, D-15). Destroy the engine only after rendering has stopped.

#include <atomic>
#include <cstdint>
#include <memory>

#include "core/NodePool.h"
#include "core/ParamSlotTable.h"
#include "core/Realtime.h"
#include "core/Reclaimer.h"
#include "core/RenderGraph.h"
#include "core/RenderTarget.h"
#include "core/RetireQueue.h"
#include "core/Telemetry.h"
#include "time/TempoMap.h"
#include "time/Transport.h"

namespace daw {

class Engine {
public:
    // Non-RT. Starts daw.reclaim; in Debug also installs the RT trap (ENG-030, DW-011).
    Engine();
    // Non-RT. Requires that no render() is running or will run. Everything still alive (the
    // current graph, pooled nodes) is freed on daw.reclaim before this returns.
    ~Engine();
    Engine(const Engine&) = delete;
    Engine& operator=(const Engine&) = delete;

    // ENG-010: non-RT, any thread. Makes `graph` current from the next block on and retires the
    // previous one (ENG-012). Null unpublishes: render outputs silence (ENG-015).
    void publish(std::unique_ptr<RenderGraph> graph);

    // ENG-040: the single RT entry point. Renders `numFrames` frames of the current graph into
    // target.output (clamped to its numFrames). Outputs silence when no graph is published or
    // numFrames exceeds the graph's maxBlock.
    void render(RenderTarget& target, uint32_t numFrames) DAW_RT;

    // ENG-020/021: the session's param slots; graphs reference them by ParamID. DW-029: free a
    // ParamID only once the last graph that references it has been reclaimed, never right after
    // publishing a graph without it: a block may still be rendering the old graph, and a freed
    // slot is handed out again at once.
    ParamSlotTable& params() { return params_; }
    NodePool& nodes() { return nodes_; }  // non-RT

    // TIME-004/009: commands and the playhead from any non-RT thread; render() advances it.
    Transport& transport() { return transport_; }
    const Transport& transport() const { return transport_; }

    // ENG-014: for RT code that is done with a heap object (audio thread only).
    RetireQueue& retireQueue() { return reclaimer_.rtQueue(); }

    // Non-RT diagnostics.
    const Reclaimer& reclaimer() const { return reclaimer_; }
    // Completed blocks so far (each block bumps the raw epoch twice, see Reclaimer.h).
    uint64_t blocksRendered() const { return renderEpoch_.load(std::memory_order_acquire) / 2; }

    // ENG-050: read from any thread without locks. The non-const overload is for the other
    // producers (driver xruns and latency, meters, node latencies; see Telemetry.h).
    const Telemetry& telemetry() const { return telemetry_; }
    Telemetry& telemetry() { return telemetry_; }

private:
    // Declaration order is destruction order in reverse: the reclaimer outlives the pool and
    // the epoch outlives the reclaimer.
    std::atomic<uint64_t> renderEpoch_{0};
    Reclaimer reclaimer_{renderEpoch_};
    NodePool nodes_{reclaimer_};
    ParamSlotTable params_;
    // TIME-004..009: advanced at the start of every block that renders a graph.
    Transport transport_;
    // T-012 seam (TIME-003): render() should hand the transport graph->tempoMap() (approved 05
    // Interfaces addition: the RenderGraph owns the map GraphBuilder built at the engine's rate).
    // Until T-012 merges, every graph plays at this map's 120 bpm, 4/4, 48 kHz.
    TempoMap fallbackTempo_;
    // ENG-010/011. seq_cst on both sides, see Reclaimer.h.
    std::atomic<RenderGraph*> current_{nullptr};
    // ENG-050: written by render() once per block (the "publish telemetry" step).
    Telemetry telemetry_;
};

} // namespace daw
