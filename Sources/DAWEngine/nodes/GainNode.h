#pragma once
// MIX-007: NodeKind::gain, one smoothed level on a stereo signal, with an optional mute. The model
// uses it as a send: a gain node on an edge into a bus, fed by the strip (post-fader) or by
// whatever feeds the strip (pre-fader). See 05 MIX-007 for the routing.
//
// Params, relative to NodeDesc::firstParam, read once per block (ENG-021) and ramped linearly
// across it from the previous block's end (ENG-022):
//   0 level  linear amplitude, 0 (−∞ dB) … 3.98 (+12 dB), default 1, like the model's
//            Send.level. Out-of-range values are clamped; NaN is silence.
//   1 mute   switch: muted when ≥ 0.5, default 0, NaN off. A send needs it (numParams 2): the
//            model writes the track's resolved mute (manual or solo, MIX-006) here as well as
//            into the strip's mute slot, so a muted track's sends go silent, pre-fader included.
//            A plain gain node may leave it out (numParams 1) and is never muted.
// A mute fades out (or in) over one block, like the strip's. The first block after prepare()
// jumps to the slot values instead of ramping up from 0.

#include <array>
#include <cstdint>
#include <span>

#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/ParamSmoother.h"
#include "core/Realtime.h"
#include "dsp/ParamInfo.h"

namespace daw {

class GainNode final : public Node {
public:
    static constexpr uint32_t kLevel = 0;
    static constexpr uint32_t kMute = 1;
    static constexpr uint32_t kNumParams = 2;     // a send
    static constexpr uint32_t kMinNumParams = 1;  // a plain gain, no mute slot
    static constexpr float kMaxLevel = 3.98107171f;  // +12 dB, as ChannelStrip::kMaxGain

    static constexpr std::array<ParamInfo, kNumParams> kParamInfo{{
        {kLevel, "level", "Level", 0.0f, kMaxLevel, 1.0f, ParamInfo::Curve::db, "dB", true},
        {kMute, "mute", "Mute", 0.0f, 1.0f, 0.0f, ParamInfo::Curve::linear, "", true},
    }};
    static std::span<const ParamInfo> paramInfo() { return kParamInfo; }

    // `numParams` as in the NodeDesc: kNumParams reads the mute slot, kMinNumParams doesn't.
    GainNode(ParamID firstParam, uint32_t numParams)
        : firstParam_(firstParam), hasMute_(numParams >= kNumParams) {}

    void prepare(const PrepareInfo& info) override;
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;

private:
    ParamID firstParam_;
    bool hasMute_;
    ParamSmoother level_;
    ParamSmoother mute_;  // 1 open … 0 muted
    bool primed_ = false;
};

} // namespace daw
