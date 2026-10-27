#pragma once
// DSP-010, MIX-005: NodeKind::channelStrip, the gain and pan stage at the end of a track or bus.
// T-013 covers gain and pan; mute, solo, phase invert and the GraphBuilder side of metering
// arrive with T-020.
//
// Params, relative to NodeDesc::firstParam (numParams >= 2), read once per block (ENG-021) and
// ramped across it with ParamSmoother (ENG-022):
//   0 gain  linear amplitude, 0 (−∞ dB) … 3.98 (+12 dB), default 1. Linear, as in the model's
//           ChannelStripState.gain, so a slot never has to hold −∞.
//   1 pan   −1 (left) … 1 (right), default 0, −3 dB constant-power law (dsp/PanLaw.h).
// Out-of-range slot values are clamped.
//
// Each block ramps the two channel gains (gain · pan law) linearly from the previous block's
// values to this block's, so the last frame is exact and nothing zippers. A pan move is therefore
// constant-power at block boundaries and linear in between, which is inaudible at block rate.
//
// Metering (MIX-005, DW-048): with a MeterTarget, process() writes the post-fader peak and 300 ms
// RMS (dsp/MeterWindow.h) to Telemetry every block. Until GraphBuilder hands out MeterIDs the
// registered factory makes strips without one.

#include <array>
#include <cstdint>
#include <span>

#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/ParamSmoother.h"
#include "core/Realtime.h"
#include "core/Telemetry.h"
#include "dsp/MeterWindow.h"
#include "dsp/ParamInfo.h"

namespace daw {

// Where a strip writes its meter. At namespace scope because a nested struct's member
// initializers aren't usable in its enclosing class's default arguments.
struct MeterTarget {
    Telemetry* telemetry = nullptr;  // null: no metering
    MeterID id = 0;
};

class ChannelStrip final : public Node {
public:
    static constexpr uint32_t kGain = 0;
    static constexpr uint32_t kPan = 1;
    static constexpr uint32_t kNumParams = 2;
    static constexpr float kMaxGain = 3.98107171f;  // +12 dB

    static constexpr std::array<ParamInfo, kNumParams> kParamInfo{{
        {kGain, "gain", "Gain", 0.0f, kMaxGain, 1.0f, ParamInfo::Curve::db, "dB", true},
        {kPan, "pan", "Pan", -1.0f, 1.0f, 0.0f, ParamInfo::Curve::linear, "", true},
    }};
    static std::span<const ParamInfo> paramInfo() { return kParamInfo; }

    // `firstParam` as in the NodeDesc, whose range must hold kNumParams slots.
    explicit ChannelStrip(ParamID firstParam, MeterTarget meter = {});

    void prepare(const PrepareInfo& info) override;
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;

private:
    ParamID gainParam_;
    ParamID panParam_;
    MeterTarget meter_;
    MeterWindow window_;
    ParamSmoother gain_;
    ParamSmoother pan_;
    // The first block after prepare() jumps to the slot values instead of ramping up from 0:
    // prepare() can't read slots (PrepareInfo carries no table).
    bool primed_ = false;
};

} // namespace daw
