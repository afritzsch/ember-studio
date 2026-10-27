#pragma once
// MIX-002: topological order for GraphBuilder, by Kahn's algorithm. Non-RT.
//
// Among the nodes that are ready, Kahn's algorithm may pick any. This one picks by a depth-first
// post-order from the sinks, so each node runs as soon after its inputs as possible. That keeps
// few summing buffers open at once, which is what lets buffer liveness (MIX-003) reuse buffers.

#include <cstdint>
#include <limits>
#include <span>
#include <vector>

namespace daw {

struct TopoEdge {
    uint32_t from;
    uint32_t to;
};

struct TopoSortResult {
    std::vector<uint32_t> order;  // every node, inputs before outputs; empty when there's a cycle
    // When the graph has a cycle: the nodes on a cycle or on a path between cycles (nodes that
    // merely feed into one, or hang off one, are left out), ascending.
    std::vector<uint32_t> cycle;
};

inline constexpr uint32_t kNoNode = std::numeric_limits<uint32_t>::max();

// Nodes are 0..<numNodes; every edge endpoint must be in range. `last`, if not kNoNode, must
// have no outgoing edges and is ordered after every other node (the master, MIX-009).
TopoSortResult topoSort(uint32_t numNodes, std::span<const TopoEdge> edges, uint32_t last = kNoNode);

} // namespace daw
