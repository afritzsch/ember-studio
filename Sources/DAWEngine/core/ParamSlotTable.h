#pragma once
// ENG-020..023: param slots, the path continuous values (faders, knobs, automation) take to the
// audio thread without a snapshot (D-09). A slot is a pair of atomics in a table that is
// preallocated at construction and never grows or shrinks, so a ParamID is a plain index and a
// slot never moves. Snapshot NodeConfigs hold ParamIDs, not values (ENG-023): writing a value
// touches nothing but the slot, so it rebuilds and publishes nothing.
//
// Threads: allocate()/free() are non-RT and may be called from any non-RT thread (they take a
// lock). get()/set() are RT-safe from any thread, the audio thread included (AUTO-002 writes
// automation values there before nodes process).

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

#include "core/Realtime.h"
#include "core/Result.h"

namespace daw {

using ParamID = uint32_t;

struct ParamSlot {
    std::atomic<float> value{0.0f};
    // Counts writes made through the table (set() and allocate()), so a reader can tell that a
    // slot was written since it last looked even if the value didn't change (e.g. PLUG-015 pushes
    // only changed plugin params). It wraps, so compare for equality only.
    std::atomic<uint32_t> generation{0};
};

// The slots must be readable and writable from the audio thread without a lock.
static_assert(std::atomic<float>::is_always_lock_free);
static_assert(std::atomic<uint32_t>::is_always_lock_free);

class ParamSlotTable {
public:
    static constexpr uint32_t kDefaultCapacity = 65'536; // ENG-020

    // Non-RT. Allocates all `capacity` slots up front: all free, value 0.
    explicit ParamSlotTable(uint32_t capacity = kDefaultCapacity);
    ~ParamSlotTable();
    // Slots are referenced by address and by index from other threads, so the table stays put.
    ParamSlotTable(const ParamSlotTable&) = delete;
    ParamSlotTable& operator=(const ParamSlotTable&) = delete;

    uint32_t capacity() const DAW_RT { return capacity_; }

    // Non-RT. Reserves `count` contiguous slots (a node's params are one range, see NodeDesc::
    // firstParam/numParams in 05), sets each to `initialValue` and returns the first ID.
    // invalidArgument for count 0; outOfMemory when no free run of `count` slots is left.
    Result<ParamID> allocate(uint32_t count = 1, float initialValue = 0.0f);

    // Non-RT. Returns [first, first + count) to the table. Every slot in the range must be
    // allocated, otherwise it fails with invalidArgument and frees nothing; any part of an
    // allocation may be freed. A freed slot can be handed out again at once, so free a node's
    // slots only after no live graph references them.
    Result<void> free(ParamID first, uint32_t count = 1);

    // Non-RT.
    uint32_t allocatedCount() const;
    bool isAllocated(ParamID id) const;

    // ENG-021: RT-safe from any thread. Relaxed, because a slot carries one independent value and
    // publishes nothing else; a reader picks up a write at its next block. Nodes read each param
    // once per block and ramp to it (ParamSmoother, ENG-022). `id` must be < capacity().
    void set(ParamID id, float value) DAW_RT {
        DAW_RT_ASSERT(id < capacity_);
        slots_[id].value.store(value, std::memory_order_relaxed);
        slots_[id].generation.fetch_add(1, std::memory_order_relaxed);
    }
    float get(ParamID id) const DAW_RT {
        DAW_RT_ASSERT(id < capacity_);
        return slots_[id].value.load(std::memory_order_relaxed);
    }
    uint32_t generation(ParamID id) const DAW_RT {
        DAW_RT_ASSERT(id < capacity_);
        return slots_[id].generation.load(std::memory_order_relaxed);
    }
    // Read-only: writes go through set() so the generation stays in step.
    const ParamSlot& slot(ParamID id) const DAW_RT {
        DAW_RT_ASSERT(id < capacity_);
        return slots_[id];
    }

private:
    const std::unique_ptr<ParamSlot[]> slots_;
    const uint32_t capacity_;

    // Allocation state. Only allocate()/free() and the non-RT queries touch it, under the lock;
    // RT paths never do.
    mutable std::mutex mutex_;
    std::vector<bool> allocated_;
    uint32_t allocatedCount_ = 0;
    uint32_t firstFree_ = 0; // no free slot below this index
};

} // namespace daw
