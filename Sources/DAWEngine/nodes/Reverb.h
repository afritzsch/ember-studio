#pragma once
// DSP-033: NodeKind::reverb, an algorithmic stereo reverb: a feedback delay network (FDN) of 8
// delay lines mixed by an orthogonal 8×8 Hadamard matrix (Jot & Chaigne 1991; Smith, "Physical
// Audio Signal Processing", "Feedback Delay Networks"). Deterministic (IO-011): no modulation, no
// noise, no random state; the same input and params give the same output bits whatever the block
// sizes (ENG-004).
//
// Params, relative to NodeDesc::firstParam, read once per block (ENG-021). Slots beyond
// numParams use their defaults, so a reverb with numParams 0 runs at the defaults. A NaN slot
// reads as the default; other out-of-range values are clamped.
//   0 size      0 … 1, default 0.5        scales the delay lines (room size)
//   1 decay     s, 0.1 … 20, default 2    RT60: time for the tail to fall by 60 dB at low
//                                         frequencies (damping shortens it above its cutoff)
//   2 damping   0 … 1, default 0.5        high-frequency absorption in the loop
//   3 predelay  ms, 0 … 200, default 10   delay before the input enters the network
//   4 mix       0 … 1, default 0.3        0 dry only, 1 wet only (linear crossfade)
// decay and mix ramp linearly across the block (ENG-022). size and predelay move delay times, so
// a step would click: the delay times glide towards their new values at kGlide samples per
// sample instead (a short, bounded pitch bend, like a tape delay's time knob). damping is latched
// per block: it changes a one-pole coefficient, which moves no sample by a step.
//
// Signal path, per sample n (float; channel 0 = L, 1 = R):
//   input     inL = input channel 0, inR = channel 1 (a mono input feeds both). Without an input
//             (no channels) the input is silence and the tail rings on.
//   pre-delay pL, pR = inL, inR delayed by P samples, P gliding to round(predelay · rate / 1000)
//             (P = 0 passes the current sample).
//   lines     x_i = line i read D_i samples back (linear interpolation; D_i is a multiple of
//             kGlide, so it reads whole samples except while gliding), i = 0 … 7.
//             D_i glides to L_i = max(1, round(kBaseFrames[i] · s · rate / 48000)),
//             s = kMinScale + (1 − kMinScale) · size.
//   damping   z_i = (1 − a) · x_i + a · z_i,  a = exp(−2π · f / rate),
//             f = min(kDampMaxHz · (kDampMinHz / kDampMaxHz)^damping, 0.45 · rate)
//   decay     y_i = g_i · z_i,  g_i = 10^(−3 · L_i / (decay · rate)): each pass through line i
//             loses 60 dB per `decay` seconds (from the target lengths L_i, so a glide doesn't
//             detune the decay).
//   feedback  m = H8 · y / √8 (dsp/Hadamard.h; orthogonal, lossless)
//   write     line i ← m_i + pL (even i) or m_i + pR (odd i)
//   wet       wL = kOutGain · Σ_i cL_i · x_i,  wR = kOutGain · Σ_i cR_i · x_i, with the
//             orthogonal taps cL = H8 row 1 (+ − + − + − + −) and cR = H8 row 2 (+ + − − + + − −),
//             so the two outputs are decorrelated.
//   output    out_c = (1 − mix) · in_c + mix · w_c
// The first wet sample of an impulse at frame 0 arrives at frame P + min_i L_i.
//
// Silence (DSP-040): a value written to a line or held in a damping filter whose magnitude is
// below kSnap (−180 dBFS) is stored as exactly 0. The loop gain is < 1 everywhere, so after the
// input stops the whole network reaches exact 0 in finite time (roughly decay · 180/60 seconds
// after the tail starts from 0 dBFS), the output is then exactly 0, and nothing decays into
// denormals.
//
// Tail: the Node API has no tail length (02). The offline export's tail (IO-012) ends on quiet
// output, and the tail falls by 60 dB every `decay` seconds; tailSeconds() states it for callers.
//
// NaN guard (DSP-040): a block whose input holds a NaN or ±Inf outputs silence and clears the
// network (lines, pre-delay, filters), so one bad block can't poison the tail. It is counted in
// nanBlocks() and in Telemetry when the factory was given one (DW-142).
//
// Delay memory is allocated in prepare() for the longest lines (size 1) and pre-delay (200 ms) at
// the session rate; process() never allocates. Latency 0: the pre-delay is part of the effect.
//
// The engine never resets an effect on a locate, so the tail keeps running across one (TIME-008).
// reset() clears it; only offline renders call it, before their first block (DW-063).

#include <array>
#include <atomic>
#include <cstdint>
#include <span>
#include <vector>

#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/ParamSmoother.h"
#include "core/Realtime.h"
#include "core/Telemetry.h"
#include "dsp/ParamInfo.h"
#include "graph/NodeRegistry.h"

