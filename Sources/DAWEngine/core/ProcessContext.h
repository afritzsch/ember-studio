#pragma once
// ENG-001: per-block context handed to every Node::process(). Built once per block by
// Engine::render and shared by all nodes in that block.

#include <cstdint>

#include "time/TransportBlock.h"

namespace daw {

class ParamSlotTable;

struct ProcessContext {
    uint32_t numFrames;
    double sampleRate;
    const TransportBlock& transport;  // 03-time-transport
    const ParamSlotTable& params;     // ENG-021: nodes read their slots once per block
};

} // namespace daw
