#pragma once
// AUTO-001 (T-074): one compiled automation lane. GraphBuilder makes one per enabled lane of the
// GraphDescription (AutomationCompiler.h); the RenderGraph owns them in an AutomationSet.
//
// The points are a sorted array (strictly increasing ticks), fixed for the graph's lifetime. The
// player caches the index of the segment it evaluated last, because playback asks for ticks that
// move forward a block at a time: the cached segment or the next one is the answer almost
// always, and anything else (a locate, a loop wrap) is a binary search, O(log n). The cursor is
// audio-thread state; a new graph starts with a fresh one.

#include <cstdint>
#include <vector>

#include "automation/AutomationCurve.h"
#include "automation/ParamMapping.h"
#include "core/ParamSlotTable.h"
#include "core/Realtime.h"

namespace daw {

class AutomationPlayer {
public:
    // Non-RT. `points` sorted by strictly increasing tick and non-empty (AutomationCompiler
    // checks it).
    AutomationPlayer(uint64_t laneID, ParamID target, std::vector<AutomationPoint> points, ParamMapping mapping);

    uint64_t laneID() const DAW_RT { return laneID_; }
    ParamID target() const DAW_RT { return target_; }
    const ParamMapping& mapping() const DAW_RT { return mapping_; }
    const std::vector<AutomationPoint>& points() const { return points_; }

    // AUTO-004: the lane's normalized value at `tick`. RT; moves the cursor.
    float normalizedAt(Tick tick) DAW_RT;
    // AUTO-002/008: the value the target slot gets at `tick` (normalizedAt through the mapping).
    float valueAt(Tick tick) DAW_RT { return mapping_.map(normalizedAt(tick)); }

    // Diagnostics and tests: the segment the cursor sits on, and how many lookups needed a binary
    // search (the rest were the cached segment or the next one).
    uint32_t cursor() const { return cursor_; }
    uint64_t searches() const { return searches_; }

private:
    // The last point with tick <= `tick`, or 0 when `tick` is before the first point.
    uint32_t seek(Tick tick) DAW_RT;

    uint64_t laneID_;
    ParamID target_;
    std::vector<AutomationPoint> points_;
    ParamMapping mapping_;
    uint32_t cursor_ = 0;  // audio thread only
    uint64_t searches_ = 0;
};

} // namespace daw
