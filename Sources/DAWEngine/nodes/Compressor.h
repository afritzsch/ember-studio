#pragma once
// DSP-031: NodeKind::compressor, a feed-forward compressor with an optional external key on the
// node's sidechain input (MIX-008). 0 latency: no lookahead, so latencySamples() is 0 and a gain
// change starts on the key sample that causes it.
//
// Params, relative to NodeDesc::firstParam, read once per block (ENG-021). Slots beyond
// numParams use their defaults, so a compressor with numParams 0 runs at the defaults. A NaN
// slot reads as the default; other out-of-range values are clamped.
//   0 threshold  dB, −60 … 0, default −20
//   1 ratio      1 … 20 (:1), default 4
//   2 attack     ms, 0.1 … 200, default 10
//   3 release    ms, 1 … 2000, default 100
//   4 knee       dB (full width), 0 … 24, default 6
//   5 makeup     dB, 0 … 24, default 0
//   6 detector   switch: RMS when ≥ 0.5, else peak; default 0 (peak)
// threshold, ratio, knee and makeup ramp linearly across the block (ENG-022, per sample, like
// ParamRamp). attack, release and the detector switch are latched per block: they set how the
// gain moves, not the gain itself, so they can't zipper.
//
// Signal path, per sample n (everything in double, stereo-linked: one gain for all channels):
//   key       the sidechain input when one is routed (NodeIO::sidechain non-empty), else the
//             node's own input. Every key channel counts.
//   level     peak: x = 20·log10(max_c |key_c[n]|)
//             RMS:  m[n] = β·m[n−1] + (1 − β)·mean_c key_c[n]², x = 10·log10(m[n]),
//                   β = exp(−1 / (kRmsMs/1000 · rate))
//             (x is floored at kFloorDb; a level of 0 reads as kFloorDb)
//   computer  c = compressorGainDb(x, threshold, ratio, knee)   (dsp/GainComputer.h, ≤ 0 dB)
//   ballistics (log domain, smooth branching):
//             e[n] = α·e[n−1] + (1 − α)·c,  α = exp(−1 / (t/1000 · rate)) with t = attack when
//             c < e[n−1] (more reduction), else release. e starts at 0 dB after prepare().
//   output    out_c[n] = in_c[n] · 10^((e[n] + makeup) / 20)
// e and m snap to exactly 0 once they are within kSnapDb / kSnapMs of it, so silence settles to
// exact unity gain and nothing decays into denormals (DSP-040). Silence in is silence out: the
// gain only multiplies the input.
//
// NaN guard (DSP-040): a block whose input or key holds a NaN or ±Inf outputs silence and starts
// the detector afresh (e = 0, m = 0), so one bad block can't poison later ones. It is counted in
// nanBlocks(); Telemetry has no processor NaN counter yet (DW-142).
//
// Gain-reduction meter (DSP-031): with a MeterTarget, process() writes the gain reduction to the
// node's telemetry meter every block, as linear gain factors (1 = no reduction, makeup not
// included): MeterReading::peak is the block's deepest reduction (the smallest factor) and
// MeterReading::rms the factor at the block's last frame. The registered factory meters
// (NodeKindInfo::meters), so the facade's meter(node) reads it like a strip's (DW-071).
//
// reset() keeps the envelope: an effect keeps running across a locate (TIME-008), like any
// insert processing a continuous input.

#include <array>
#include <atomic>
#include <cstdint>
#include <span>

#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/ParamSmoother.h"
#include "core/Realtime.h"
#include "core/Telemetry.h"
#include "dsp/ParamInfo.h"
#include "graph/NodeRegistry.h"
#include "nodes/ChannelStrip.h"  // MeterTarget

namespace daw {

class Compressor final : public Node {
public:
    static constexpr uint32_t kThreshold = 0;
    static constexpr uint32_t kRatio = 1;
    static constexpr uint32_t kAttack = 2;
    static constexpr uint32_t kRelease = 3;
    static constexpr uint32_t kKnee = 4;
    static constexpr uint32_t kMakeup = 5;
    static constexpr uint32_t kDetector = 6;
    static constexpr uint32_t kNumParams = 7;

    static constexpr double kRmsMs = 10.0;      // RMS detector averaging time constant
    static constexpr double kFloorDb = -200.0;  // detector level floor
    static constexpr double kSnapDb = 1e-9;     // |e| below this is 0 dB
    static constexpr double kSnapMs = 1e-20;    // m below this (−200 dB) is 0

    static constexpr std::array<ParamInfo, kNumParams> kParamInfo{{
        {kThreshold, "threshold", "Threshold", -60.0f, 0.0f, -20.0f, ParamInfo::Curve::linear, "dB", true},
        {kRatio, "ratio", "Ratio", 1.0f, 20.0f, 4.0f, ParamInfo::Curve::log, ":1", true},
        {kAttack, "attack", "Attack", 0.1f, 200.0f, 10.0f, ParamInfo::Curve::log, "ms", true},
        {kRelease, "release", "Release", 1.0f, 2000.0f, 100.0f, ParamInfo::Curve::log, "ms", true},
        {kKnee, "knee", "Knee", 0.0f, 24.0f, 6.0f, ParamInfo::Curve::linear, "dB", true},
        {kMakeup, "makeup", "Makeup", 0.0f, 24.0f, 0.0f, ParamInfo::Curve::linear, "dB", true},
        {kDetector, "detector", "RMS Detector", 0.0f, 1.0f, 0.0f, ParamInfo::Curve::linear, "", false},
    }};
    static std::span<const ParamInfo> paramInfo() { return kParamInfo; }

    // Non-RT. The registry entry for NodeKind::compressor (registerBuiltinNodes): meters into
    // `telemetry` with the MeterID GraphBuilder assigns; null means no metering.
    static NodeKindInfo kindInfo(Telemetry* telemetry);

    // `firstParam` / `numParams` as in the NodeDesc.
    Compressor(ParamID firstParam, uint32_t numParams, MeterTarget meter = {})
        : firstParam_(firstParam), numParams_(numParams), meter_(meter) {}

    void prepare(const PrepareInfo& info) override;
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;

    // The current gain reduction e in dB (≤ 0, makeup not included). For tests and meters.
    double gainReductionDb() const DAW_RT { return env_; }
    // Blocks silenced by the NaN guard since construction. Any thread.
    uint64_t nanBlocks() const { return nanBlocks_.load(std::memory_order_relaxed); }

private:
    float param(const ProcessContext& ctx, uint32_t index) const DAW_RT;

    ParamID firstParam_;
    uint32_t numParams_;
    MeterTarget meter_;
    double sampleRate_ = 48000.0;
    double rmsCoeff_ = 0.0;  // β
    double env_ = 0.0;       // e, dB
    double ms_ = 0.0;        // m, linear power
    ParamSmoother threshold_, ratio_, knee_, makeup_;
    bool primed_ = false;  // the first block jumps to the slot values (see ChannelStrip)
    std::atomic<uint64_t> nanBlocks_{0};
};

} // namespace daw
