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

namespace daw {

// AUTO-003 (T-092, DW-232): for a node with `count` params from slot `first` (its NodeDesc), the
// frame where the block `ctx` jumps: the wrap frame if automation registered a value after the
// wrap for any of them, else 0 (no jump; a wrap at frame 0 or at/after the block's end isn't one,
// like ParamSmoother::next). All of a block's jumps share that frame (one wrap per pass). The
// built-ins with more than a couple of params split their block there: frames [0, frame) ramp to
// this block's values as usual, and from the frame on the params hold their after-wrap values
// (afterWrapOr), so nothing ramps across the loop's discontinuity.
inline uint32_t wrapFrame(const ProcessContext& ctx, ParamID first, uint32_t count, uint32_t numFrames) DAW_RT {
    if (ctx.transport.numSegments != 2) return 0;
    const uint32_t frame = ctx.transport.seg[1].frameOffset;
    if (frame == 0 || frame >= numFrames) return 0;
    float value = 0.0f;
    for (uint32_t i = 0; i < count; ++i)  // CONV-RT-04: bounded by the node's param count
        if (ctx.params.afterWrap(first + i, value)) return frame;
    return 0;
}

// The value slot `id` takes after this block's wrap: the registered after-wrap value, or the
// slot's own value when automation registered none (an unautomated param doesn't jump).
inline float afterWrapOr(const ProcessContext& ctx, ParamID id) DAW_RT {
    float value = 0.0f;
    return ctx.params.afterWrap(id, value) ? value : ctx.params.get(id);
}

} // namespace daw
