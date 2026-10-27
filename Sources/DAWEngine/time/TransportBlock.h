#pragma once
// 03-time-transport Interfaces: what the transport hands the graph for one block (TIME-005),
// verbatim from the contract. Plain data: Transport::advance (Transport.h) produces it, and
// TransportSegments.h says what the fields mean and how timeline nodes read them (TIME-006).

#include <cstdint>

#include "time/TempoMap.h"

namespace daw {

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
