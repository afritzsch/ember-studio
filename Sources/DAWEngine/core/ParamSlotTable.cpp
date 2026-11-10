#include "core/ParamSlotTable.h"

#include <algorithm>

namespace daw {

ParamSlotTable::ParamSlotTable(uint32_t capacity)
    : slots_(new ParamSlot[capacity]), capacity_(capacity), afterWrap_(new AfterWrap[capacity]),
      allocated_(capacity, false) {}

ParamSlotTable::~ParamSlotTable() = default;

Result<ParamID> ParamSlotTable::allocate(uint32_t count, float initialValue) {
    if (count == 0) return makeError(ErrorCode::invalidArgument, "ParamSlotTable: count is 0");

    std::lock_guard<std::mutex> lock(mutex_);
    if (count > capacity_ - allocatedCount_)
        return makeError(ErrorCode::outOfMemory, "ParamSlotTable: not enough free slots");

    // First fit. The table is small (ENG-020: 64k flags) and this is off the audio thread, so a
    // linear scan is fine.
    uint32_t run = 0;
    for (uint32_t i = firstFree_; i < capacity_; ++i) {
        run = allocated_[i] ? 0 : run + 1;
        if (run < count) continue;

        const ParamID first = i + 1 - count;
        for (uint32_t id = first; id <= i; ++id) {
            allocated_[id] = true;
            slots_[id].value.store(initialValue, std::memory_order_relaxed);
            slots_[id].generation.fetch_add(1, std::memory_order_relaxed);
        }
        allocatedCount_ += count;
        if (first == firstFree_) {
            firstFree_ = i + 1;
            while (firstFree_ < capacity_ && allocated_[firstFree_]) ++firstFree_;
        }
        return first;
    }
    return makeError(ErrorCode::outOfMemory, "ParamSlotTable: no contiguous run of free slots");
}

Result<void> ParamSlotTable::free(ParamID first, uint32_t count) {
    if (count == 0 || first >= capacity_ || count > capacity_ - first)
        return makeError(ErrorCode::invalidArgument, "ParamSlotTable: range out of bounds");

    std::lock_guard<std::mutex> lock(mutex_);
    for (uint32_t id = first; id < first + count; ++id)
        if (!allocated_[id])
            return makeError(ErrorCode::invalidArgument, "ParamSlotTable: slot not allocated");

    for (uint32_t id = first; id < first + count; ++id) allocated_[id] = false;
    allocatedCount_ -= count;
    firstFree_ = std::min(firstFree_, first);
    return {};
}

uint32_t ParamSlotTable::allocatedCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return allocatedCount_;
}

bool ParamSlotTable::isAllocated(ParamID id) const {
    if (id >= capacity_) return false;
    std::lock_guard<std::mutex> lock(mutex_);
    return allocated_[id];
}

} // namespace daw
