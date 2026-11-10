#pragma once
// REC-010/011 (T-053): the seam between Engine::render and live MIDI input (record/MidiInputRouter).
// Engine knows only this interface, so core/ doesn't depend on record/.
//
// Each rendered block calls beginBlock once, after the transport has advanced and after any
// MIX-023 pre-roll, and endBlock once after the graph ran; nodes read the block's live events in
// between. A pre-roll chunk is not a block: it renders ahead and is thrown away, so live input
// must not be consumed by it. A block that renders no graph calls idleBlock instead, so inputs
// keep draining.

#include <cstdint>

#include "core/Realtime.h"

namespace daw {

class Transport;

class LiveMidiInput {
public:
    virtual ~LiveMidiInput() = default;

    // RT. `cycleHostTicks` is the host time the device IO cycle started at (mach_absolute_time),
    // for the first block of a cycle; 0 for the other blocks of a cycle and for offline renders.
    virtual void beginBlock(const Transport& transport, uint32_t numFrames, double sampleRate,
                            uint64_t cycleHostTicks) DAW_RT = 0;
    virtual void endBlock() DAW_RT = 0;
    virtual void idleBlock(uint32_t numFrames, uint64_t cycleHostTicks) DAW_RT = 0;
};

} // namespace daw
