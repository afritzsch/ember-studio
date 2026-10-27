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
#include "core/Realtime.h"

namespace daw {

struct ParamRamp {
    float start = 0.0f;  // the previous block's last value (not itself rendered in this block)
    float target = 0.0f; // the value at this block's last sample
    uint32_t numFrames = 0;

    bool isConstant() const DAW_RT { return start == target; }

    // The per-sample increment. Values are start + step * (i + 1), not an accumulated sum, so
    // rounding doesn't drift across a 4096-frame block.
    float step() const DAW_RT {
        return numFrames == 0 ? 0.0f : (target - start) / static_cast<float>(numFrames);
    }

    float at(uint32_t i) const DAW_RT {
        DAW_RT_ASSERT(i < numFrames);
        return i + 1 == numFrames ? target : start + step() * static_cast<float>(i + 1);
    }

    // out[0 … numFrames) = the ramp. `out` may be null when numFrames is 0.
    void fill(float* out) const DAW_RT {
        if (numFrames == 0) return;
        const float s = step();
        for (uint32_t i = 0; i + 1 < numFrames; ++i) out[i] = start + s * static_cast<float>(i + 1);
        out[numFrames - 1] = target;
    }

    // samples[i] *= the ramp, e.g. a gain stage. `samples` may be null when numFrames is 0.
    void multiply(float* samples) const DAW_RT {
        if (numFrames == 0) return;
        if (isConstant()) {
            for (uint32_t i = 0; i < numFrames; ++i) samples[i] *= target;
            return;
        }
        const float s = step();
        for (uint32_t i = 0; i + 1 < numFrames; ++i) samples[i] *= start + s * static_cast<float>(i + 1);
        samples[numFrames - 1] *= target;
    }
};

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

    // ENG-021: the one read of the slot for this block, then next().
    ParamRamp next(const ParamSlotTable& params, ParamID id, uint32_t numFrames) DAW_RT {
        return next(params.get(id), numFrames);
    }

private:
    float current_ = 0.0f;
};

} // namespace daw
