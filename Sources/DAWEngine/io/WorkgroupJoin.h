#pragma once
// IO-002: keeps the audio thread (the output device's IO thread, CONV §3 daw.audio) joined to the
// device's os_workgroup (kAudioDevicePropertyIOThreadOSWorkgroup), so the scheduler treats our
// render work as part of the device's real-time deadline.
//
// A thread can only join and leave a workgroup itself, so this runs on the IO thread: the first
// cycle joins, and a cycle on a different thread (the HAL recreated its IO thread) joins again.
// Leaving is requested from the stopping thread and done by the next cycle, before the device
// stops. A HAL IO thread may already be a member, in which case join reports EALREADY; that
// counts as joined but there is nothing to leave.
//
// The os_workgroup calls go through WorkgroupOps so the bookkeeping is testable without a device.
// onCycle() runs in the IO cycle (DAW_RT), outside the engine's RtScope.

#include <atomic>
#include <cerrno>
#include <cstdint>

#include "core/Realtime.h"

namespace daw {

// os_workgroup_t and os_workgroup_join_token_t, type-erased so this header stays framework-free.
// The IO-thread operations must be nonblocking (CONV-RT-06); release runs only in attach().
struct WorkgroupOps {
    using JoinFn = int (*)(void* workgroup, void* token) DAW_RT;  // 0, EALREADY, EINVAL, …
    using LeaveFn = void (*)(void* workgroup, void* token) DAW_RT;
    using ThreadIdFn = uint64_t (*)() DAW_RT;                     // the calling thread
    using ReleaseFn = void (*)(void* workgroup);                  // drops attach()'s reference

    JoinFn join = nullptr;
    LeaveFn leave = nullptr;
    ThreadIdFn threadId = nullptr;
    ReleaseFn release = nullptr;
};

// os_workgroup_join / os_workgroup_leave / os_release / pthread_threadid_np.
WorkgroupOps systemWorkgroupOps();

enum class WorkgroupState : uint8_t {
    none,           // no workgroup attached (no device, or the device has none)
    pending,        // attached, no cycle yet
    joined,         // this thread joined (join returned 0)
    alreadyMember,  // join returned EALREADY: the IO thread was already in a workgroup
    failed,         // join returned another error (lastJoinResult); cycles still render
    left,           // a leave was requested and done (if this thread had joined); cycles output
                    // silence until the next attach()
};

class WorkgroupJoin {
public:
    static constexpr uint32_t kTokenSize = 64;  // >= sizeof(os_workgroup_join_token_s)

    explicit WorkgroupJoin(WorkgroupOps ops = systemWorkgroupOps());
    ~WorkgroupJoin();  // releases the workgroup
    WorkgroupJoin(const WorkgroupJoin&) = delete;
    WorkgroupJoin& operator=(const WorkgroupJoin&) = delete;

    // Non-RT, while no cycle runs. Takes over one reference to `workgroup` (null: none), releases
    // the previous one, and starts over: the next cycle joins.
    void attach(void* workgroup);

    // IO thread, at the start of every cycle. Returns false once a leave was requested: the
    // cycle must output silence and not render.
    bool onCycle() DAW_RT;

    // Non-RT. Asks the IO thread to leave at its next cycle; leaveDone() turns true once a cycle
    // has seen the request (whether or not there was anything to leave).
    void requestLeave();
    bool leaveDone() const { return leaveDone_.load(std::memory_order_acquire); }

    // Any thread.
    WorkgroupState state() const { return state_.load(std::memory_order_acquire); }
    int lastJoinResult() const { return lastJoinResult_.load(std::memory_order_relaxed); }
    uint32_t joinAttempts() const { return joinAttempts_.load(std::memory_order_relaxed); }
    // Joins left behind because the IO thread changed: the old thread can no longer leave.
    uint32_t abandonedJoins() const { return abandoned_.load(std::memory_order_relaxed); }

private:
    WorkgroupOps ops_;
    void* workgroup_ = nullptr;
    alignas(16) unsigned char token_[kTokenSize] = {};
    uint64_t thread_ = 0;  // IO thread only: the thread the last join was attempted on
    std::atomic<WorkgroupState> state_{WorkgroupState::none};
    std::atomic<int> lastJoinResult_{0};
    std::atomic<uint32_t> joinAttempts_{0};
    std::atomic<uint32_t> abandoned_{0};
    std::atomic<bool> leaveRequested_{false};
    std::atomic<bool> leaveDone_{false};
};

} // namespace daw
