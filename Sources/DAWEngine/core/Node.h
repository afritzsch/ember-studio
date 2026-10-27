#pragma once
// ENG-001..004: the node API. A node owns DSP state and is shared across RenderGraph snapshots
// through the NodePool, so publishing a graph never re-instantiates it or resets its state.

#include <cstdint>

#include "core/Realtime.h"

namespace daw {

// Stable identity assigned by the model; survives snapshots.
using NodeID = uint64_t;

// ENG-004: nodes handle any numFrames <= kMaxBlock, including 0.
inline constexpr uint32_t kMaxBlock = 4096;

struct PrepareInfo {
    double sampleRate;
    uint32_t maxBlock;
    uint32_t numIn, numOut;
};

struct ProcessContext;
struct NodeIO;

class Node {
public:
    virtual ~Node() = default;
    // ENG-013: called on the compile thread before the node is first published, and again when
    // its config changes.
    virtual void prepare(const PrepareInfo&) = 0;  // non-RT
    // ENG-013: called on daw.reclaim once no live graph references the node.
    virtual void release() {}                      // non-RT
    virtual void reset() DAW_RT {}                 // RT (transport jump)
    virtual void process(ProcessContext&, NodeIO&) DAW_RT = 0;
    // ENG-002: readable off the audio thread; changes only after prepare().
    virtual uint32_t latencySamples() const { return 0; }
};

} // namespace daw
