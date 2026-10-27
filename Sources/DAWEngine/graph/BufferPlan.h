#pragma once
// MIX-003: which scratch buffer each step of a graph uses, assigned by liveness over the
// topological order so buffers are reused as soon as nothing reads them any more. Non-RT.
//
// Inputs are pushed (RenderGraph.h): a producer feeds its output into its consumers' input
// buffers right after it runs, so a merge never holds all of its inputs at once. Per step, in
// order:
//   1. the output buffer is allocated (it can't be one of the step's own inputs);
//   2. the step's input buffers are freed (the node has read them by the time it has run);
//   3. for each outgoing edge, the consumer's input buffer is allocated on first use and fed;
//   4. the output is freed, unless a consumer reads it directly or it is the master.
// A port with exactly one incoming edge, from a producer with no other outgoing audio edge,
// reads the producer's output directly instead (no buffer, no copy). The producer has no other
// reader, so the consumer may even treat that input as scratch.

#include <cstdint>
#include <span>
#include <vector>

#include "core/RenderGraph.h"

namespace daw {

// An audio or sidechain edge between steps (indices into the topological order, from < to).
struct PlanEdge {
    uint32_t from;
    uint32_t to;
    bool sidechain;
};

struct StepBuffers {
    uint32_t output = kNoBuffer;
    RenderPortDesc input;      // fed, or empty
    RenderPortDesc sidechain;  // fed, or empty
    std::vector<RenderFeedDesc> feeds;
};

struct BufferPlan {
    std::vector<StepBuffers> steps;
    uint32_t numBuffers = 0;
};

// `producesAudio[s]`: step s gets an output buffer. Every edge's `from` must produce audio.
// `master`: the step whose output must stay intact to the end of the block (kNoBuffer: none).
// Edges into one port keep their order; that is the order they're summed in (MIX-004).
BufferPlan planBuffers(const std::vector<bool>& producesAudio, std::span<const PlanEdge> edges,
                       uint32_t master);

} // namespace daw
