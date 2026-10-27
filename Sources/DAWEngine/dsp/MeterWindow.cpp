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
    next_ = 0;
    partialPeak_ = 0.0f;
    partialSumSq_ = 0.0;
    partialFrames_ = 0;
}

void MeterWindow::add(const float* left, const float* right, uint32_t numFrames) DAW_RT {
    for (uint32_t f = 0; f < numFrames; ++f) {
        const float l = left[f];
        const float r = right[f];
        partialPeak_ = std::max({partialPeak_, std::fabs(l), std::fabs(r)});
        partialSumSq_ += 0.5 * (static_cast<double>(l) * l + static_cast<double>(r) * r);
        if (++partialFrames_ < chunkFrames_) continue;
        chunkPeak_[next_] = partialPeak_;
        chunkSumSq_[next_] = partialSumSq_;
        next_ = next_ + 1 == kChunks ? 0 : next_ + 1;
        partialPeak_ = 0.0f;
        partialSumSq_ = 0.0;
        partialFrames_ = 0;
    }
}

MeterReading MeterWindow::reading() const DAW_RT {
    float peak = partialPeak_;
    double sumSq = partialSumSq_;
    for (uint32_t i = 0; i < kChunks; ++i) {
        peak = std::max(peak, chunkPeak_[i]);
        sumSq += chunkSumSq_[i];
    }
    const double frames = static_cast<double>(kChunks) * chunkFrames_ + partialFrames_;
    return MeterReading{peak, static_cast<float>(std::sqrt(std::max(0.0, sumSq) / frames))};
}

} // namespace daw
