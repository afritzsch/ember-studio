#pragma once
// MIX-007: NodeKind::gain, one smoothed level on a stereo signal. The model uses it as a send: a
// gain node on an edge into a bus, fed by the strip (post-fader) or by whatever feeds the strip
// (pre-fader). See 05 MIX-007 for the routing.
//
// Param, relative to NodeDesc::firstParam (numParams >= kNumParams), read once per block
// (ENG-021) and ramped linearly across it from the previous block's end (ENG-022):
//   0 level  linear amplitude, 0 (−∞ dB) … 3.98 (+12 dB), default 1, like the model's
//            Send.level. Out-of-range values are clamped; NaN is silence.
// The first block after prepare() jumps to the slot's value instead of ramping up from 0.

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
    static constexpr uint32_t kNumParams = 1;
    static constexpr float kMaxLevel = 3.98107171f;  // +12 dB, as ChannelStrip::kMaxGain

    static constexpr std::array<ParamInfo, kNumParams> kParamInfo{{
        {kLevel, "level", "Level", 0.0f, kMaxLevel, 1.0f, ParamInfo::Curve::db, "dB", true},
    }};
    static std::span<const ParamInfo> paramInfo() { return kParamInfo; }

    explicit GainNode(ParamID firstParam) : levelParam_(firstParam + kLevel) {}

    void prepare(const PrepareInfo& info) override;
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;

private:
    ParamID levelParam_;
    ParamSmoother level_;
    bool primed_ = false;
};

} // namespace daw
