#include "graph/TopoSort.h"

#include <functional>
#include <queue>
#include <utility>

namespace daw {

namespace {

// Adjacency lists as offsets into one array (CSR).
struct Adjacency {
    std::vector<uint32_t> start;  // numNodes + 1
    std::vector<uint32_t> nodes;

    Adjacency(uint32_t numNodes, std::span<const TopoEdge> edges, bool reversed)
        : start(numNodes + 1, 0), nodes(edges.size()) {
        for (const TopoEdge& e : edges) ++start[(reversed ? e.to : e.from) + 1];
        for (uint32_t i = 0; i < numNodes; ++i) start[i + 1] += start[i];
        std::vector<uint32_t> fill(start.begin(), start.end() - 1);
        for (const TopoEdge& e : edges)
            nodes[fill[reversed ? e.to : e.from]++] = reversed ? e.from : e.to;
    }
    std::span<const uint32_t> of(uint32_t node) const {
        return {nodes.data() + start[node], start[node + 1] - start[node]};
    }
};

// Post-order rank of a depth-first walk over inputs, started from each sink (`last` after the
// others), then from anything not reached (only possible on a cycle). Iterative, so long chains
// can't overflow the stack.
std::vector<uint32_t> postOrderRanks(uint32_t numNodes, const Adjacency& inputs,
                                     const Adjacency& outputs, uint32_t last) {
    constexpr uint32_t kUnranked = kNoNode;
    std::vector<uint32_t> rank(numNodes, kUnranked);
    std::vector<bool> visited(numNodes, false);
    std::vector<std::pair<uint32_t, uint32_t>> stack;  // node, next input to visit
    uint32_t next = 0;

    auto walk = [&](uint32_t root) {
        if (visited[root]) return;
        visited[root] = true;
        stack.push_back({root, 0});
        while (!stack.empty()) {
            auto& [node, i] = stack.back();
            const auto in = inputs.of(node);
            if (i < in.size()) {
                const uint32_t u = in[i++];
                if (!visited[u]) {
                    visited[u] = true;
                    stack.push_back({u, 0});
                }
                continue;
            }
            rank[node] = next++;
            stack.pop_back();
        }
    };

    for (uint32_t n = 0; n < numNodes; ++n)
        if (n != last && outputs.of(n).empty()) walk(n);
    if (last != kNoNode) walk(last);
    for (uint32_t n = 0; n < numNodes; ++n) walk(n);
    return rank;
}

} // namespace

TopoSortResult topoSort(uint32_t numNodes, std::span<const TopoEdge> edges, uint32_t last) {
    const Adjacency outputs(numNodes, edges, false);
    const Adjacency inputs(numNodes, edges, true);
    const std::vector<uint32_t> rank = postOrderRanks(numNodes, inputs, outputs, last);

    // Kahn: repeatedly take the ready node (all inputs ordered) with the lowest rank. On a DAG
    // the post-order is itself topological, so this reproduces it.
    std::vector<uint32_t> pending(numNodes, 0);  // unordered inputs per node
    for (const TopoEdge& e : edges) ++pending[e.to];
    using Entry = std::pair<uint32_t, uint32_t>;  // rank, node
    std::priority_queue<Entry, std::vector<Entry>, std::greater<>> ready;
    for (uint32_t n = 0; n < numNodes; ++n)
        if (pending[n] == 0) ready.push({rank[n], n});

    TopoSortResult result;
    result.order.reserve(numNodes);
    while (!ready.empty()) {
        const uint32_t n = ready.top().second;
        ready.pop();
        result.order.push_back(n);
        for (uint32_t v : outputs.of(n))
            if (--pending[v] == 0) ready.push({rank[v], v});
    }
    if (result.order.size() == numNodes) return result;

    // MIX-002: a cycle. Kahn has already dropped everything upstream of it; peel what is only
    // downstream (nodes with no output left in the remaining set) the same way, in reverse.
    std::vector<bool> remaining(numNodes, true);
    for (uint32_t n : result.order) remaining[n] = false;
    std::vector<uint32_t> liveOutputs(numNodes, 0);
    for (const TopoEdge& e : edges)
        if (remaining[e.from] && remaining[e.to]) ++liveOutputs[e.from];
    std::vector<uint32_t> peel;
    for (uint32_t n = 0; n < numNodes; ++n)
        if (remaining[n] && liveOutputs[n] == 0) peel.push_back(n);
    while (!peel.empty()) {
        const uint32_t n = peel.back();
        peel.pop_back();
        remaining[n] = false;
        for (uint32_t u : inputs.of(n))
            if (remaining[u] && --liveOutputs[u] == 0) peel.push_back(u);
    }
    for (uint32_t n = 0; n < numNodes; ++n)
        if (remaining[n]) result.cycle.push_back(n);
    result.order.clear();
    return result;
}

} // namespace daw
