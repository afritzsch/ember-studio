#pragma once
// DSP-030: NodeKind::eq, a stereo six-band EQ: high-pass → low shelf → peak 1 → peak 2 → high shelf
// → low-pass, RBJ biquads in TDF-II (dsp/Biquad.h), 12 dB/oct at the HP and LP. 0 latency.
//
// Params, relative to NodeDesc::firstParam, read once per block (ENG-021). Slots beyond numParams
// use their defaults, so an EQ with numParams 0 runs at the defaults. A NaN slot reads as the
// default; other out-of-range values are clamped. Frequencies above 0.49 · rate are treated as
// 0.49 · rate.
//   band        on (default)   freq Hz, 20…20000, log   gain dB, ±24   Q, 0.1…10, log
//   0  HP       0  (off)       1  (30)                  -              2  (0.7071)
//   1  low      3  (on)        4  (100)                 5  (0)         6  (0.7071)
//   2  peak 1   7  (on)        8  (400)                 9  (0)         10 (1)
//   3  peak 2   11 (on)        12 (2500)                13 (0)         14 (1)
//   4  high     15 (on)        16 (8000)                17 (0)         18 (0.7071)
//   5  LP       19 (off)       20 (20000)               -              21 (0.7071)
// A band's "on" is a switch (on at ≥ 0.5). Every band that is on at 0 dB, or off, is H(z) = 1 and
// passes its input bit for bit, so the default EQ is exactly flat.
//
// Coefficient changes (DSP-030). Coefficients are recomputed once per block, only when a band's
// params changed. A band whose coefficients changed moves to them linearly across the block,
// coefficient by coefficient, ending exactly on the new ones at the last frame (the ENG-022 ramp
// shape); between stable biquads every interpolated filter is stable (dsp/Biquad.h). TDF-II
// state carries across. The first block after prepare() jumps (like the other effects).
//
// Silence and NaN (DSP-040). Filter state below BiquadState::kSnap is stored as exactly 0, so
// after the input stops the output reaches exact 0 in finite time. A block whose input holds a
// NaN or ±Inf, or whose output went non-finite, outputs silence and clears the filter state; it
// is counted in nanBlocks() and, when the factory was given one, in Telemetry (DW-142).
//
// reset() keeps the filter state: an effect keeps running across a locate (TIME-008). A mono
// input feeds both channels; no input is silence and the filters ring on; channels beyond
// stereo are silent. The same input and params give the same bits for any block sizes (ENG-004).

#include <array>
#include <atomic>
#include <cstdint>
#include <span>

#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/Realtime.h"
#include "core/Telemetry.h"
#include "dsp/Biquad.h"
#include "dsp/ParamInfo.h"
#include "graph/NodeRegistry.h"

namespace daw {

class Eq final : public Node {
public:
    static constexpr uint32_t kNumBands = 6;
    enum Band : uint32_t { kHighPass = 0, kLowShelf, kPeak1, kPeak2, kHighShelf, kLowPass };

    static constexpr uint32_t kHpOn = 0, kHpFreq = 1, kHpQ = 2;
    static constexpr uint32_t kLowOn = 3, kLowFreq = 4, kLowGain = 5, kLowQ = 6;
    static constexpr uint32_t kPeak1On = 7, kPeak1Freq = 8, kPeak1Gain = 9, kPeak1Q = 10;
    static constexpr uint32_t kPeak2On = 11, kPeak2Freq = 12, kPeak2Gain = 13, kPeak2Q = 14;
    static constexpr uint32_t kHighOn = 15, kHighFreq = 16, kHighGain = 17, kHighQ = 18;
    static constexpr uint32_t kLpOn = 19, kLpFreq = 20, kLpQ = 21;
    static constexpr uint32_t kNumParams = 22;

    static constexpr float kMinFreq = 20.0f, kMaxFreq = 20000.0f;
    static constexpr float kMaxGainDb = 24.0f;
    static constexpr float kMinQ = 0.1f, kMaxQ = 10.0f;
    static constexpr float kButterworthQ = 0.70710678f;
    static constexpr double kMaxFreqRatio = 0.49;  // of the sample rate

