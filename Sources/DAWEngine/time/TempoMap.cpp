#include "time/TempoMap.h"

#include <algorithm>
#include <cmath>

// TIME-011: the Swift mirror must produce the same doubles. Swift never fuses a*b+c into an FMA,
// and Clang does by default, which changes the last bit and occasionally the rounded sample.
#pragma clang fp contract(off)

namespace daw {

namespace {

// Positions are clamped here before converting to an integer so out-of-range input can't hit
// undefined behaviour (and Swift's mirror can't trap).
constexpr double kMaxPosition = 4611686018427387904.0;  // 2^62

int64_t clampToInt64(double x) DAW_RT {
    return static_cast<int64_t>(std::clamp(x, -kMaxPosition, kMaxPosition));
}

// Round half away from zero: std::llround, and Swift's default rounded().
int64_t roundToInt64(double x) DAW_RT {
    return std::llround(std::clamp(x, -kMaxPosition, kMaxPosition));
}

int64_t floorDiv(int64_t a, int64_t b) DAW_RT {
    return a >= 0 ? a / b : -((-a - 1) / b) - 1;
}

int64_t ceilDiv(int64_t a, int64_t b) DAW_RT {
    return (a + b - 1) / b;  // a >= 0 only
}

double samplesPerTick(double sampleRate, double bpm) DAW_RT {
    return (sampleRate * 60.0) / (bpm * static_cast<double>(kPPQ));
}

bool isValidDenominator(int32_t den) DAW_RT {
    return den >= 1 && den <= kMaxTimeSigDenominator && (den & (den - 1)) == 0;
}

}  // namespace

TempoMap::TempoMap() : TempoMap({{0, 120.0}}, {{0, 4, 4}}, 48000.0) {}

TempoMapError TempoMap::validate(const TempoEventList& tempos, const TimeSigEventList& sigs,
                                 double sampleRate) {
    // The order of checks is part of the contract: tempo_vectors.json pins the reported error.
    if (!(sampleRate >= kMinSampleRate && sampleRate <= kMaxSampleRate)) {
        return TempoMapError::sampleRateOutOfRange;
    }
    if (tempos.empty()) return TempoMapError::noTempoEvents;
    for (size_t i = 0; i < tempos.size(); ++i) {
        if (i == 0 && tempos[i].tick != 0) return TempoMapError::firstEventNotAtTickZero;
        if (i > 0 && tempos[i].tick <= tempos[i - 1].tick) return TempoMapError::eventsNotAscending;
        if (!(tempos[i].bpm >= kMinBPM && tempos[i].bpm <= kMaxBPM)) {
            return TempoMapError::tempoOutOfRange;
        }
    }
    if (sigs.empty()) return TempoMapError::noTimeSignatures;
    for (size_t i = 0; i < sigs.size(); ++i) {
        if (i == 0 && sigs[i].tick != 0) return TempoMapError::firstEventNotAtTickZero;
        if (i > 0 && sigs[i].tick <= sigs[i - 1].tick) return TempoMapError::eventsNotAscending;
        if (sigs[i].num < 1 || sigs[i].num > kMaxTimeSigNumerator || !isValidDenominator(sigs[i].den)) {
            return TempoMapError::invalidTimeSignature;
        }
    }
    return TempoMapError::ok;
}

static const char* errorName(TempoMapError e) {
    switch (e) {
        case TempoMapError::ok: return "ok";
        case TempoMapError::noTempoEvents: return "noTempoEvents";
        case TempoMapError::noTimeSignatures: return "noTimeSignatures";
        case TempoMapError::firstEventNotAtTickZero: return "firstEventNotAtTickZero";
        case TempoMapError::eventsNotAscending: return "eventsNotAscending";
        case TempoMapError::tempoOutOfRange: return "tempoOutOfRange";
        case TempoMapError::invalidTimeSignature: return "invalidTimeSignature";
        case TempoMapError::sampleRateOutOfRange: return "sampleRateOutOfRange";
    }
    return "unknown";
}

Result<TempoMap> TempoMap::make(const TempoEventList& tempos, const TimeSigEventList& sigs,
                                double sampleRate) {
    const TempoMapError error = validate(tempos, sigs, sampleRate);
    if (error != TempoMapError::ok) {
        return makeError(ErrorCode::invalidArgument, std::string("tempo map: ") + errorName(error));
    }
    return TempoMap(tempos, sigs, sampleRate);
}

TempoMap::TempoMap(const TempoEventList& tempos, const TimeSigEventList& sigs, double sampleRate)
    : sampleRate_(sampleRate) {
    tempo_.reserve(tempos.size());
    for (const TempoEvent& e : tempos) {
        double start = 0.0;
        if (!tempo_.empty()) {
            const TempoSegment& prev = tempo_.back();
            // TIME-001: accumulate in double; only the outputs are rounded.
            start = prev.startSample +
                    (static_cast<double>(e.tick) - static_cast<double>(prev.tick)) * prev.samplesPerTick;
        }
        tempo_.push_back({e.tick, e.bpm, start, samplesPerTick(sampleRate, e.bpm)});
    }

    sig_.reserve(sigs.size());
    for (const TimeSigEvent& e : sigs) {
        int64_t firstBar = 1;
        if (!sig_.empty()) {
            const SigSegment& prev = sig_.back();
            // A partial last bar still counts as a bar (see TimeSigEvent).
            firstBar = prev.firstBar + ceilDiv(e.tick - prev.tick, prev.barTicks);
        }
        const int64_t beatTicks = int64_t{kPPQ} * 4 / e.den;
        sig_.push_back({e.tick, e.num, e.den, firstBar, beatTicks, beatTicks * e.num});
    }
}

size_t TempoMap::tempoSegmentAt(Tick tick) const DAW_RT {
    auto it = std::upper_bound(tempo_.begin(), tempo_.end(), tick,
                               [](Tick t, const TempoSegment& s) { return t < s.tick; });
    return it == tempo_.begin() ? 0 : static_cast<size_t>(it - tempo_.begin()) - 1;
}

size_t TempoMap::sigSegmentAt(Tick tick) const DAW_RT {
    auto it = std::upper_bound(sig_.begin(), sig_.end(), tick,
                               [](Tick t, const SigSegment& s) { return t < s.tick; });
    return it == sig_.begin() ? 0 : static_cast<size_t>(it - sig_.begin()) - 1;
}

SamplePos TempoMap::tickToSample(Tick tick) const DAW_RT {
    const TempoSegment& s = tempo_[tempoSegmentAt(tick)];
    // Subtract as doubles: exact for any realistic tick, and can't overflow for extreme ones.
    return roundToInt64(s.startSample +
                        (static_cast<double>(tick) - static_cast<double>(s.tick)) * s.samplesPerTick);
}

Tick TempoMap::sampleToTick(SamplePos sample) const DAW_RT {
    // tickToSample(t) <= sample  ⇔  exact position of t < sample + 0.5 (up to ties), so the
    // answer is the last tick before sample + 0.5. Find its segment, solve, then correct the
    // estimate against tickToSample itself so the two functions agree exactly.
    const double target = static_cast<double>(sample) + 0.5;
    auto it = std::upper_bound(tempo_.begin(), tempo_.end(), target,
                               [](double x, const TempoSegment& s) { return x < s.startSample; });
    const TempoSegment& s = tempo_[it == tempo_.begin() ? 0 : static_cast<size_t>(it - tempo_.begin()) - 1];
    const double offset = std::ceil((target - s.startSample) / s.samplesPerTick) - 1.0;
    Tick t = clampToInt64(static_cast<double>(s.tick) + offset);

    // The estimate is off by at most one tick (ties, last-bit differences); 4 steps is a margin.
    for (int i = 0; i < 4 && tickToSample(t + 1) <= sample; ++i) ++t;
    for (int i = 0; i < 4 && tickToSample(t) > sample; ++i) --t;
    return t;
}

double TempoMap::bpmAt(Tick tick) const DAW_RT {
    return tempo_[tempoSegmentAt(tick)].bpm;
}

BBT TempoMap::tickToBBT(Tick tick) const DAW_RT {
    const SigSegment& s = sig_[sigSegmentAt(tick)];
    const int64_t rel = tick - s.tick;
    const int64_t barIndex = floorDiv(rel, s.barTicks);
    const int64_t inBar = rel - barIndex * s.barTicks;
    return {s.firstBar + barIndex, static_cast<int32_t>(inBar / s.beatTicks + 1),
            static_cast<int32_t>(inBar % s.beatTicks)};
}

Tick TempoMap::bbtToTick(BBT bbt) const DAW_RT {
    auto it = std::upper_bound(sig_.begin(), sig_.end(), bbt.bar,
                               [](int64_t bar, const SigSegment& s) { return bar < s.firstBar; });
    const SigSegment& s = sig_[it == sig_.begin() ? 0 : static_cast<size_t>(it - sig_.begin()) - 1];
    return s.tick + (bbt.bar - s.firstBar) * s.barTicks + int64_t{bbt.beat - 1} * s.beatTicks + bbt.tick;
}

}  // namespace daw
