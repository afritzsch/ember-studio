#pragma once
// MIX-005: peak + RMS over the last 300 ms, for a channel strip's telemetry meter (DW-048: the
// window is the strip's job; Telemetry only stores the latest pair).
//
// The window is kept as 300 chunks of ~1 ms (round(sampleRate / 1000) frames), each holding its
// peak and sum of squares, plus the chunk being filled. A reading covers the 300 complete chunks
// and the partial one, so it spans 300 … 301 ms. Recomputing the totals from the chunks (in
// groups of 20, each recomputed when one of its chunks completes; T-091) means nothing drifts the
// way a running sum with subtraction would, and no per-sample history is needed. Before 300 ms have been seen, the missing past counts as silence.
//
// Stereo frames meter as one signal: peak = max(|L|, |R|), mean square = (L² + R²) / 2, so a sine
// of amplitude A in both channels reads peak A and RMS A/√2.

#include <array>
#include <cstdint>

#include "core/Realtime.h"
#include "core/Telemetry.h"

namespace daw {

class MeterWindow {
public:
    static constexpr uint32_t kChunks = 300;

    // Non-RT. Sets the chunk length for `sampleRate` and clears the window.
    void prepare(double sampleRate);
    // Forgets everything seen so far (reads 0 until new audio arrives).
    void reset() DAW_RT;

    // Adds `numFrames` frames. `right` may equal `left` for a mono signal.
    void add(const float* left, const float* right, uint32_t numFrames) DAW_RT;

    MeterReading reading() const DAW_RT;

    uint32_t chunkFrames() const DAW_RT { return chunkFrames_; }

private:
    uint32_t chunkFrames_ = 48;
    std::array<float, kChunks> chunkPeak_{};
    std::array<double, kChunks> chunkSumSq_{};
    // T-091 (TEST-008): the chunks in groups of kGroup, each group's peak and sum recomputed from
    // its chunks whenever one of them completes, so a reading adds 15 groups instead of 300
    // chunks and still nothing drifts.
    static constexpr uint32_t kGroup = 20;
    static constexpr uint32_t kGroups = kChunks / kGroup;
    static_assert(kChunks % kGroup == 0);
    std::array<float, kGroups> groupPeak_{};
    std::array<double, kGroups> groupSumSq_{};
    uint32_t next_ = 0;  // the chunk slot the partial chunk goes into when it completes
    float partialPeak_ = 0.0f;
    double partialSumSq_ = 0.0;
    uint32_t partialFrames_ = 0;
};

} // namespace daw
