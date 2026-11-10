#pragma once
// DSP-032: NodeKind::delay, a stereo / ping-pong echo with the time in milliseconds or as a
// tempo-synced note value (read from the TransportBlock's tempo map), feedback through a lowpass
// in the loop, and a dry/wet mix.
//
// Params, relative to NodeDesc::firstParam, read once per block (ENG-021). Slots beyond
// numParams use their defaults, so a delay with numParams 0 runs at the defaults. A NaN slot
// reads as the default; other out-of-range values are clamped.
//   0 time      ms, 1 … 4000, default 375      the delay time while sync is off
//   1 sync      switch, default 1              ≥ 0.5: the time is the note value at the tempo
//   2 note      0 … 13, default 5 (1/8)        index into kNotes (rounded to the nearest index)
//   3 feedback  0 … 0.95, default 0.35         gain of each repeat (through the lowpass)
//   4 lowpass   Hz, 200 … 20000, log, def 8000 one-pole lowpass in the feedback loop; 20000 is
//                                              off (the loop is flat)
//   5 pingpong  switch, default 0              ≥ 0.5: echoes alternate left and right
//   6 mix       0 … 1, default 0.3             0 dry only, 1 wet only (linear crossfade)
// feedback and mix ramp linearly across the block (ENG-022). lowpass and pingpong are latched per
// block. time, sync and note set the target delay T (whole frames, see below). A change of T
// doesn't move the read tap (a step would click, a glide would bend the pitch): the output
// crossfades linearly from the tap at the old time to the tap at the new one over kCrossfadeMs.
// A T that changes again during a crossfade is taken up when it ends. Tempo changes act the same
// way: the synced T is recomputed every block from the tempo at the block's start (TIME-007), so
// a tempo change while playing crossfades to the new time, as does a locate to another tempo.
//
// Delay time in frames: T = round(time · rate / 1000) (sync off) or
// T = round(beats · 60 · rate / bpm) (sync on; `beats` in quarter notes from kNotes, `bpm` the
// tempo at the block's start: tempoAtStart(), also while stopped; 120 without a tempo map), then
// clamped to 1 … round(kMaxSeconds · rate). At 120 bpm and 48 kHz a 1/8 note is 12000 frames.
//
// Signal path, per sample (float; channel 0 = L, 1 = R):
//   input     inL = input channel 0, inR = channel 1 (a mono input feeds both). Without an input
//             (no channels) the input is silence and the echoes ring on.
//   taps      x_c = line c read D frames back (D ≥ 1, so before this frame's write); during a
//             crossfade from D to D' over N = round(kCrossfadeMs · rate / 1000) frames, its k-th
//             frame (k = 1 … N) reads x_c = (1 − k/N) · line_c[D] + (k/N) · line_c[D'], and D
//             becomes D' after the N-th.
//   loop LP   z_c = (1 − a) · x_c + a · z_c, a = exp(−2π · f / rate), f = min(lowpass, 0.45 · rate);
//             at lowpass ≥ kLowpassOff, z_c = x_c.
//   write     stereo:    line_L ← inL + fb · z_L,              line_R ← inR + fb · z_R
//             ping-pong: line_L ← ½(inL + inR) + fb · z_R,     line_R ← fb · z_L
//             (ping-pong: the input enters on the left, the first echo is left at D, the next
//             right at 2D, then left …)
//   output    out_c = (1 − mix) · in_c + mix · x_c. The first echo is the input unfiltered; each
//             further repeat has passed the lowpass once more and is fb times quieter.
// Channels beyond stereo are silent.
//
// Silence (DSP-040): a value written to a line or held in a lowpass whose magnitude is below
// kSnap (−180 dBFS) is stored as exactly 0. feedback < 1, so after the input stops every write
// becomes exactly 0 in finite time, the output then is exactly 0, and nothing decays into
// denormals. The Node API has no tail length (02); an export's tail (IO-012) ends on quiet
// output.
//
// NaN guard (DSP-040): a block whose input holds a NaN or ±Inf outputs silence and clears the
// lines and filters, so one bad block can't poison the echoes. It is counted in nanBlocks() and
// in Telemetry when the factory was given one (DW-142).
//
// Delay memory (kMaxSeconds per channel) is allocated in prepare() at the session rate; process()
// never allocates. Latency 0. reset() keeps the echoes: an effect keeps running across a locate
// (TIME-008), like the compressor and the reverb.

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

class Delay final : public Node {
public:
    static constexpr uint32_t kTime = 0;
    static constexpr uint32_t kSync = 1;
    static constexpr uint32_t kNote = 2;
    static constexpr uint32_t kFeedback = 3;
    static constexpr uint32_t kLowpass = 4;
    static constexpr uint32_t kPingPong = 5;
    static constexpr uint32_t kMix = 6;
    static constexpr uint32_t kNumParams = 7;

