#pragma once
// 03-time-transport: the tempo map converts between ticks (960 PPQ), sample positions and
// bars/beats. It is immutable once built (TIME-003); a tempo edit builds a new map.
//
// The Swift mirror is DAWModel.TempoMap (Sources/DAWModel/Time/TempoMap.swift). Both must give
// bit-identical results (TIME-011): keep the arithmetic in the same order in both files.

#include <cstdint>
#include <vector>

#include "../core/Realtime.h"
#include "../core/Result.h"

namespace daw {

using Tick = int64_t;
using SamplePos = int64_t;
constexpr int kPPQ = 960;

// Validation limits. Outside them the map is rejected rather than clamped.
constexpr double kMinBPM = 1.0;
constexpr double kMaxBPM = 1000.0;
constexpr double kMinSampleRate = 1000.0;
constexpr double kMaxSampleRate = 768000.0;
constexpr int32_t kMaxTimeSigNumerator = 64;
constexpr int32_t kMaxTimeSigDenominator = 64;

// A step change to `bpm` at `tick` (no ramps in v1).
struct TempoEvent {
    Tick tick;
    double bpm;
};

// `num`/`den` from `tick` onward. The beat is one 1/den note. A signature event always starts a
// new bar, so an event that isn't on a bar line of the previous signature cuts that bar short.
struct TimeSigEvent {
    Tick tick;
    int32_t num;
    int32_t den;
};

// Bars and beats are 1-based, `tick` is the offset inside the beat (0 ..< beat length). Ticks
// before 0 extrapolate the first signature backwards, so they land in bar 0, -1, …
struct BBT {
    int64_t bar;
    int32_t beat;
    int32_t tick;
};

using TempoEventList = std::vector<TempoEvent>;
using TimeSigEventList = std::vector<TimeSigEvent>;

enum class TempoMapError : uint8_t {
    ok,
    noTempoEvents,
    noTimeSignatures,
    firstEventNotAtTickZero,  // TIME model: event 0 is always at tick 0
    eventsNotAscending,       // ticks must be strictly increasing within each list
    tempoOutOfRange,
    invalidTimeSignature,
    sampleRateOutOfRange,
};

class TempoMap {
public:
    // 120 bpm, 4/4, 48 kHz.
    TempoMap();

    static TempoMapError validate(const TempoEventList& tempos, const TimeSigEventList& sigs,
                                  double sampleRate);
    // Non-RT. Fails with ErrorCode::invalidArgument when validate() does; the message names
    // the TempoMapError.
    static Result<TempoMap> make(const TempoEventList& tempos, const TimeSigEventList& sigs,
                                 double sampleRate);

    // TIME-001: the nearest sample to the exact position of `tick`. O(log n) in tempo events.
    SamplePos tickToSample(Tick tick) const DAW_RT;
    // TIME-001: the last tick whose tickToSample() is <= `sample`, i.e. the tick that is sounding
    // at that sample. tickToSample(sampleToTick(s)) <= s < tickToSample(sampleToTick(s) + 1).
    Tick sampleToTick(SamplePos sample) const DAW_RT;
    double bpmAt(Tick tick) const DAW_RT;
    // TIME-002
    BBT tickToBBT(Tick tick) const DAW_RT;
    // TIME-002: inverse of tickToBBT for every BBT it returns. Other inputs (beat > numerator,
    // tick >= beat length) extrapolate linearly within the bar's signature.
    Tick bbtToTick(BBT bbt) const DAW_RT;

    double sampleRate() const DAW_RT { return sampleRate_; }
    size_t tempoEventCount() const DAW_RT { return tempo_.size(); }
    TempoEvent tempoEvent(size_t i) const DAW_RT { return {tempo_[i].tick, tempo_[i].bpm}; }
    size_t timeSigEventCount() const DAW_RT { return sig_.size(); }
    TimeSigEvent timeSigEvent(size_t i) const DAW_RT {
        return {sig_[i].tick, sig_[i].num, sig_[i].den};
    }

private:
    // Precomputed per tempo event (TIME-001): the cumulative sample offset stays a double and is
    // rounded only on output, so long maps don't drift.
    struct TempoSegment {
        Tick tick;
        double bpm;
        double startSample;
        double samplesPerTick;
    };
    struct SigSegment {
        Tick tick;
        int32_t num;
        int32_t den;
        int64_t firstBar;
        int64_t beatTicks;
        int64_t barTicks;
    };

    TempoMap(const TempoEventList& tempos, const TimeSigEventList& sigs, double sampleRate);

    size_t tempoSegmentAt(Tick tick) const DAW_RT;
    size_t sigSegmentAt(Tick tick) const DAW_RT;

    std::vector<TempoSegment> tempo_;
    std::vector<SigSegment> sig_;
    double sampleRate_;
};

}  // namespace daw
