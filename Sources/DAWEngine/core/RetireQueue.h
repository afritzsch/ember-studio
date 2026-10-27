#pragma once
// ENG-014: the audio thread never frees memory. When RT code is done with a heap object it hands
// it here, and daw.reclaim (Reclaimer) destroys it. SPSC: the audio thread is the only producer,
// daw.reclaim the only consumer.

#include <cstddef>

#include "core/Realtime.h"
#include "core/SpscQueue.h"

namespace daw {

// A type-erased owning pointer: destroy(object) runs on daw.reclaim. At namespace scope because
// SpscQueue's default-constructible check can't see a nested class's member initializers yet.
struct RetiredObject {
    void (*destroy)(void*) = nullptr;
    void* object = nullptr;
};

class RetireQueue {
public:
    static constexpr std::size_t kCapacity = 1024;
    using Item = RetiredObject;

    // RT, audio thread only. Takes ownership of `object` (allocated with new) on success. Returns
    // false when the queue is full; the caller keeps the object and retries on a later block.
    template <class T>
    bool retire(T* object) DAW_RT {
        if (object == nullptr) return true;
        return queue_.push(Item{&destroyAs<T>, object});
    }

    // daw.reclaim only. Pops one item; false when empty.
    bool pop(Item& out) DAW_RT { return queue_.pop(out); }

    std::size_t sizeApprox() const DAW_RT { return queue_.sizeApprox(); }

private:
    template <class T>
    static void destroyAs(void* object) {
        delete static_cast<T*>(object);
    }

    SpscQueue<Item, kCapacity> queue_;
};

} // namespace daw
