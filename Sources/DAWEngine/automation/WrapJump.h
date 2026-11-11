#pragma once
// AUTO-003 (T-074): what a node asks to honor a loop-wrap jump of an automated slot. Kept out of
// core/ParamSmoother.h, which stays free of graph and transport headers (ENG-023).

#include "core/ParamSlotTable.h"
#include "core/ParamSmoother.h"
#include "core/ProcessContext.h"
#include "core/Realtime.h"

namespace daw {

// The jump of slot `id` in the block `ctx` describes: only in a block with two transport
// segments, at the second one's first frame, and only if automation registered a value after the
// wrap for this block (ParamSlotTable::afterWrap). Nodes on the transport's block (not the MIX-023
// look-ahead block) see the wrap where automation evaluated it.
//
// Several wraps in one block (DW-125, T-089): Engine::render splits such a block into passes with
// at most one wrap each and evaluates automation per pass (ParamSlotTable::beginBlock per pass),
// so the side channel always holds the value after the pass's single wrap, the lane at the loop
// start, and `ctx` here is the pass. Within a loop shorter than a block every pass after the
// first starts at the loop start, so the loop-start value holds from the first wrap on.
inline WrapJump wrapJump(const ProcessContext& ctx, ParamID id) DAW_RT {
    WrapJump jump;
    if (ctx.transport.numSegments != 2) return jump;
    float value = 0.0f;
    if (!ctx.params.afterWrap(id, value)) return jump;
    jump.frame = ctx.transport.seg[1].frameOffset;
    jump.value = value;
    return jump;
}

} // namespace daw
