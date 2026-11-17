#include "dsp/MeterWindow.h"

#include <algorithm>
#include <cmath>

namespace daw {

void MeterWindow::prepare(double sampleRate) {
    chunkFrames_ = static_cast<uint32_t>(std::max(1.0, std::round(sampleRate / 1000.0)));
    reset();
}

void MeterWindow::reset() DAW_RT {
    chunkPeak_.fill(0.0f);
    chunkSumSq_.fill(0.0);
    groupPeak_.fill(0.0f);
    groupSumSq_.fill(0.0);
    next_ = 0;
    partialPeak_ = 0.0f;
    partialSumSq_ = 0.0;
    partialFrames_ = 0;
}

void MeterWindow::add(const float* left, const float* right, uint32_t numFrames) DAW_RT {
    // T-091 (TEST-008): a run of frames up to the end of the chunk being filled at a time, with
    // four independent maxima and sums so the inner loop vectorizes (every strip meters every
    // block). Each frame's term is the same; only the order of the additions within a chunk
    // differs from adding one frame at a time.
    uint32_t f = 0;
    while (f < numFrames) {  // CONV-RT-04: each pass takes at least one frame
        const uint32_t take = std::min(numFrames - f, chunkFrames_ - partialFrames_);
        const float* l = left + f;
        const float* r = right + f;
        float peaks[4] = {partialPeak_, 0.0f, 0.0f, 0.0f};
        double sums[4] = {partialSumSq_, 0.0, 0.0, 0.0};
        uint32_t i = 0;
        for (; i + 4 <= take; i += 4) {
            for (uint32_t k = 0; k < 4; ++k) {
                const float a = std::fabs(l[i + k]), b = std::fabs(r[i + k]);
                const float m = a > b ? a : b;
                peaks[k] = m > peaks[k] ? m : peaks[k];
                sums[k] += 0.5 * (static_cast<double>(l[i + k]) * l[i + k] + static_cast<double>(r[i + k]) * r[i + k]);
            }
        }
        for (; i < take; ++i) {
            const float a = std::fabs(l[i]), b = std::fabs(r[i]);
            const float m = a > b ? a : b;
            peaks[0] = m > peaks[0] ? m : peaks[0];
            sums[0] += 0.5 * (static_cast<double>(l[i]) * l[i] + static_cast<double>(r[i]) * r[i]);
        }
        partialPeak_ = std::max(std::max(peaks[0], peaks[1]), std::max(peaks[2], peaks[3]));
        partialSumSq_ = (sums[0] + sums[1]) + (sums[2] + sums[3]);
        partialFrames_ += take;
        f += take;
        if (partialFrames_ < chunkFrames_) continue;
        chunkPeak_[next_] = partialPeak_;
        chunkSumSq_[next_] = partialSumSq_;
        const uint32_t first = next_ / kGroup * kGroup;
        float groupPeak = 0.0f;
        double groupSum = 0.0;
        for (uint32_t i = first; i < first + kGroup; ++i) {
            groupPeak = chunkPeak_[i] > groupPeak ? chunkPeak_[i] : groupPeak;
            groupSum += chunkSumSq_[i];
        }
        groupPeak_[next_ / kGroup] = groupPeak;
        groupSumSq_[next_ / kGroup] = groupSum;
        next_ = next_ + 1 == kChunks ? 0 : next_ + 1;
        partialPeak_ = 0.0f;
        partialSumSq_ = 0.0;
        partialFrames_ = 0;
    }
}

MeterReading MeterWindow::reading() const DAW_RT {
    // T-091 (TEST-008): every strip reads once per block; the group totals keep that to 15 adds.
    float peak = partialPeak_;
    double sumSq = partialSumSq_;
    for (uint32_t g = 0; g < kGroups; ++g) {
        peak = groupPeak_[g] > peak ? groupPeak_[g] : peak;
        sumSq += groupSumSq_[g];
    }
    const double frames = static_cast<double>(kChunks) * chunkFrames_ + partialFrames_;
    return MeterReading{peak, static_cast<float>(std::sqrt(std::max(0.0, sumSq) / frames))};
}

} // namespace daw
