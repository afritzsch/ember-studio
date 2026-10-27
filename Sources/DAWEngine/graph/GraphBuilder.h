#pragma once
// MIX-001: compiles a GraphDescription (05 Interfaces) into a RenderGraph. It is the engine's
// only producer of RenderGraphs; GraphCompiler runs it on daw.compile.
//
// build() validates the whole description before it touches the NodePool, so a rejected
// description changes nothing:
//   - node IDs unique, every kind registered (NodeRegistry), params in the table (DW-030);
//   - edges between known nodes, toPort 0, edge IDs unique, audio/sidechain edges only out of
//     nodes with audio output (MIX-004);
//   - one master node, of kind master, with no outgoing edges; it runs last (MIX-009);
//   - acyclic (MIX-002), and a valid tempo map (TIME-003).
// Then it reuses or creates node instances (DW-036, ENG-013), plans buffers (MIX-003) and
// assembles the graph. MIDI edges order nodes but carry no data yet (T-040).
//
// Not thread-safe: one builder per NodePool, used from one thread at a time.

#include <cstdint>
#include <memory>
#include <unordered_map>
#include <vector>

#include "core/Node.h"
#include "core/NodePool.h"
#include "core/ParamSlotTable.h"
#include "core/RenderGraph.h"
#include "core/Result.h"
#include "daw/GraphDescription.h"
#include "graph/NodeRegistry.h"

namespace daw {

class GraphBuilder {
public:
    // Nodes are prepared at `sampleRate`, for blocks of up to `maxBlock` frames, stereo in and
    // out (MIX-004). A format change needs a new builder, which re-creates every node.
    GraphBuilder(NodeRegistry registry, double sampleRate, uint32_t maxBlock = kMaxBlock);

    // MIX-001. Non-RT; meant for daw.compile. Errors:
    //   cycle: the edges form a cycle. Error::nodes holds the NodeIDs on it, ascending, and the
    //     message is "cycle: " followed by the same IDs (MIX-002, DW-050).
    //   invalidArgument: the description is malformed.
    //   unsupported: a node's kind has no factory.
    //   or whatever a factory returns.
    // On success, nodes this builder created that the description no longer has are removed
    // from `pool`; graphs that still use them keep them alive until they are reclaimed.
    Result<std::unique_ptr<RenderGraph>> build(const GraphDescription& desc, NodePool& pool,
                                               ParamSlotTable& params);

    // DW-048: the MeterID handed to `node`'s factory (see NodeCreateInfo), or kNoMeter.
    MeterID meterOf(NodeID node) const;

    double sampleRate() const { return sampleRate_; }
    uint32_t maxBlock() const { return maxBlock_; }

private:
    // DW-036: what a pooled instance was created from. A node whose kind, configVersion or param
    // range differs gets a new instance; one a live graph may be rendering is never re-prepared.
    struct Instance {
        NodeKind kind;
        uint32_t configVersion;
        ParamID firstParam;
        uint32_t numParams;
        // The instance this builder put in the pool. Weak, so the last reference to a node is
        // never the builder's (nodes are destroyed on daw.reclaim, ENG-013).
        std::weak_ptr<Node> node;
    };

    NodeRegistry registry_;
    double sampleRate_;
    uint32_t maxBlock_;
    std::unordered_map<NodeID, Instance> instances_;

    // DW-048: MeterIDs of metering nodes, kept per NodeID; released IDs are reused.
    MeterID assignMeter(NodeID node);
    std::unordered_map<NodeID, MeterID> meters_;
    std::vector<MeterID> freeMeters_;
    MeterID nextMeter_ = 0;
};

} // namespace daw
