#pragma once
// ENG-060: single-producer single-consumer ring buffer, the queue that CONV-RT-05 allows for
// cross-thread traffic. Lock-free and wait-free: push and pop do a bounded amount of work and
// never loop on contention. One thread may push and one (other) thread may pop at a time.
//
// Storage is inline (std::array), so a large queue must live on the heap. Construct it off the
// audio thread; push/pop are RT-safe from either side.

#include <array>
#include <atomic>
#include <bit>
#include <cstddef>
#include <span>
#include <type_traits>

#include "core/Realtime.h"

namespace daw {

template <class T, std::size_t N = 1024>
    requires(std::is_trivially_copyable_v<T> && std::is_default_constructible_v<T> &&
             std::has_single_bit(N))
class SpscQueue {
public:
    // Indices count up forever and are masked on access, so all N slots are usable and full
    // and empty are told apart without a spare slot. 64-bit counters don't wrap in practice.
    static_assert(std::atomic<std::size_t>::is_always_lock_free);

    SpscQueue() = default;
    SpscQueue(const SpscQueue&) = delete;
    SpscQueue& operator=(const SpscQueue&) = delete;

    static constexpr std::size_t capacity() DAW_RT { return N; }

    // Producer side. Returns false (and drops nothing) when the queue is full.
    bool push(const T& item) DAW_RT {
        const std::size_t write = write_.load(std::memory_order_relaxed);
        if (write - readCache_ == N) {
            readCache_ = read_.load(std::memory_order_acquire);
            if (write - readCache_ == N) return false;
        }
        slots_[write & kMask] = item;
        write_.store(write + 1, std::memory_order_release);
        return true;
    }

    // Producer side. Pushes as many leading items as fit and returns how many that was.
    std::size_t push(std::span<const T> items) DAW_RT {
        const std::size_t write = write_.load(std::memory_order_relaxed);
        if (write - readCache_ + items.size() > N)
            readCache_ = read_.load(std::memory_order_acquire);
        const std::size_t space = N - (write - readCache_);
        const std::size_t n = items.size() < space ? items.size() : space;
        for (std::size_t i = 0; i < n; ++i) slots_[(write + i) & kMask] = items[i];
        write_.store(write + n, std::memory_order_release);
        return n;
    }

    // Consumer side. Returns false when the queue is empty; `out` is untouched then.
    bool pop(T& out) DAW_RT {
        const std::size_t read = read_.load(std::memory_order_relaxed);
        if (read == writeCache_) {
            writeCache_ = write_.load(std::memory_order_acquire);
            if (read == writeCache_) return false;
        }
        out = slots_[read & kMask];
        read_.store(read + 1, std::memory_order_release);
        return true;
    }

    // Consumer side. Pops up to out.size() items into `out` and returns how many.
    std::size_t pop(std::span<T> out) DAW_RT {
        const std::size_t read = read_.load(std::memory_order_relaxed);
        if (writeCache_ - read < out.size()) writeCache_ = write_.load(std::memory_order_acquire);
        const std::size_t available = writeCache_ - read;
        const std::size_t n = out.size() < available ? out.size() : available;
        for (std::size_t i = 0; i < n; ++i) out[i] = slots_[(read + i) & kMask];
        read_.store(read + n, std::memory_order_release);
        return n;
    }

    // Either side; exact only from a thread while the other side is idle. Callers use it for
    // telemetry and draining heuristics, never for correctness.
    std::size_t sizeApprox() const DAW_RT {
        const std::size_t read = read_.load(std::memory_order_acquire);
        const std::size_t write = write_.load(std::memory_order_acquire);
        return write - read;
    }
    bool emptyApprox() const DAW_RT { return sizeApprox() == 0; }

private:
    static constexpr std::size_t kMask = N - 1;

    // Each side's index and its cached copy of the other side's index share a cache line that
    // only that side writes, so the two threads don't false-share.
    alignas(kCacheLineSize) std::atomic<std::size_t> write_{0};
    std::size_t readCache_ = 0;  // producer-only
    alignas(kCacheLineSize) std::atomic<std::size_t> read_{0};
    std::size_t writeCache_ = 0;  // consumer-only
    alignas(kCacheLineSize) std::array<T, N> slots_{};
};

} // namespace daw