    static constexpr std::array<ParamInfo, kNumParams> kParamInfo{{
        {kHpOn, "hpOn", "HP On", 0.0f, 1.0f, 0.0f, ParamInfo::Curve::linear, "", false},
        {kHpFreq, "hpFreq", "HP Freq", kMinFreq, kMaxFreq, 30.0f, ParamInfo::Curve::log, "Hz", true},
        {kHpQ, "hpQ", "HP Q", kMinQ, kMaxQ, kButterworthQ, ParamInfo::Curve::log, "", true},
        {kLowOn, "lowOn", "Low On", 0.0f, 1.0f, 1.0f, ParamInfo::Curve::linear, "", false},
        {kLowFreq, "lowFreq", "Low Freq", kMinFreq, kMaxFreq, 100.0f, ParamInfo::Curve::log, "Hz", true},
        {kLowGain, "lowGain", "Low Gain", -kMaxGainDb, kMaxGainDb, 0.0f, ParamInfo::Curve::linear, "dB", true},
        {kLowQ, "lowQ", "Low Q", kMinQ, kMaxQ, kButterworthQ, ParamInfo::Curve::log, "", true},
        {kPeak1On, "peak1On", "Peak 1 On", 0.0f, 1.0f, 1.0f, ParamInfo::Curve::linear, "", false},
        {kPeak1Freq, "peak1Freq", "Peak 1 Freq", kMinFreq, kMaxFreq, 400.0f, ParamInfo::Curve::log, "Hz", true},
        {kPeak1Gain, "peak1Gain", "Peak 1 Gain", -kMaxGainDb, kMaxGainDb, 0.0f, ParamInfo::Curve::linear, "dB", true},
        {kPeak1Q, "peak1Q", "Peak 1 Q", kMinQ, kMaxQ, 1.0f, ParamInfo::Curve::log, "", true},
        {kPeak2On, "peak2On", "Peak 2 On", 0.0f, 1.0f, 1.0f, ParamInfo::Curve::linear, "", false},
        {kPeak2Freq, "peak2Freq", "Peak 2 Freq", kMinFreq, kMaxFreq, 2500.0f, ParamInfo::Curve::log, "Hz", true},
        {kPeak2Gain, "peak2Gain", "Peak 2 Gain", -kMaxGainDb, kMaxGainDb, 0.0f, ParamInfo::Curve::linear, "dB", true},
        {kPeak2Q, "peak2Q", "Peak 2 Q", kMinQ, kMaxQ, 1.0f, ParamInfo::Curve::log, "", true},
        {kHighOn, "highOn", "High On", 0.0f, 1.0f, 1.0f, ParamInfo::Curve::linear, "", false},
        {kHighFreq, "highFreq", "High Freq", kMinFreq, kMaxFreq, 8000.0f, ParamInfo::Curve::log, "Hz", true},
        {kHighGain, "highGain", "High Gain", -kMaxGainDb, kMaxGainDb, 0.0f, ParamInfo::Curve::linear, "dB", true},
        {kHighQ, "highQ", "High Q", kMinQ, kMaxQ, kButterworthQ, ParamInfo::Curve::log, "", true},
        {kLpOn, "lpOn", "LP On", 0.0f, 1.0f, 0.0f, ParamInfo::Curve::linear, "", false},
        {kLpFreq, "lpFreq", "LP Freq", kMinFreq, kMaxFreq, 20000.0f, ParamInfo::Curve::log, "Hz", true},
        {kLpQ, "lpQ", "LP Q", kMinQ, kMaxQ, kButterworthQ, ParamInfo::Curve::log, "", true},
    }};
    static std::span<const ParamInfo> paramInfo() { return kParamInfo; }

    // Non-RT. The registry entry for NodeKind::eq (registerBuiltinNodes); NaN blocks count into
    // `telemetry` (DW-142), null means not at all.
    static NodeKindInfo kindInfo(Telemetry* telemetry = nullptr);

    // `firstParam` / `numParams` as in the NodeDesc.
    Eq(ParamID firstParam, uint32_t numParams, Telemetry* telemetry = nullptr)
        : firstParam_(firstParam), numParams_(numParams), telemetry_(telemetry) {}

    void prepare(const PrepareInfo& info) override;
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;

    // Blocks silenced by the NaN guard since construction. Any thread.
    uint64_t nanBlocks() const { return nanBlocks_.load(std::memory_order_relaxed); }

private:
    // One band's params as read this block; compared to the last block to skip the redesign.
    struct BandParams {
        bool on = false;
        float freq = 0.0f, gain = 0.0f, q = 0.0f;
        friend bool operator==(const BandParams&, const BandParams&) = default;
    };

    float param(const ProcessContext& ctx, uint32_t index) const DAW_RT;
    BandParams readBand(const ProcessContext& ctx, uint32_t band) const DAW_RT;
    BiquadCoeffs design(uint32_t band, const BandParams& params) const DAW_RT;
    void clearState() DAW_RT;
    void silence(const NodeIO& io, uint32_t n) DAW_RT;  // the NaN guard's output and bookkeeping

    ParamID firstParam_;
    uint32_t numParams_;
    Telemetry* telemetry_;
    double sampleRate_ = 48000.0;
    std::array<BandParams, kNumBands> params_{};   // as of the last block
    std::array<BiquadCoeffs, kNumBands> coeffs_{};  // where the last block ended
    std::array<std::array<BiquadState, kNumBands>, 2> state_{};
    bool primed_ = false;  // the first block jumps to the slot values
    std::atomic<uint64_t> nanBlocks_{0};
};

} // namespace daw
