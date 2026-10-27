#include "io/InputFifo.h"

#include <bit>
#include <cstring>

#include "io/DriverConfig.h"

namespace daw {

Result<void> InputFifo::configure(uint32_t channels, uint32_t capacityFrames) {
    if (channels == 0 || channels > kMaxDeviceChannels)
        return makeError(ErrorCode::invalidArgument, "input FIFO channels must be in 1...32");
    if (capacityFrames == 0 || capacityFrames > (1u << 20))
        return makeError(ErrorCode::invalidArgument, "input FIFO capacity must be in 1...2^20");
    const uint32_t capacity = std::bit_ceil(capacityFrames);
    storage_.assign(std::size_t{channels} * capacity, 0.0f);
    channels_ = channels;
    mask_ = capacity - 1;
    reset();
    return {};
}

void InputFifo::reset() {
    write_.store(0, std::memory_order_relaxed);
    read_.store(0, std::memory_order_relaxed);
}

uint32_t InputFifo::write(const float* const* source, uint32_t numChannels,
                          uint32_t numFrames) DAW_RT {
    const uint64_t write = write_.load(std::memory_order_relaxed);
    const uint64_t read = read_.load(std::memory_order_acquire);
    const uint64_t space = (mask_ + 1) - (write - read);
    const auto n = static_cast<uint32_t>(numFrames < space ? numFrames : space);
    const uint64_t start = write & mask_;
    const uint64_t first = n < (mask_ + 1) - start ? n : (mask_ + 1) - start;  // before the wrap
    for (uint32_t c = 0; c < channels_; ++c) {
        float* dst = channel(c);
        if (c < numChannels) {
            std::memcpy(dst + start, source[c], first * sizeof(float));
            std::memcpy(dst, source[c] + first, (n - first) * sizeof(float));
        } else {
            std::memset(dst + start, 0, first * sizeof(float));
            std::memset(dst, 0, (n - first) * sizeof(float));
        }
    }
    write_.store(write + n, std::memory_order_release);
    if (n < numFrames) overflowFrames_.fetch_add(numFrames - n, std::memory_order_relaxed);
    return n;
}

uint32_t InputFifo::available() const DAW_RT {
    return static_cast<uint32_t>(write_.load(std::memory_order_acquire) -
                                 read_.load(std::memory_order_relaxed));
}

uint32_t InputFifo::pull(float* const* dest, uint32_t numChannels, uint32_t numFrames,
                         uint32_t maxBacklog) DAW_RT {
    uint64_t read = read_.load(std::memory_order_relaxed);
    const uint64_t avail = write_.load(std::memory_order_acquire) - read;
    if (avail < numFrames) {
        for (uint32_t c = 0; c < numChannels; ++c)
            std::memset(dest[c], 0, std::size_t{numFrames} * sizeof(float));
        underruns_.fetch_add(1, std::memory_order_relaxed);
        return 0;
    }
    if (avail - numFrames > maxBacklog) {
        const uint64_t drop = avail - numFrames - maxBacklog;
        read += drop;
        droppedFrames_.fetch_add(drop, std::memory_order_relaxed);
    }
    const uint64_t start = read & mask_;
    const uint64_t first = numFrames < (mask_ + 1) - start ? numFrames : (mask_ + 1) - start;
    for (uint32_t c = 0; c < numChannels; ++c) {
        if (c < channels_) {
            const float* src = channel(c);
            std::memcpy(dest[c], src + start, first * sizeof(float));
            std::memcpy(dest[c] + first, src, (numFrames - first) * sizeof(float));
        } else {
            std::memset(dest[c], 0, std::size_t{numFrames} * sizeof(float));
        }
    }
    read_.store(read + numFrames, std::memory_order_release);
    return numFrames;
}

} // namespace daw