namespace daw {

class Reverb final : public Node {
public:
    static constexpr uint32_t kSize = 0;
    static constexpr uint32_t kDecay = 1;
    static constexpr uint32_t kDamping = 2;
    static constexpr uint32_t kPredelay = 3;
    static constexpr uint32_t kMix = 4;
    static constexpr uint32_t kNumParams = 5;

    static constexpr uint32_t kLines = 8;
    // Line lengths in frames at 48 kHz and size 1 (≈ 50 … 100 ms; primes, so the lines' echoes
    // don't pile up on common multiples).
    static constexpr std::array<uint32_t, kLines> kBaseFrames{2411, 2647, 2953, 3203, 3541, 3833, 4241, 4799};
    static constexpr double kBaseRate = 48000.0;
    static constexpr double kMinScale = 0.15;     // line scale at size 0 (≈ 7.5 … 15 ms)
    static constexpr double kMaxPredelayMs = 200.0;
    static constexpr double kDampMaxHz = 18000.0;  // damping 0
    static constexpr double kDampMinHz = 500.0;    // damping 1
    static constexpr float kGlide = 0.125f;        // samples per sample a delay time moves
    static constexpr float kOutGain = 0.25f;
    static constexpr float kSnap = 1e-9f;          // −180 dBFS

    static constexpr std::array<ParamInfo, kNumParams> kParamInfo{{
        {kSize, "size", "Size", 0.0f, 1.0f, 0.5f, ParamInfo::Curve::linear, "", true},
        {kDecay, "decay", "Decay", 0.1f, 20.0f, 2.0f, ParamInfo::Curve::log, "s", true},
        {kDamping, "damping", "Damping", 0.0f, 1.0f, 0.5f, ParamInfo::Curve::linear, "", true},
        {kPredelay, "predelay", "Pre-delay", 0.0f, 200.0f, 10.0f, ParamInfo::Curve::linear, "ms", true},
        {kMix, "mix", "Mix", 0.0f, 1.0f, 0.3f, ParamInfo::Curve::linear, "", true},
    }};
    static std::span<const ParamInfo> paramInfo() { return kParamInfo; }

    // Non-RT. The registry entry for NodeKind::reverb (registerBuiltinNodes).
    static NodeKindInfo kindInfo(Telemetry* telemetry = nullptr);

    // The delay line lengths L_i in frames for `size` (clamped to 0 … 1) at `rate`.
    static std::array<uint32_t, kLines> lineLengths(double size, double rate);
    // Seconds for the tail to fall by `db` dB (> 0) at decay `decaySeconds` (RT60).
    static double tailSeconds(double decaySeconds, double db = 60.0) { return decaySeconds * db / 60.0; }

    // `firstParam` / `numParams` as in the NodeDesc.
    Reverb(ParamID firstParam, uint32_t numParams, Telemetry* telemetry = nullptr)
        : firstParam_(firstParam), numParams_(numParams), telemetry_(telemetry) {}

    void prepare(const PrepareInfo& info) override;
    // DW-063 (T-089): back to the state prepare() leaves (no tail, first block jumps to the
    // slot values). Only offline renders reset every node; a live locate never resets an effect
    // (TIME-008), so tails survive it.
    void reset() DAW_RT override;
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;

    // Blocks silenced by the NaN guard since construction. Any thread.
    uint64_t nanBlocks() const { return nanBlocks_.load(std::memory_order_relaxed); }
    // Whether every line, filter and pre-delay sample is exactly 0 (the tail has ended). Not RT;
    // for tests.
    bool isSilent() const;

private:
    float param(const ProcessContext& ctx, uint32_t index) const DAW_RT;
    void clear() DAW_RT;

    ParamID firstParam_;
    uint32_t numParams_;
    Telemetry* telemetry_;  // DW-142: NaN blocks count here; null when not wired
    double sampleRate_ = 48000.0;

    // Ring buffers, power-of-two sized: line i is lines_[i·lineCap_ … (i+1)·lineCap_), the
    // pre-delay pre_[0 … preCap_) (L) and pre_[preCap_ … 2·preCap_) (R).
    std::vector<float> lines_, pre_;
    uint32_t lineCap_ = 0, lineMask_ = 0, preCap_ = 0, preMask_ = 0;
    uint32_t lineWrite_ = 0, preWrite_ = 0;

    std::array<float, kLines> delay_{};   // D_i, current (gliding)
    std::array<float, kLines> target_{};  // L_i
    std::array<float, kLines> damp_{};    // z_i
    float predelay_ = 0.0f, predelayTarget_ = 0.0f;
    float size_ = -1.0f;  // the size L_i were computed for (−1: none yet)

    std::array<float, kLines> gains_{};  // g_i at the previous block's end (ENG-022 ramp start)
    ParamSmoother mix_;
    bool primed_ = false;  // the first block jumps to the slot values (see ChannelStrip)
    std::atomic<uint64_t> nanBlocks_{0};
};

} // namespace daw
