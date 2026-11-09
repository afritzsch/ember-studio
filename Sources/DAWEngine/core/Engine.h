#pragma once
// ENG-010..015, ENG-040..042: the engine. Non-RT threads publish immutable RenderGraphs; the
// audio thread renders whichever graph is current, one block per render() call.
//
// Threads: publish() from any non-RT thread; render() from one thread at a time (the device or
// offline driver, D-15). Destroy the engine only after rendering has stopped.
//
// Latency compensation at the source (MIX-023, T-021). The transport position is what the graph
// outputs in this block: OfflineDriver writes block i as timeline position from + i, and the
// TIME-009 playhead subtracts only the device's output latency. So a graph with total latency L
// (RenderGraph::latency, the master's path latency) runs its timeline nodes L samples ahead:
//   - Timeline steps (RenderStepDesc::timeline: clip/MIDI players, metronome) get a TransportBlock
//     laid out from where the transport will be L samples later, following the loop the way the
//     transport does (a playhead before the loop end wraps; one at or past it plays on). Every
//     other node gets the transport's own block. PDC aligns every path to the master at L, so
//     what a timeline node renders at position p leaves the master when the transport is at p.
//     The look-ahead is a pure function of the transport position, so it stays continuous
//     across the transport's own loop wraps.
//   - Pre-roll: a run of playback (play from stopped, or a locate while playing) starts with L
//     frames rendered and discarded before the block, in chunks of at most maxBlock, timeline
//     nodes playing [p, p + L) and the rest seeing the L frames before p. That fills the PDC
//     delay lines and the latent nodes, so the first block out is exactly position p (an export
//     from tick 0 has the click on beat 1 at sample 0). The first block of a run costs L extra
//     frames of rendering, which can overrun a live callback when L is large.
//   - Pre-roll lives here rather than in each player so every timeline node gets it the same way
//     and players need no latency state or loop knowledge. A graph whose latency changes while
//     playing (MIX-024) jumps the timeline nodes by the difference, without a new pre-roll; the
//     players' wrap crossfade softens it.
//   - Automation and param changes aren't compensated (MIX-025): they apply when the block
//     renders, so a param on a node behind L samples of latency is heard L samples early.

#include <atomic>
#include <cstdint>
#include <memory>

#include "core/NodePool.h"
#include "core/LiveMidiInput.h"
#include "core/ParamSlotTable.h"
#include "core/Realtime.h"
#include "core/Reclaimer.h"
#include "core/RenderGraph.h"
#include "core/RenderTarget.h"
#include "core/RetireQueue.h"
#include "core/Telemetry.h"
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

    // REC-010/011 (T-053), non-RT, before anything renders: where live MIDI input comes from.
    void setLiveMidiInput(LiveMidiInput* input) { liveMidi_ = input; }
    // RT, the render thread: the host time this device IO cycle started at, for the next block's
    // LiveMidiInput::beginBlock (DeviceRenderer sets it; offline renders never do).
    void setCycleHostTicks(uint64_t ticks) DAW_RT { cycleHostTicks_ = ticks; }

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
    // ENG-010/011. seq_cst on both sides, see Reclaimer.h.
    std::atomic<RenderGraph*> current_{nullptr};
    // ENG-050: written by render() once per block (the "publish telemetry" step).
    Telemetry telemetry_;

    // Audio thread only. MIX-020/023: the serial of the graph whose latency table telemetry has
    // (0: none, or no graph); and whether the current run of playback has been pre-rolled.
    uint64_t latencySerial_ = 0;
    bool runPrerolled_ = false;
    void preRoll(const RenderGraph& graph, const TransportBlock& block) DAW_RT;
    // REC-010/011 (T-053). Set before rendering starts; the ticks are render thread only.
    LiveMidiInput* liveMidi_ = nullptr;
    uint64_t cycleHostTicks_ = 0;
};

} // namespace daw
