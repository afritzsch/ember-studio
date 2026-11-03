#pragma once
// TIME-010 / DSP-011: NodeKind::metronome, a click on every beat of the tempo map with an
// accented downbeat. A source node: it ignores any audio input and writes the click to every
// output channel (the same signal on L and R).
//
// Params, relative to NodeDesc::firstParam, read once per block (ENG-021). Slots beyond
// numParams use their defaults, so a metronome with numParams 0 is simply on at default levels:
//   0 on      switch: clicks are triggered while ≥ 0.5, default 1, NaN off. "Enabled per
//             transport" (TIME-010): the model writes the project's metronome toggle here.
//   1 level   linear amplitude of a beat click, 0 … 3.98 (+12 dB), default 0.25 (−12 dBFS).
//             Out-of-range values are clamped; NaN is silence.
//   2 accent  linear gain of the downbeat click over `level`, 0 … 3.98, default 2 (+6 dB, so a
//             downbeat peaks at 0.5 by default). Clamped; NaN is silence.
// Switch and levels are latched when a click starts and hold for the whole click: turning the
// metronome off (or on, or changing a level) never cuts or reshapes a click in progress, so it
// needs no ramp (ENG-022) and makes no partial clicks or discontinuities.
//
// Sound (deterministic, IO-011): a click is kClickSeconds long; sample k of it is
//   amp · (1 − k/N)³ · cos(2π · f · k / sampleRate),   N = round(kClickSeconds · sampleRate)
// with f = kBeatHz on beats and kAccentHz on downbeats, amp = level (· accent on downbeats).
// Its first sample is exactly `amp` (the transient), its envelope reaches 0 at N. Both shapes
// are tabulated in prepare() (non-RT); process() only copies and scales them.
//
// Timing (TIME-010, TIME-006/007): a beat is one 1/den note (03: 6/8 has six 480-tick beats) and
// a bar's first beat is the downbeat. A time-signature event starts a new bar on its tick, so a
// bar it cuts short ends early and the event's tick is a downbeat. A beat at tick t clicks at
// sample tempo->tickToSample(t), placed per TransportSegment through the block's TempoMap, so it
// is sample-exact across tempo and signature changes inside a block. Clicks overlap freely
// (kMaxVoices sum); a new click never cuts an older one.
//
// Transport (03 "Transport semantics", DW-085):
//   - It is a timeline node: GraphBuilder flags NodeKind::metronome `timeline`, so the Engine
//     runs it graph-latency samples ahead like the clip players (MIX-023) and it stays on the
//     beat behind latent plugins.
//   - Loop wraps (TIME-005/006): the new pass clicks from the segment's own ticks (the loop
//     start's beat sounds if the loop starts on one); clicks from the old pass ring out, since
//     each is a complete, self-ending sound.
//   - Locate (TIME-008), or any other segment that doesn't continue the previous one (a tempo
//     edit that moved the samples under the playhead): clicks in progress are cut cleanly, with
//     a linear fade over kFadeFrames, and the new position clicks as usual. reset() does the
//     same, and the node also detects the jump itself (SegmentContinuity), so it behaves the
//     same whether or not the builder marks it reset-on-locate.
//   - Stopped (numSegments == 0): no clicks; clicks in progress fade out over kFadeFrames, then
//     the output is silent.

#include <array>
#include <cstdint>
#include <span>
#include <vector>

#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/Realtime.h"
#include "dsp/ParamInfo.h"
#include "graph/NodeRegistry.h"
#include "time/TempoMap.h"
#include "time/TransportSegments.h"

namespace daw {

class Metronome final : public Node {
public:
    static constexpr uint32_t kOn = 0;
    static constexpr uint32_t kLevel = 1;
    static constexpr uint32_t kAccent = 2;
    static constexpr uint32_t kNumParams = 3;
    static constexpr float kMaxLevel = 3.98107171f;  // +12 dB, as GainNode::kMaxLevel

    static constexpr double kClickSeconds = 0.02;
    static constexpr double kBeatHz = 1000.0;
    static constexpr double kAccentHz = 1500.0;
    static constexpr uint32_t kFadeFrames = 64;  // like the clip players' declick (DSP-001)
    // Concurrent clicks. The densest valid map (1000 bpm, 1/64 beats) has a beat every 3.75 ms,
    // so at most 6 clicks of 20 ms overlap; the rest is room for clicks fading after a jump.
    // When all are busy, the oldest is replaced.
    static constexpr uint32_t kMaxVoices = 16;

    static constexpr std::array<ParamInfo, kNumParams> kParamInfo{{
        {kOn, "on", "On", 0.0f, 1.0f, 1.0f, ParamInfo::Curve::linear, "", true},
        {kLevel, "level", "Level", 0.0f, kMaxLevel, 0.25f, ParamInfo::Curve::db, "dB", true},
        {kAccent, "accent", "Accent", 0.0f, kMaxLevel, 2.0f, ParamInfo::Curve::db, "dB", true},
    }};
    static std::span<const ParamInfo> paramInfo() { return kParamInfo; }

    // Non-RT. The registry entry for NodeKind::metronome (registerBuiltinNodes).
    static NodeKindInfo kindInfo();

    // `firstParam` / `numParams` as in the NodeDesc.
    Metronome(ParamID firstParam, uint32_t numParams) : firstParam_(firstParam), numParams_(numParams) {}

    void prepare(const PrepareInfo& info) override;
    void reset() DAW_RT override;
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;

    // Non-RT, for tests: the unit click shapes (amp 1) at the prepared rate.
    std::span<const float> beatClick() const { return beat_; }
    std::span<const float> accentClick() const { return accent_; }

    // The first beat at or after `tick`, whether it is a downbeat, and the beat after a beat.
    // RT-safe; shared with tests as the oracle's beat grid.
    static Tick firstBeatAtOrAfter(const TempoMap& tempo, Tick tick) DAW_RT;
    static Tick nextBeat(const TempoMap& tempo, Tick beat) DAW_RT;
    static bool isDownbeat(const TempoMap& tempo, Tick beat) DAW_RT;

private:
    struct Voice {
        const float* shape = nullptr;  // null: free
        uint32_t pos = 0;              // next sample of the shape
        float amp = 0.0f;
        uint32_t fadeLeft = 0;         // > 0: fading out, this many samples to go
    };

    float param(const ProcessContext& ctx, uint32_t index) const DAW_RT;
    void trigger(bool downbeat) DAW_RT;
    void fadeAll() DAW_RT;
    // Adds every sounding click to frames [from, to) and advances them.
    void render(float* left, float* right, uint32_t from, uint32_t to) DAW_RT;

    ParamID firstParam_;
    uint32_t numParams_;
    std::vector<float> beat_, accent_;
    std::array<Voice, kMaxVoices> voices_{};
    SegmentContinuity continuity_;
    // Latched per block (ENG-021) and applied to clicks starting in it.
    bool on_ = false;
    float beatAmp_ = 0.0f, accentAmp_ = 0.0f;
};

} // namespace daw