    // Tempo-synced note values, shortest first, in quarter notes (T = triplet, D = dotted).
    struct NoteValue {
        const char* name;
        double beats;
    };
    static constexpr uint32_t kNumNotes = 14;
    static constexpr std::array<NoteValue, kNumNotes> kNotes{{
        {"1/32", 0.125},
        {"1/16T", 1.0 / 6.0},
        {"1/16", 0.25},
        {"1/8T", 1.0 / 3.0},
        {"1/16D", 0.375},
        {"1/8", 0.5},
        {"1/4T", 2.0 / 3.0},
        {"1/8D", 0.75},
        {"1/4", 1.0},
        {"1/2T", 4.0 / 3.0},
        {"1/4D", 1.5},
        {"1/2", 2.0},
        {"1/2D", 3.0},
        {"1/1", 4.0},
    }};

    static constexpr double kMaxSeconds = 4.0;    // longest delay (memory per channel)
    static constexpr double kCrossfadeMs = 20.0;  // time-change crossfade
    static constexpr double kLowpassOff = 20000.0;
    static constexpr double kFallbackBpm = 120.0;  // no tempo map in the TransportBlock
    static constexpr float kSnap = 1e-9f;          // −180 dBFS

    static constexpr std::array<ParamInfo, kNumParams> kParamInfo{{
        {kTime, "time", "Time", 1.0f, 4000.0f, 375.0f, ParamInfo::Curve::log, "ms", true},
        {kSync, "sync", "Tempo Sync", 0.0f, 1.0f, 1.0f, ParamInfo::Curve::linear, "", true},
        {kNote, "note", "Note Value", 0.0f, 13.0f, 5.0f, ParamInfo::Curve::linear, "", true},
        {kFeedback, "feedback", "Feedback", 0.0f, 0.95f, 0.35f, ParamInfo::Curve::linear, "", true},
        {kLowpass, "lowpass", "Lowpass", 200.0f, 20000.0f, 8000.0f, ParamInfo::Curve::log, "Hz", true},
        {kPingPong, "pingpong", "Ping-Pong", 0.0f, 1.0f, 0.0f, ParamInfo::Curve::linear, "", true},
        {kMix, "mix", "Mix", 0.0f, 1.0f, 0.3f, ParamInfo::Curve::linear, "", true},
    }};
    static std::span<const ParamInfo> paramInfo() { return kParamInfo; }

    // Non-RT. The registry entry for NodeKind::delay (registerBuiltinNodes).
    static NodeKindInfo kindInfo(Telemetry* telemetry = nullptr);

    // T in frames for the given (clamped) param values at `bpm` and `rate`: the rule above.
    static uint32_t delayFrames(float timeMs, bool sync, float note, double bpm, double rate) DAW_RT;
    // The crossfade length N in frames at `rate`.
    static uint32_t crossfadeFrames(double rate) DAW_RT;

    // `firstParam` / `numParams` as in the NodeDesc.
    Delay(ParamID firstParam, uint32_t numParams, Telemetry* telemetry = nullptr)
        : firstParam_(firstParam), numParams_(numParams), telemetry_(telemetry) {}

    void prepare(const PrepareInfo& info) override;
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;

    // Blocks silenced by the NaN guard since construction. Any thread.
    uint64_t nanBlocks() const { return nanBlocks_.load(std::memory_order_relaxed); }
    // Whether both lines and filters are exactly 0 (the echoes have ended). Not RT; for tests.
    bool isSilent() const;
    // The read tap D in frames (the crossfade's target once one ends). Not RT; for tests.
    uint32_t currentDelayFrames() const { return xfadeTo_; }

private:
    float param(const ProcessContext& ctx, uint32_t index) const DAW_RT;
    void clear() DAW_RT;

    ParamID firstParam_;
    uint32_t numParams_;
    Telemetry* telemetry_;  // DW-142: NaN blocks count here; null when not wired
    double sampleRate_ = 48000.0;

    // Two ring buffers, power-of-two sized: L is line_[0 … cap_), R is line_[cap_ … 2·cap_).
    std::vector<float> line_;
    uint32_t cap_ = 0, mask_ = 0, write_ = 0;
    uint32_t maxDelay_ = 1, xfadeLen_ = 1;

    uint32_t delay_ = 1;     // D
    uint32_t target_ = 1;    // T for this block
    uint32_t xfadeTo_ = 1;   // D' while a crossfade runs (xfadeTo_ != delay_), else D
    uint32_t xfadePos_ = 0;  // frames of the running crossfade done
    std::array<float, 2> lp_{};  // z_L, z_R

    ParamSmoother feedback_, mix_;
    bool primed_ = false;  // the first block jumps to the slot values (see ChannelStrip)
    std::atomic<uint64_t> nanBlocks_{0};
};

} // namespace daw
