#include "automation/AutomationSet.h"

#include "time/TransportSegments.h"

namespace daw {

namespace {

// Writes only a change (bit for bit; a NaN slot always differs), so the generation moves only
// when the value does.
void write(ParamSlotTable& params, ParamID id, float value) DAW_RT {
    if (!(params.get(id) == value)) params.set(id, value);
}

} // namespace

void AutomationSet::apply(const TransportBlock& block, ParamSlotTable& params) DAW_RT {
    if (block.numSegments == 0) {
        // Stopped (or a 0-frame block): the lane's value at the playhead, once per position.
        if (block.tempo == nullptr) return;
        const Tick at = blockStartTick(block);
        if (stoppedWritten_ && at == stoppedAt_) return;
        for (AutomationPlayer& p : players_) write(params, p.target(), p.valueAt(at));
        stoppedWritten_ = true;
        stoppedAt_ = at;
        return;
    }
    stoppedWritten_ = false;
    // AUTO-002: the value at the first segment's start, before any node runs.
    for (AutomationPlayer& p : players_) write(params, p.target(), p.valueAt(block.seg[0].startTick));
    // AUTO-003: a wrap inside the block; the value at the loop start applies from the wrap frame.
    if (block.numSegments == 2)
        for (AutomationPlayer& p : players_) params.setAfterWrap(p.target(), p.valueAt(block.seg[1].startTick));
}

} // namespace daw
