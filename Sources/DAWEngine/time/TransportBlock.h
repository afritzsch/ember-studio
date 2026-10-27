#pragma once
// 03-time-transport Interfaces: what the transport hands the graph for one block (TIME-005).
// Defined here by T-004, verbatim from the contract, because ProcessContext (ENG-001) holds a
// reference to one and Engine::render must bind a real object every block. Plain data only:
// producing it (advancing the transport, loop segments) is T-008's.

#include <cstdint>

#include "time/TempoMap.h"

namespace daw {

class TempoMap;

struct TransportSegment {
    SamplePos startSample;
    Tick startTick;
    Tick endTick;
    uint32_t frameOffset, numFrames;
    bool afterWrap;
};

struct TransportBlock {
    bool playing, recording;
    uint8_t numSegments;
    TransportSegment seg[2];
    const TempoMap* tempo;
};

} // namespace daw
