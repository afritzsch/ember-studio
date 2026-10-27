#include "graph/BusNode.h"

#include "graph/PassThrough.h"

namespace daw {

void BusNode::process(ProcessContext&, NodeIO& io) DAW_RT { passThrough(io); }

} // namespace daw
