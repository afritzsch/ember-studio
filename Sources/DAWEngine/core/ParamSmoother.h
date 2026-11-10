#pragma once
// ENG-022: per-block linear param ramps (D-13: no sub-block splitting), so a value that jumps
// between blocks doesn't zipper. A node keeps one ParamSmoother per continuous param, reads the
// slot once per block (ENG-021), and ramps from where the previous block ended to the new value
// across this block:
//
//   value[i] = start + (target - start) * (i + 1) / numFrames,   i = 0 … numFrames - 1
//
// The block's last sample is exactly `target` and the next block starts from there, so the
// sequence is continuous across blocks. An unchanged value gives a constant block.
//
// Both types are trivially copyable and allocation-free; everything is RT-safe.

#include <cstdint>

#include "core/ParamSlotTable.h"
#include "core/ProcessContext.h"
#include "core/Realtime.h"

namespace daw {

struct ParamRamp {
    static constexpr uint32_t kNoJump = 0xFFFF'FFFFu;

    float start = 0.0f;  // the previous block's last value (not itself rendered in this block)
    float target = 0.0f; // the value at this block's last sample (at frame jumpAt − 1 with a jump)
    uint32_t numFrames = 0;
    // AUTO-003 (T-074): a loop wrap inside the block where the value jumps. With jumpAt in
    // 1…numFrames − 1, the ramp runs from `start` to `target` over frames [0, jumpAt) and holds
    // `after` from frame jumpAt on, so nothing ramps across the wrap. kNoJump (the default):
    // the ramp spans the whole block, as before.
    uint32_t jumpAt = kNoJump;
    float after = 0.0f;

    bool jumps() const DAW_RT { return jumpAt > 0 && jumpAt < numFrames; }
    // Frames the linear part covers.
    uint32_t rampFrames() const DAW_RT { return jumps() ? jumpAt : numFrames; }
    // The value at the block's last frame, where the next block starts from.
    float end() const DAW_RT { return jumps() ? after : target; }

    bool isConstant() const DAW_RT { return start == target && end() == target; }

    // The per-sample increment of the linear part. Values are start + step * (i + 1), not an
    // accumulated sum, so rounding doesn't drift across a 4096-frame block.
    float step() const DAW_RT {
        const uint32_t frames = rampFrames();
        return frames == 0 ? 0.0f : (target - start) / static_cast<float>(frames);
    }

    float at(uint32_t i) const DAW_RT {
        DAW_RT_ASSERT(i < numFrames);
        if (jumps() && i >= jumpAt) return after;
        return i + 1 == rampFrames() ? target : start + step() * static_cast<float>(i + 1);
    }

    // out[0 … numFrames) = the ramp. `out` may be null when numFrames is 0.
    void fill(float* out) const DAW_RT {
        if (numFrames == 0) return;
        const uint32_t frames = rampFrames();
        const float s = step();
        for (uint32_t i = 0; i + 1 < frames; ++i) out[i] = start + s * static_cast<float>(i + 1);
        out[frames - 1] = target;
        for (uint32_t i = frames; i < numFrames; ++i) out[i] = after;
    }

    // samples[i] *= the ramp, e.g. a gain stage. `samples` may be null when numFrames is 0.
    void multiply(float* samples) const DAW_RT {
        if (numFrames == 0) return;
        if (isConstant()) {
            for (uint32_t i = 0; i < numFrames; ++i) samples[i] *= target;
            return;
        }
        const uint32_t frames = rampFrames();
        const float s = step();
        for (uint32_t i = 0; i + 1 < frames; ++i) samples[i] *= start + s * static_cast<float>(i + 1);
        samples[frames - 1] *= target;
        for (uint32_t i = frames; i < numFrames; ++i) samples[i] *= after;
    }
};

// AUTO-003 (T-074): where and to what a slot jumps inside this block (a loop wrap with
// automation on it); frame kNoJump: no jump. wrapJump() reads it for a node.
struct WrapJump {
    uint32_t frame = ParamRamp::kNoJump;
    float value = 0.0f;

    bool active() const DAW_RT { return frame != ParamRamp::kNoJump; }
};

// The jump of slot `id` in the block `ctx` describes: only in a block with two transport
// segments, at the second one's first frame, and only if automation registered a value after the
// wrap for this block (ParamSlotTable::afterWrap). Nodes on the transport's block (not the MIX-023
// look-ahead block) see the wrap where automation evaluated it.
inline WrapJump wrapJump(const ProcessContext& ctx, ParamID id) DAW_RT {
    WrapJump jump;
    if (ctx.transport.numSegments != 2) return jump;
    float value = 0.0f;
    if (!ctx.params.afterWrap(id, value)) return jump;
    jump.frame = ctx.transport.seg[1].frameOffset;
    jump.value = value;
    return jump;
}

class ParamSmoother {
public:
    ParamSmoother() = default;
    explicit ParamSmoother(float initial) : current_(initial) {}

    // Jumps to `value` with no ramp. Nodes call it from prepare() with the slot's value, so the
    // first block doesn't ramp up from 0.
    void reset(float value) DAW_RT { current_ = value; }
    float current() const DAW_RT { return current_; }

    // ENG-022: call once per block with the value read for this block. Returns the ramp from the
    // previous block's end to `target` and makes `target` current. A 0-frame block (ENG-004)
    // renders nothing, so it leaves the smoother as it was and the next real block ramps.
    ParamRamp next(float target, uint32_t numFrames) DAW_RT {
        if (numFrames == 0) return ParamRamp{current_, current_, 0};
        const ParamRamp ramp{current_, target, numFrames};
        current_ = target;
        return ramp;
    }

    // AUTO-003 (T-074): like next(target, numFrames), but with `jump` active (a frame inside the
    // block) the ramp reaches `target` at the jump frame and holds `jump.value` after it, which
    // becomes current. The caller maps jump.value the way it maps the slot value.
    ParamRamp next(float target, uint32_t numFrames, WrapJump jump) DAW_RT {
        if (numFrames == 0 || !jump.active() || jump.frame == 0 || jump.frame >= numFrames)
            return next(target, numFrames);
        const ParamRamp ramp{current_, target, numFrames, jump.frame, jump.value};
        current_ = jump.value;
        return ramp;
    }

    // ENG-021: the one read of the slot for this block, then next().
    ParamRamp next(const ParamSlotTable& params, ParamID id, uint32_t numFrames) DAW_RT {
        return next(params.get(id), numFrames);
    }

private:
    float current_ = 0.0f;
};

} // namespace daw
