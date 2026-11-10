#include "nodes/Metronome.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <numbers>

#include "core/ProcessContext.h"

namespace daw {

namespace {

// 03: a beat is one 1/den note.
inline Tick beatTicks(int32_t den) DAW_RT { return Tick{kPPQ} * 4 / den; }

// The signature in effect at `tick` (the last event at or before it; the first one before
// tick 0) and the tick of the next event after `tick` (INT64_MAX if none). Binary search, bounded
// by the event count.
struct SigAt {
    int32_t den;
    Tick nextEvent;
};
inline SigAt sigAt(const TempoMap& tempo, Tick tick) DAW_RT {
    const size_t count = tempo.timeSigEventCount();
    size_t lo = 0, hi = count;  // first event with tick > `tick`
    while (lo < hi) {
        const size_t mid = lo + (hi - lo) / 2;
        if (tempo.timeSigEvent(mid).tick > tick) hi = mid;
        else lo = mid + 1;
    }
    const size_t at = lo > 0 ? lo - 1 : 0;
    return {tempo.timeSigEvent(at).den,
            lo < count ? tempo.timeSigEvent(lo).tick : std::numeric_limits<Tick>::max()};
}

std::vector<float> makeShape(double sampleRate, double hz) {
    const auto n = static_cast<size_t>(std::llround(Metronome::kClickSeconds * sampleRate));
    std::vector<float> shape(n);
    for (size_t k = 0; k < n; ++k) {
        const double env = 1.0 - static_cast<double>(k) / static_cast<double>(n);
        shape[k] = static_cast<float>(env * env * env *
                                      std::cos(2.0 * std::numbers::pi * hz * static_cast<double>(k) / sampleRate));
    }
    return shape;
}

} // namespace

NodeKindInfo Metronome::kindInfo() {
    NodeKindInfo info{[](const NodeCreateInfo& create) -> Result<std::unique_ptr<Node>> {
        return std::unique_ptr<Node>(std::make_unique<Metronome>(create.desc.firstParam, create.desc.numParams));
    }};
    info.paramInfo = kParamInfo;  // DSP-041
    return info;
}

Tick Metronome::firstBeatAtOrAfter(const TempoMap& tempo, Tick tick) DAW_RT {
    const BBT bbt = tempo.tickToBBT(tick);
    if (bbt.tick == 0) return tick;
    const SigAt sig = sigAt(tempo, tick);
    // A signature event inside this beat starts a new bar there (03), before the beat ends.
    return std::min(tick - bbt.tick + beatTicks(sig.den), sig.nextEvent);
}

Tick Metronome::nextBeat(const TempoMap& tempo, Tick beat) DAW_RT {
    const SigAt sig = sigAt(tempo, beat);
    return std::min(beat + beatTicks(sig.den), sig.nextEvent);
}

bool Metronome::isDownbeat(const TempoMap& tempo, Tick beat) DAW_RT {
    const BBT bbt = tempo.tickToBBT(beat);
    return bbt.beat == 1 && bbt.tick == 0;
}

void Metronome::prepare(const PrepareInfo& info) {
    beat_ = makeShape(info.sampleRate, kBeatHz);
    accent_ = makeShape(info.sampleRate, kAccentHz);
    voices_ = {};
    continuity_.forget();
}

void Metronome::reset() DAW_RT {
    // TIME-008, DW-085: a locate cuts the clicks in progress cleanly; process() renders the fade.
    fadeAll();
    continuity_.forget();
}

float Metronome::param(const ProcessContext& ctx, uint32_t index) const DAW_RT {
    const ParamInfo& info = kParamInfo[index];
    if (index >= numParams_) return info.def;
    const float v = ctx.params.get(firstParam_ + index);
    // NaN fails both comparisons: off for the switch, silence for the levels.
    return v >= info.min ? (v <= info.max ? v : info.max) : info.min;
}

void Metronome::fadeAll() DAW_RT {
    for (Voice& v : voices_)
        if (v.shape != nullptr && v.fadeLeft == 0) v.fadeLeft = kFadeFrames;
}

void Metronome::trigger(bool downbeat) DAW_RT {
    const float amp = downbeat ? accentAmp_ : beatAmp_;
    const std::vector<float>& shape = downbeat ? accent_ : beat_;
    if (!on_ || amp == 0.0f || shape.empty()) return;
    // A free voice, else the oldest (furthest along); see kMaxVoices.
    Voice* slot = &voices_[0];
    for (Voice& v : voices_) {
        if (v.shape == nullptr) {
            slot = &v;
            break;
        }
        if (v.pos > slot->pos) slot = &v;
    }
    *slot = Voice{shape.data(), 0, amp, 0};
}

void Metronome::render(float* left, float* right, uint32_t from, uint32_t to) DAW_RT {
    if (to <= from) return;
    const auto length = static_cast<uint32_t>(beat_.size());  // both shapes have N samples
    constexpr float kRamp = 1.0f / static_cast<float>(kFadeFrames);
    for (Voice& v : voices_) {
        if (v.shape == nullptr) continue;
        uint32_t m = std::min(to - from, length - v.pos);
        if (v.fadeLeft > 0) m = std::min(m, v.fadeLeft);
        for (uint32_t i = 0; i < m; ++i) {
            float s = v.amp * v.shape[v.pos + i];
            // The fade's j-th sample plays at (kFadeFrames − 1 − j) / kFadeFrames, ending on 0.
            if (v.fadeLeft > 0) s *= static_cast<float>(v.fadeLeft - 1 - i) * kRamp;
            left[from + i] += s;
            if (right != nullptr) right[from + i] += s;
        }
        v.pos += m;
        bool done = v.pos >= length;
        if (v.fadeLeft > 0) {
            v.fadeLeft -= m;
            done = done || v.fadeLeft == 0;
        }
        if (done) v = Voice{};
    }
}

void Metronome::process(ProcessContext& ctx, NodeIO& io) DAW_RT {
    const AudioBufferView& out = io.audioOut;
    for (uint32_t c = 0; c < out.numChannels; ++c)
        std::memset(out.channels[c], 0, std::size_t{out.numFrames} * sizeof(float));
    const uint32_t n = std::min(ctx.numFrames, out.numFrames);
    if (out.numChannels == 0 || n == 0) return;  // ENG-004: a 0-frame block changes nothing
    float* left = out.channels[0];
    float* right = out.numChannels > 1 ? out.channels[1] : nullptr;

    // ENG-021: params once per block, latched into the clicks that start in it.
    on_ = param(ctx, kOn) >= 0.5f;
    const float level = param(ctx, kLevel);
    beatAmp_ = level;
    accentAmp_ = level * param(ctx, kAccent);

    const TransportBlock& block = ctx.transport;
    if (block.numSegments == 0 || block.tempo == nullptr) {
        // Stopped: no clicks; those in progress fade out (TIME-010, DW-085).
        fadeAll();
        render(left, right, 0, n);
        return;
    }
    const TempoMap& tempo = *block.tempo;

    uint32_t cursor = 0;
    forEachSegment(block, [&](const TransportSegment& seg) DAW_RT {
        render(left, right, cursor, seg.frameOffset);
        cursor = seg.frameOffset;
        // DW-085: a locate (or a tempo edit that moved the playhead's samples) cuts the clicks in
        // progress cleanly; a loop wrap lets them ring out (see Metronome.h).
        if (continuity_.jumped(seg) && !seg.afterWrap) fadeAll();

        // TIME-006/007: beats from the segment's own ticks, placed through the TempoMap. Beats
        // are at least one sample apart at any valid rate and tempo, so numFrames bounds them.
        Tick beat = firstBeatAtOrAfter(tempo, seg.startTick);
        for (uint32_t guard = 0; beat < seg.endTick && guard <= seg.numFrames; ++guard) {
            const uint32_t frame = frameOfTick(block, seg, beat);
            render(left, right, cursor, frame);
            cursor = frame;
            trigger(isDownbeat(tempo, beat));
            beat = nextBeat(tempo, beat);
        }
        render(left, right, cursor, seg.frameOffset + seg.numFrames);
        cursor = seg.frameOffset + seg.numFrames;
    });
    // Frames after the last segment (a loop shorter than the block) play no new clicks.
    render(left, right, cursor, n);
}

} // namespace daw
