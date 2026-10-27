#include "io/WorkgroupJoin.h"

#include <os/workgroup.h>
#include <pthread.h>

namespace daw {

static_assert(sizeof(os_workgroup_join_token_s) <= WorkgroupJoin::kTokenSize);

// IO-002: os_workgroup_join/leave exist to be called by real-time threads on themselves (Apple,
// "Adding Parallel Real-Time Threads to Audio Workgroups"), and pthread_threadid_np for the
// calling thread reads its id from thread-local storage. None of them allocates or locks; the
// effect analysis can't know that about unannotated libSystem functions.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunknown-warning-option"
#pragma clang diagnostic ignored "-Wfunction-effects"
static int systemJoin(void* workgroup, void* token) DAW_RT {
    return os_workgroup_join(static_cast<os_workgroup_t>(workgroup),
                             static_cast<os_workgroup_join_token_t>(token));
}
static void systemLeave(void* workgroup, void* token) DAW_RT {
    os_workgroup_leave(static_cast<os_workgroup_t>(workgroup),
                       static_cast<os_workgroup_join_token_t>(token));
}
static uint64_t systemThreadId() DAW_RT {
    uint64_t id = 0;
    pthread_threadid_np(nullptr, &id);
    return id;
}
#pragma clang diagnostic pop

static void systemRelease(void* workgroup) { os_release(static_cast<os_workgroup_t>(workgroup)); }

WorkgroupOps systemWorkgroupOps() {
    WorkgroupOps ops;
    ops.join = &systemJoin;
    ops.leave = &systemLeave;
    ops.threadId = &systemThreadId;
    ops.release = &systemRelease;
    return ops;
}

WorkgroupJoin::WorkgroupJoin(WorkgroupOps ops) : ops_(ops) {}

WorkgroupJoin::~WorkgroupJoin() { attach(nullptr); }

void WorkgroupJoin::attach(void* workgroup) {
    if (workgroup_ != nullptr && ops_.release != nullptr) ops_.release(workgroup_);
    workgroup_ = workgroup;
    thread_ = 0;
    lastJoinResult_.store(0, std::memory_order_relaxed);
    leaveRequested_.store(false, std::memory_order_relaxed);
    leaveDone_.store(false, std::memory_order_relaxed);
    state_.store(workgroup != nullptr ? WorkgroupState::pending : WorkgroupState::none,
                 std::memory_order_release);
}

bool WorkgroupJoin::onCycle() DAW_RT {
    const WorkgroupState state = state_.load(std::memory_order_relaxed);
    if (leaveRequested_.load(std::memory_order_acquire)) {
        if (state == WorkgroupState::left) return false;
        // Only a join that returned 0 has a token to leave, and only on the joining thread.
        if (state == WorkgroupState::joined) {
            if (ops_.threadId() == thread_)
                ops_.leave(workgroup_, token_);
            else
                abandoned_.fetch_add(1, std::memory_order_relaxed);
        }
        if (state != WorkgroupState::none)
            state_.store(WorkgroupState::left, std::memory_order_release);
        leaveDone_.store(true, std::memory_order_release);
        return false;
    }
    if (state == WorkgroupState::none) return true;

    const uint64_t thread = ops_.threadId();
    if (state != WorkgroupState::pending && thread == thread_) return true;  // the common case

    // First cycle, or the HAL moved IO to a new thread: join from this one. A join made on the
    // old thread can't be left from here; that thread is gone, so the token is just dropped.
    if (state == WorkgroupState::joined) abandoned_.fetch_add(1, std::memory_order_relaxed);
    thread_ = thread;
    const int result = ops_.join(workgroup_, token_);
    joinAttempts_.fetch_add(1, std::memory_order_relaxed);
    lastJoinResult_.store(result, std::memory_order_relaxed);
    state_.store(result == 0           ? WorkgroupState::joined
                 : result == EALREADY  ? WorkgroupState::alreadyMember
                                       : WorkgroupState::failed,
                 std::memory_order_release);
    return true;
}

void WorkgroupJoin::requestLeave() {
    leaveDone_.store(false, std::memory_order_relaxed);
    leaveRequested_.store(true, std::memory_order_release);
}

} // namespace daw
