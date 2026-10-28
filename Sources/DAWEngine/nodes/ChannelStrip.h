#pragma once
// DSP-010, MIX-005: NodeKind::channelStrip, the gain and pan stage at the end of a track or bus.
//
// Params, relative to NodeDesc::firstParam (numParams >= kNumParams), read once per block
// (ENG-021) and ramped across it with ParamSmoother (ENG-022):
//   0 gain   linear amplitude, 0 (−∞ dB) … 3.98 (+12 dB), default 1. Linear, as in the model's
//            ChannelStripState.gain, so a slot never has to hold −∞.
//   1 pan    −1 (left) … 1 (right), default 0, −3 dB constant-power law (dsp/PanLaw.h).
//   2 mute   switch: muted when ≥ 0.5, default 0. The model writes the solo-resolved mute here
//            (MIX-006), so mute and solo changes never rebuild the graph.
//   3 phase  switch: polarity inverted when ≥ 0.5, default 0. Applied to the input, before gain
//            and pan.
// Out-of-range slot values are clamped; a NaN switch reads as off, a NaN gain as silence.
//
// Each block ramps the two channel gains (polarity · mute · gain · pan law) linearly from the
// previous block's values to this block's, so the last frame is exact and nothing zippers. A pan
// move is therefore constant-power at block boundaries and linear in between, which is inaudible
// at block rate. The switches ramp too: a mute fades out (or in) over one block, and a phase flip
// passes linearly through 0 from +1 to −1, so neither clicks (D-13: no sub-block splitting).
//
// Everything is a per-channel multiply, so "phase before gain/pan" only fixes the documented
// order; it changes no sample. What it does fix is the tap: a pre-fader send taps the strip's
// input (MIX-007), so it sees neither the phase switch nor mute.
//
// Metering (MIX-005, DW-048): with a MeterTarget, process() writes the post-fader (post-mute)
// peak and 300 ms RMS (dsp/MeterWindow.h) to Telemetry every block. The registered factory uses
// the MeterID GraphBuilder assigned (NodeCreateInfo::meter).

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
    static constexpr uint32_t kMute = 2;
    static constexpr uint32_t kPhase = 3;
    static constexpr uint32_t kNumParams = 4;
    static constexpr float kMaxGain = 3.98107171f;  // +12 dB

    static constexpr std::array<ParamInfo, kNumParams> kParamInfo{{
        {kGain, "gain", "Gain", 0.0f, kMaxGain, 1.0f, ParamInfo::Curve::db, "dB", true},
        {kPan, "pan", "Pan", -1.0f, 1.0f, 0.0f, ParamInfo::Curve::linear, "", true},
        {kMute, "mute", "Mute", 0.0f, 1.0f, 0.0f, ParamInfo::Curve::linear, "", true},
        {kPhase, "phase", "Phase Invert", 0.0f, 1.0f, 0.0f, ParamInfo::Curve::linear, "", false},
    }};
    static std::span<const ParamInfo> paramInfo() { return kParamInfo; }

    // `firstParam` as in the NodeDesc, whose range must hold kNumParams slots.
    explicit ChannelStrip(ParamID firstParam, MeterTarget meter = {});

    void prepare(const PrepareInfo& info) override;
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;

private:
    ParamID firstParam_;
    MeterTarget meter_;
    MeterWindow window_;
    ParamSmoother gain_;
    ParamSmoother pan_;
    ParamSmoother mute_;      // 1 open … 0 muted
    ParamSmoother polarity_;  // +1 … −1
    // The first block after prepare() jumps to the slot values instead of ramping up from 0:
    // prepare() can't read slots (PrepareInfo carries no table).
    bool primed_ = false;
};

} // namespace daw
