#pragma once
// NodeKind::bus: the summing point of a bus (05 Topology, MIX-004). The RenderGraph has already
// summed every edge into the bus's input; the node carries that sum on to the bus's insert chain
// and channel strip, which are separate nodes.

#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/Realtime.h"

namespace daw {

class BusNode final : public Node {
public:
    void prepare(const PrepareInfo&) override {}
    void process(ProcessContext&, NodeIO& io) DAW_RT override;
};

} // namespace daw
