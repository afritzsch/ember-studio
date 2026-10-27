#pragma once
// IO-004: carries device input from a separate input device's IO thread to the output IO cycle.
// The two devices share a clock, so in the long run as many frames arrive as are consumed; the
// FIFO absorbs the phase between the two IO threads.
//
// Single producer (the input device's IO thread), single consumer (the output IO cycle), both
// RT and wait-free (CONV-RT-05). Non-interleaved float32.

#include <atomic>
#include <cstdint>
#include <vector>

#include "core/Realtime.h"
#include "core/Result.h"

namespace daw {

class InputFifo {
public:
    InputFifo() = default;
    InputFifo(const InputFifo&) = delete;
    InputFifo& operator=(const InputFifo&) = delete;

    // Non-RT, while neither side runs. `capacityFrames` is rounded up to a power of two.
    Result<void> configure(uint32_t channels, uint32_t capacityFrames);
    // Non-RT, while neither side runs: empties it.
    void reset();

    uint32_t channels() const DAW_RT { return channels_; }
    uint32_t capacity() const DAW_RT { return static_cast<uint32_t>(mask_ + 1); }

    // Producer. Writes the leading frames that fit and returns how many; channels beyond
    // `numChannels` are written as silence, extra source channels are ignored.
    uint32_t write(const float* const* source, uint32_t numChannels, uint32_t numFrames) DAW_RT;

    // Consumer.
    uint32_t available() const DAW_RT;
    // Fills `numFrames` frames of `dest` for one IO cycle. With fewer than numFrames available
    // it reads nothing, clears `dest` and returns 0 (an underrun: the input device hasn't caught
    // up yet). With more than numFrames + maxBacklog available, the oldest excess is dropped
    // first, so input latency can't creep up. Returns the frames read.
    uint32_t pull(float* const* dest, uint32_t numChannels, uint32_t numFrames,
                  uint32_t maxBacklog) DAW_RT;

    // Diagnostics (relaxed): frames dropped because the FIFO was full or the backlog too long,
    // and cycles that found too little input.
    uint64_t overflowFrames() const { return overflowFrames_.load(std::memory_order_relaxed); }
    uint64_t droppedFrames() const { return droppedFrames_.load(std::memory_order_relaxed); }
    uint64_t underruns() const { return underruns_.load(std::memory_order_relaxed); }

private:
    float* channel(uint32_t c) DAW_RT { return storage_.data() + std::size_t{c} * (mask_ + 1); }

    std::vector<float> storage_;  // channels_ × capacity, channel-major
    uint32_t channels_ = 0;
    uint64_t mask_ = 0;
    // Frame counters that count up forever (64-bit, no wrap in practice), masked on access.
    std::atomic<uint64_t> write_{0};
    std::atomic<uint64_t> read_{0};
    std::atomic<uint64_t> overflowFrames_{0};
    std::atomic<uint64_t> droppedFrames_{0};
    std::atomic<uint64_t> underruns_{0};
};

} // namespace daw
