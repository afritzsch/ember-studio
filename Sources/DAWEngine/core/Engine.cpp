#include "core/Engine.h"

#include <cstring>
#include <utility>

#include "core/Denormals.h"
#include "core/ProcessContext.h"
#include "core/RtTrap.h"
#include "time/TransportSegments.h"

namespace daw {

namespace {

void silence(const AudioBufferView& out, uint32_t numFrames) DAW_RT {
    for (uint32_t c = 0; c < out.numChannels; ++c)
        std::memset(out.channels[c], 0, std::size_t{numFrames} * sizeof(float));
}

// MARK: MIX-023 look-ahead (see Engine.h)

// The transport's loop for this block, in samples of the graph's map, as Transport::layOut
// resolves it: an empty loop is off.
struct Loop {
    bool on = false;
    SamplePos start = 0, end = 0;
    Tick startTick = 0;
};

Loop loopOf(const Transport& transport, const TempoMap& tempo) DAW_RT {
    Loop loop;
    if (!transport.loopEnabled()) return loop;
    loop.start = tempo.tickToSample(transport.loopStart());
    loop.end = tempo.tickToSample(transport.loopEnd());
    loop.startTick = transport.loopStart();
    loop.on = loop.end > loop.start;
    return loop;
}

// Where playback from `pos` is `frames` later, with the transport's loop rule; `wrapped` when it
// lands exactly on the loop start by wrapping (the next segment is the first after a wrap).
struct Ahead {
    SamplePos pos;
    bool wrapped;
};

Ahead advance(SamplePos pos, uint32_t frames, const Loop& loop) DAW_RT {
    const SamplePos to = pos + frames;
    if (!loop.on || pos >= loop.end || to < loop.end) return {to, false};
    const SamplePos offset = (to - loop.end) % (loop.end - loop.start);
    return {loop.start + offset, offset == 0};
}

// Transport.cpp's makeSegment: the tick rule of TransportSegments.h, and a tick that rounds onto
// the loop start's sample from before it belongs before the loop.
TransportSegment makeSegment(const TempoMap& tempo, SamplePos start, uint32_t frameOffset,
                             uint32_t numFrames, bool afterWrap, Tick wrapTick) DAW_RT {
    TransportSegment seg{start, firstTickAtOrAfter(tempo, start),
                         firstTickAtOrAfter(tempo, start + numFrames), frameOffset, numFrames,
                         afterWrap};
    if (afterWrap && seg.startTick < wrapTick) {
        seg.startTick = wrapTick;
        if (seg.endTick < wrapTick) seg.endTick = wrapTick;
    }
    return seg;
}

// `numFrames` frames of playback from `from`, laid out like Transport::layOut: one segment, or
// two when the loop wraps inside (a loop shorter than the rest leaves a gap, TIME-005).
TransportBlock layOut(const TransportBlock& like, const TempoMap& tempo, Ahead from,
                      uint32_t numFrames, const Loop& loop) DAW_RT {
    TransportBlock block = like;
    block.tempo = &tempo;
    const SamplePos end = from.pos + numFrames;
    if (!loop.on || from.pos >= loop.end || end <= loop.end) {
        block.seg[0] = makeSegment(tempo, from.pos, 0, numFrames, from.wrapped, loop.startTick);
        block.seg[1] = block.seg[0];
        block.numSegments = 1;
        return block;
    }
    const auto first = static_cast<uint32_t>(loop.end - from.pos);
    block.seg[0] = makeSegment(tempo, from.pos, 0, first, from.wrapped, loop.startTick);
    const SamplePos length = loop.end - loop.start;
    const uint32_t rest = numFrames - first;
    const uint32_t second = rest < length ? rest : static_cast<uint32_t>(length);
    block.seg[1] = makeSegment(tempo, loop.start, first, second, true, loop.startTick);
    block.numSegments = 2;
    return block;
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

    // REC-010/011 (T-053): the first block of a device cycle anchors the MIDI clock.
    const uint64_t cycleHostTicks = cycleHostTicks_;
    cycleHostTicks_ = 0;

    if (graph == nullptr || n > graph->maxBlock()) {
        silence(out, n);  // ENG-015
        if (liveMidi_ != nullptr) liveMidi_->idleBlock(n, cycleHostTicks);  // inputs keep draining
    } else {
        // ENG-041 "advance transport": queued commands apply from this block's first frame
        // (TIME-004), then the block is laid out on the timeline (TIME-005) with the map this
        // graph was built with (TIME-003), so a tempo edit takes effect with its snapshot.
        const TransportBlock& block = transport_.advance(graph->tempoMap(), n);
        // TIME-008: a locate while playing resets the timeline nodes (clip and MIDI players), so
        // they drop voices and tails from the old position; effects keep their tails. Loop wraps
        // don't reset: they can fall mid-block, and nodes handle them per segment (TIME-006).
        if (transport_.locatedWhilePlaying()) graph->resetTimelineNodes();

        // MIX-023: timeline nodes run graph->latency() samples ahead, and a new run of playback
        // is pre-rolled first (Engine.h).
        const uint32_t latency = graph->latency();
        // REC-021 (T-054): monitored tracks hear the device input, when the block has any.
        const bool monitorEnabled = !target.input.empty();
        if (!block.playing || transport_.locatedWhilePlaying()) runPrerolled_ = false;
        if (block.numSegments > 0 && !runPrerolled_) {
            if (latency > 0) preRoll(*graph, block, monitorEnabled);
            runPrerolled_ = true;
        }
        TransportBlock ahead = block;
        if (latency > 0 && block.numSegments > 0) {
            const Loop loop = loopOf(transport_, graph->tempoMap());
            ahead = layOut(block, graph->tempoMap(), advance(blockStartSample(block), latency, loop), n, loop);
        }
        ProcessContext ctx{n, graph->sampleRate(), block, params_};
        ProcessContext timeline{n, graph->sampleRate(), ahead, params_};
        // REC-011: after the pre-roll, whose chunks are rendered and thrown away.
        if (liveMidi_ != nullptr) liveMidi_->beginBlock(transport_, n, graph->sampleRate(), cycleHostTicks);
        graph->process(ctx, timeline, MonitorInput{monitorEnabled, &target.input});
        if (liveMidi_ != nullptr) liveMidi_->endBlock();

        // ENG-041: write master to the target.
        const AudioBufferView master = graph->master(n);
        for (uint32_t c = 0; c < out.numChannels; ++c) {
            if (c < master.numChannels)
                std::memcpy(out.channels[c], master.channels[c], std::size_t{n} * sizeof(float));
            else
                std::memset(out.channels[c], 0, std::size_t{n} * sizeof(float));
        }
    }

    // ENG-050, MIX-020/023: per-node latencies and the graph latency of the graph being heard,
    // copied whenever it changes.
    const uint64_t serial = graph != nullptr ? graph->serial() : 0;
    if (serial != latencySerial_) {
        if (graph != nullptr) {
            const auto table = graph->nodeLatencies();
            telemetry_.publishNodeLatencies(table.data(), static_cast<uint32_t>(table.size()),
                                            graph->latency());
        } else {
            telemetry_.publishNodeLatencies(nullptr, 0, 0);
        }
        latencySerial_ = serial;
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

void Engine::preRoll(const RenderGraph& graph, const TransportBlock& block, bool monitorEnabled) DAW_RT {
    // MIX-023: L frames before the block, chunked to the graph's maxBlock (CONV-RT-04: bounded
    // by latency / maxBlock). Timeline nodes play [p, p + L) on the transport's loop; the others
    // see a straight run of the L frames before p. The master output is dropped.
    const TempoMap& tempo = graph.tempoMap();
    const Loop loop = loopOf(transport_, tempo);
    const Loop straight;
    const uint32_t latency = graph.latency();
    const SamplePos start = blockStartSample(block);
    for (uint32_t done = 0; done < latency;) {
        const uint32_t remaining = latency - done;
        const uint32_t n = remaining < graph.maxBlock() ? remaining : graph.maxBlock();
        const TransportBlock before =
            layOut(block, tempo, {start - static_cast<SamplePos>(latency - done), false}, n, straight);
        const TransportBlock ahead = layOut(block, tempo, advance(start, done, loop), n, loop);
        ProcessContext ctx{n, graph.sampleRate(), before, params_};
        ProcessContext timeline{n, graph.sampleRate(), ahead, params_};
        // REC-021 (T-054): monitored tracks pre-roll silence (no input to give, no clip to leak).
        graph.process(ctx, timeline, MonitorInput{monitorEnabled, nullptr});
        done += n;
    }
}

} // namespace daw
