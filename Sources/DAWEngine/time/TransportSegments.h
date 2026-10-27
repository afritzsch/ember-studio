#pragma once
// TIME-005/006: reading a TransportBlock. For timeline nodes (clip players T-013, MIDI players
// T-040, metronome T-024, automation 11) and for the Transport, which builds segments with the
// same tick rule.
//
// A segment is a run of frames that plays the timeline contiguously:
//   - block frames [frameOffset, frameOffset + numFrames) play samples
//     [startSample, startSample + numFrames);
//   - [startTick, endTick) are exactly the ticks whose events sound in it, i.e. those with
//     startSample <= tickToSample(t) < startSample + numFrames. Consecutive segments tile ticks
//     without gaps or repeats, so an event plays exactly once per pass;
//   - afterWrap: it starts at the loop start, right after a wrap (in this block or at the end of
//     the previous one).
// Segments are never empty. They may not cover the whole block: there are none while stopped or
// for a 0-frame block, and a loop shorter than the block leaves a gap after the second one.
//
// TIME-006, the contract for timeline nodes. In process():
//   1. Clear the output first; frames outside every segment stay silent.
//   2. forEachSegment: render each one into its own frame range, deriving the source position
//      from the segment (startSample / startTick), not from where the last block ended.
//   3. A node that does keep a cursor across blocks (an index into sorted events, a read
//      position in a clip) re-seeks it when SegmentContinuity::jumped() says so: after a wrap,
//      a locate, or a tempo edit that moved the samples under the playhead.
//   4. On a wrap, end the previous pass's voices without a click (TIME-005).
//   5. reset() (TIME-008, on a locate while playing) drops voices and tails and forgets cursors.
// Tempo: the whole block runs at tempoAtStart() (TIME-007), but event positions come from the
// TempoMap, so they stay exact across a tempo change inside the block.

#include <cstdint>
#include <limits>

#include "core/Realtime.h"
#include "time/TempoMap.h"
#include "time/TransportBlock.h"

namespace daw {

// The first tick whose events sound at or after `sample` (tickToSample(t) >= sample). TempoMap
// gives the last tick at or before a sample, so step one back and take the next tick.
inline Tick firstTickAtOrAfter(const TempoMap& tempo, SamplePos sample) DAW_RT {
    return tempo.sampleToTick(sample - 1) + 1;
}

// Calls fn(const TransportSegment&) for each segment, in timeline order.
template <class Fn>
void forEachSegment(const TransportBlock& block, Fn&& fn) DAW_RT {
    for (uint8_t i = 0; i < block.numSegments && i < 2; ++i) fn(block.seg[i]);
}

inline bool segmentContains(const TransportSegment& seg, Tick tick) DAW_RT {
    return tick >= seg.startTick && tick < seg.endTick;
}

// The block frame at which an event at `tick` sounds. Requires segmentContains(seg, tick).
inline uint32_t frameOfTick(const TransportBlock& block, const TransportSegment& seg,
                            Tick tick) DAW_RT {
    return seg.frameOffset + static_cast<uint32_t>(block.tempo->tickToSample(tick) - seg.startSample);
}

// TIME-005's block-level values, which the contract struct leaves implicit. Valid for every
// block Transport::advance() produced (seg[0] holds the position even when it isn't a segment).
inline SamplePos blockStartSample(const TransportBlock& block) DAW_RT {
    return block.seg[0].startSample;
}
// The tick sounding at the block's first frame (TempoMap::sampleToTick), the musical position.
// Not seg[0].startTick, which is the first tick at or after it.
inline Tick blockStartTick(const TransportBlock& block) DAW_RT {
    return block.tempo->sampleToTick(block.seg[0].startSample);
}
// TIME-007: the tempo the whole block is processed at.
inline double tempoAtStart(const TransportBlock& block) DAW_RT {
    return block.tempo->bpmAt(blockStartTick(block));
}
inline uint32_t segmentFrames(const TransportBlock& block) DAW_RT {
    uint32_t frames = 0;
    forEachSegment(block, [&](const TransportSegment& seg) DAW_RT { frames += seg.numFrames; });
    return frames;
}

// TIME-006 step 3: tells a node when a segment doesn't continue where its previous one ended.
// The first segment a node sees, and the first after forget(), counts as a jump.
class SegmentContinuity {
public:
    bool jumped(const TransportSegment& seg) DAW_RT {
        const bool jump = seg.afterWrap || seg.startSample != next_;
        next_ = seg.startSample + seg.numFrames;
        return jump;
    }
    void forget() DAW_RT { next_ = kNone; }  // from reset()

private:
    static constexpr SamplePos kNone = std::numeric_limits<SamplePos>::min();
    SamplePos next_ = kNone;
};

} // namespace daw
