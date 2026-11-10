#pragma once
// AUTO-001..003, AUTO-005 (T-074): a RenderGraph's automation players and the per-block step
// that drives them. Engine::render calls apply() once per block, after the transport has laid
// the block out and before the pre-roll (MIX-023) and the nodes, so every node reads this block's
// value from its slot (AUTO-002).
//
// While playing (the block has segments):
//   - each lane is evaluated at seg[0].startTick and the value written into its target slot;
//   - with a loop wrap inside the block (two segments, AUTO-003), the lane is evaluated at
//     seg[1].startTick too and that value is registered as the slot's value after the wrap
//     (ParamSlotTable::setAfterWrap). Nodes that honor it (ParamSmoother's WrapJump: the channel
//     strip and the send/gain node) ramp to the first value over segment 1 and jump to the second
//     at the wrap frame, never ramping across the loop's discontinuity. Others ramp over the
//     whole block to the first value and pick up the second in the next block.
//   - AUTO-005 `read`: the lane wins over SetParam. A value written by the model between blocks
//     is overwritten at the next block start. `off` lanes never reach the RenderGraph.
// While stopped (no segments), each lane writes its value at the playhead (blockStartTick) once
// whenever the stopped position or the graph changes: after a stop, a locate while stopped, or a
// lane edit. A SetParam made while stopped then holds until playback starts or the playhead
// moves (the engine half of AUTO-007; what the controls show and how a stopped edit reaches the
// lane is T-075's).
// A slot is written only when its value changes, so the slot generation (and with it a plugin's
// param push, PLUG-015/AUTO-009) moves only when automation actually changes something.
//
// AUTO-010 / MIX-025: automation is not latency compensated. It runs on the transport's block,
// not the look-ahead block timeline nodes get, so a param behind L samples of latency changes L
// samples early.

#include <cstdint>
#include <utility>
#include <vector>

#include "automation/AutomationPlayer.h"
#include "core/ParamSlotTable.h"
#include "core/Realtime.h"
#include "time/TransportBlock.h"

namespace daw {

class AutomationSet {
public:
    explicit AutomationSet(std::vector<AutomationPlayer> players) : players_(std::move(players)) {}
    AutomationSet(const AutomationSet&) = delete;
    AutomationSet& operator=(const AutomationSet&) = delete;

    // RT, the render thread, once per block. `block.tempo` must be set (Transport::advance does).
    void apply(const TransportBlock& block, ParamSlotTable& params) DAW_RT;

    uint32_t size() const DAW_RT { return static_cast<uint32_t>(players_.size()); }
    const AutomationPlayer& player(uint32_t i) const { return players_[i]; }

private:
    std::vector<AutomationPlayer> players_;
    // Audio thread only: the stopped position last written (AUTO-005 "while stopped").
    bool stoppedWritten_ = false;
    Tick stoppedAt_ = 0;
};

} // namespace daw
