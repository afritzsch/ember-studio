#pragma once
// AUTO-006 (T-075, 11 "Contract delta (T-075)"): lanes the model has suspended while the user
// records a gesture on their target. A suspended lane neither plays nor writes its value while
// stopped, so the control's own writes (setParam) reach the param slot and the engine never
// fights the user. Resuming hands the slot back to the lane from the next block on.
//
// A fixed table of lane IDs (0 = free) that lives in the Engine, outside any RenderGraph, so a
// graph swap mid-gesture (the commit of the recording itself) keeps the lane suspended. Setters
// run on any non-RT thread (the facade, main thread) and claim/free entries with CAS; the audio
// thread only loads (CONV-RT-05). A lane suspended twice is held once; resuming frees it.

#include <array>
#include <atomic>
#include <cstdint>

#include "core/Realtime.h"

namespace daw {

class AutomationSuspension {
public:
    // At most this many lanes are suspended at once (one per held control, plus latch/write
    // lanes until stop). A suspend beyond it is refused (returns false) and the lane keeps playing.
    static constexpr uint32_t kCapacity = 64;

    AutomationSuspension() {
        for (auto& e : entries_) e.store(0, std::memory_order_relaxed);
    }
    AutomationSuspension(const AutomationSuspension&) = delete;
    AutomationSuspension& operator=(const AutomationSuspension&) = delete;

    // Non-RT. Lane ID 0 is never a lane (ModelIDs start at 1) and is ignored.
    bool suspend(uint64_t laneID) {
        if (laneID == 0) return false;
        if (contains(laneID)) return true;
        for (auto& e : entries_) {
            uint64_t expected = 0;
            if (e.compare_exchange_strong(expected, laneID, std::memory_order_acq_rel)) {
                count_.fetch_add(1, std::memory_order_release);
                return true;
            }
        }
        return false;
    }

    // Non-RT. Resumes the lane (nothing if it wasn't suspended).
    void resume(uint64_t laneID) {
        if (laneID == 0) return;
        for (auto& e : entries_) {
            uint64_t expected = laneID;
            if (e.compare_exchange_strong(expected, 0, std::memory_order_acq_rel))
                count_.fetch_sub(1, std::memory_order_release);
        }
    }

    // Non-RT. Resumes every lane (a project replaced, the model detached).
    void resumeAll() {
        for (auto& e : entries_) {
            if (e.exchange(0, std::memory_order_acq_rel) != 0) count_.fetch_sub(1, std::memory_order_release);
        }
    }

    // RT. CONV-RT-04: bounded by kCapacity, and skipped entirely while nothing is suspended.
    bool contains(uint64_t laneID) const DAW_RT {
        if (count_.load(std::memory_order_acquire) == 0) return false;
        for (const auto& e : entries_)
            if (e.load(std::memory_order_acquire) == laneID) return true;
        return false;
    }

    uint32_t size() const DAW_RT { return count_.load(std::memory_order_acquire); }

private:
    std::array<std::atomic<uint64_t>, kCapacity> entries_;
    std::atomic<uint32_t> count_{0};
};

} // namespace daw
