// Debug RT safety trap (ENG-030..033). See RtTrap.h for the approach.
#include "core/RtTrap.h"

#if DAW_RT_TRAP

#include <array>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include <dlfcn.h>
#include <execinfo.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <os/lock.h>
#include <pthread.h>
#include <unistd.h>

// libmalloc calls this for every allocation and deallocation while it is set (it's how
// MallocStackLogging and Instruments observe the heap). Not in a public header; the symbol is
// exported by libsystem_malloc. Flag values are from libmalloc's stack_logging.h.
extern "C" {
typedef void(malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3,
                              uintptr_t result, uint32_t numHotFramesToSkip);
extern malloc_logger_t* malloc_logger;
}

#ifndef SG_READ_ONLY
#define SG_READ_ONLY 0x10 // dyld re-protects the segment read-only after fixups (__DATA_CONST)
#endif

namespace daw {
namespace {

constexpr uint32_t kMallocLogAllocate = 2;
constexpr uint32_t kMallocLogDeallocate = 4;

// ENG-030: the per-thread flag is a scope depth kept in a pthread key, not a C++ thread_local:
// Darwin allocates thread_local storage with malloc on a thread's first access, which would
// re-enter the malloc hook below. The per-thread violation counts (DW-019) live in keys too.
pthread_key_t makeKey() {
    pthread_key_t key{};
    if (pthread_key_create(&key, nullptr) != 0)
        abort();
    return key;
}
const pthread_key_t depthKey = makeKey();
const std::array<pthread_key_t, kRtViolationKindCount> threadCountKeys = {makeKey(), makeKey(),
                                                                         makeKey()};

uintptr_t scopeDepth() noexcept {
    return reinterpret_cast<uintptr_t>(pthread_getspecific(depthKey));
}
void setScopeDepth(uintptr_t depth) noexcept {
    pthread_setspecific(depthKey, reinterpret_cast<void*>(depth));
}

// uintptr_t is 64 bits on arm64 (BUILD-008), so a key holds a full uint64_t count.
uint64_t threadCount(int kind) noexcept {
    return reinterpret_cast<uintptr_t>(pthread_getspecific(threadCountKeys[kind]));
}

std::array<std::atomic<uint64_t>, kRtViolationKindCount> violationCounts{};
std::atomic<bool> abortOnViolation{false};

// ENG-032: the first violation's raw return addresses are copied on the offending thread (no
// allocation, no locks); symbolication happens later, off the audio thread, in firstViolation().
enum : int { kFirstEmpty, kFirstCapturing, kFirstReady };
constexpr int kMaxFrames = 64;
std::atomic<int> firstState{kFirstEmpty};
RtViolationKind firstKind = RtViolationKind::allocation;
std::array<void*, kMaxFrames> firstFrames{};
int firstFrameCount = 0;

const char* kindName(RtViolationKind kind) {
    switch (kind) {
    case RtViolationKind::allocation: return "allocation";
    case RtViolationKind::deallocation: return "deallocation";
    case RtViolationKind::lock: return "lock";
    }
    return "?";
}

void writeStderr(const char* text) { (void)write(STDERR_FILENO, text, strlen(text)); }

void recordViolation(RtViolationKind kind) noexcept {
    const int k = static_cast<int>(kind);
    violationCounts[k].fetch_add(1, std::memory_order_relaxed);
    // DW-019: also on the offending thread's own count, which no other thread touches.
    pthread_setspecific(threadCountKeys[k], reinterpret_cast<void*>(threadCount(k) + 1));

    int expected = kFirstEmpty;
    const bool first = firstState.compare_exchange_strong(expected, kFirstCapturing,
                                                          std::memory_order_acquire);
    const bool abortNow = abortOnViolation.load(std::memory_order_relaxed);
    if (!first && !abortNow)
        return;

    // backtrace() only walks frame pointers, but leave the RT context while it runs so that the
    // count stays exact if it ever allocates.
    const uintptr_t depth = scopeDepth();
    setScopeDepth(0);
    std::array<void*, kMaxFrames> frames;
    const int count = backtrace(frames.data(), kMaxFrames);
    if (first) {
        firstFrames = frames;
        firstFrameCount = count;
        firstKind = kind;
        firstState.store(kFirstReady, std::memory_order_release);
    }
    if (abortNow) {
        // ENG-032: DAW_RT_TRAP_ABORT=1. backtrace_symbols_fd writes without allocating.
        writeStderr("daw: RT trap: ");
        writeStderr(kindName(kind));
        writeStderr(" inside RtScope (CONV-RT-01/02), aborting (DAW_RT_TRAP_ABORT=1)\n");
        backtrace_symbols_fd(frames.data(), count, STDERR_FILENO);
        abort();
    }
    setScopeDepth(depth);
}

// MARK: Allocations (ENG-031)

malloc_logger_t* previousLogger = nullptr;

void mallocLoggerHook(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3,
                      uintptr_t result, uint32_t numHotFramesToSkip) {
    if (scopeDepth() != 0) {
        // realloc reports allocate|deallocate in one call; it's one allocation violation.
        if (type & kMallocLogAllocate)
            recordViolation(RtViolationKind::allocation);
        else if (type & kMallocLogDeallocate)
            recordViolation(RtViolationKind::deallocation);
    }
    if (previousLogger)
        previousLogger(type, arg1, arg2, arg3, result, numHotFramesToSkip + 1);
}

// MARK: Locks (ENG-031, CONV-RT-02)

// One counting forwarder per hooked function. `real` is resolved with dlsym before any symbol
// pointer is rebound, so the forwarder never calls itself.
template <int Index, typename Signature> struct LockHook;
template <int Index, typename R, typename... Args> struct LockHook<Index, R(Args...)> {
    static inline R (*real)(Args...) = nullptr;
    static R hook(Args... args) {
        if (scopeDepth() != 0)
            recordViolation(RtViolationKind::lock);
        return real(args...);
    }
};

struct LockTarget {
    const char* symbol; // as passed to dlsym
    void* hook;
    void** real;
    void* resolved;
};

template <int Index, typename Signature> LockTarget lockTarget(const char* symbol) {
    using H = LockHook<Index, Signature>;
    return {symbol, reinterpret_cast<void*>(&H::hook), reinterpret_cast<void**>(&H::real),
            nullptr};
}

// C++ member functions take `this` as their first argument (Itanium ABI), so they're forwarded
// as free functions. std::mutex and friends are hooked directly because their pthread calls
// happen inside libc++, in the shared cache, where symbol pointers can't be rebound.
std::array<LockTarget, 9> lockTargets = {
    lockTarget<0, int(pthread_mutex_t*)>("pthread_mutex_lock"),
    lockTarget<1, int(pthread_rwlock_t*)>("pthread_rwlock_rdlock"),
    lockTarget<2, int(pthread_rwlock_t*)>("pthread_rwlock_wrlock"),
    lockTarget<3, int(pthread_cond_t*, pthread_mutex_t*)>("pthread_cond_wait"),
    lockTarget<4, int(pthread_cond_t*, pthread_mutex_t*, const timespec*)>(
        "pthread_cond_timedwait"),
    lockTarget<5, void(os_unfair_lock_t)>("os_unfair_lock_lock"),
    lockTarget<6, void(void*)>("_ZNSt3__15mutex4lockEv"),
    lockTarget<7, void(void*)>("_ZNSt3__115recursive_mutex4lockEv"),
    lockTarget<8, void(void*, void*)>(
        "_ZNSt3__118condition_variable4waitERNS_11unique_lockINS_5mutexEEE"),
};

// Rebinds every symbol pointer in `header` that points at a hooked function. Called by dyld for
// each image already loaded and each one loaded later.
void rebindLockSymbols(const mach_header* header, intptr_t slide) {
    // Shared cache images are read-only and bind to each other internally; skip them.
    if (header->magic != MH_MAGIC_64 || (header->flags & MH_DYLIB_IN_CACHE))
        return;
    auto* command = reinterpret_cast<const load_command*>(
        reinterpret_cast<const char*>(header) + sizeof(mach_header_64));
    for (uint32_t i = 0; i < header->ncmds; ++i) {
        if (command->cmd == LC_SEGMENT_64) {
            auto* segment = reinterpret_cast<const segment_command_64*>(command);
            auto* sections = reinterpret_cast<const section_64*>(segment + 1);
            for (uint32_t s = 0; s < segment->nsects; ++s) {
                const uint32_t type = sections[s].flags & SECTION_TYPE;
                if (type != S_NON_LAZY_SYMBOL_POINTERS && type != S_LAZY_SYMBOL_POINTERS)
                    continue;
                auto** slots = reinterpret_cast<void**>(sections[s].addr + slide);
                const size_t count = sections[s].size / sizeof(void*);
                for (size_t slot = 0; slot < count; ++slot) {
                    for (const LockTarget& target : lockTargets) {
                        if (target.resolved == nullptr || slots[slot] != target.resolved)
                            continue;
                        const auto address = reinterpret_cast<vm_address_t>(&slots[slot]);
                        if (vm_protect(mach_task_self(), address, sizeof(void*), false,
                                       VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS)
                            break;
                        // An aligned pointer store; threads calling through it see old or new.
                        reinterpret_cast<std::atomic<void*>*>(&slots[slot])
                            ->store(target.hook, std::memory_order_relaxed);
                        if (segment->flags & SG_READ_ONLY)
                            vm_protect(mach_task_self(), address, sizeof(void*), false,
                                       VM_PROT_READ);
                        break;
                    }
                }
            }
        }
        command = reinterpret_cast<const load_command*>(reinterpret_cast<const char*>(command) +
                                                        command->cmdsize);
    }
}

void installLockHooks() {
    for (LockTarget& target : lockTargets) {
        target.resolved = dlsym(RTLD_DEFAULT, target.symbol);
        *target.real = target.resolved;
    }
    _dyld_register_func_for_add_image(rebindLockSymbols);
}

} // namespace

// MARK: RtTrap

bool RtTrap::install() {
    static std::once_flag lockHooksOnce;
    std::call_once(lockHooksOnce, installLockHooks);

    // Test suites run in parallel and each installs the trap. Two unsynchronized installs could
    // both see the old logger and the later one would chain the hook to itself.
    static std::mutex installMutex;
    std::lock_guard<std::mutex> lock(installMutex);

    const char* abortEnv = getenv("DAW_RT_TRAP_ABORT");
    abortOnViolation.store(abortEnv != nullptr && strcmp(abortEnv, "1") == 0,
                           std::memory_order_relaxed);

    if (malloc_logger != &mallocLoggerHook) {
        previousLogger = malloc_logger;
        malloc_logger = &mallocLoggerHook;
    }
    return installed();
}

bool RtTrap::installed() { return malloc_logger == &mallocLoggerHook; }

bool RtTrap::inRealtimeContext() noexcept { return scopeDepth() != 0; }

uint64_t RtTrap::violationCount() noexcept {
    uint64_t total = 0;
    for (const auto& count : violationCounts)
        total += count.load(std::memory_order_relaxed);
    return total;
}

uint64_t RtTrap::violationCount(RtViolationKind kind) noexcept {
    return violationCounts[static_cast<int>(kind)].load(std::memory_order_relaxed);
}

std::optional<RtViolationReport> RtTrap::firstViolation() {
    if (firstState.load(std::memory_order_acquire) != kFirstReady)
        return std::nullopt;
    RtViolationReport report{firstKind, {}};
    if (char** symbols = backtrace_symbols(firstFrames.data(), firstFrameCount)) {
        report.frames.assign(symbols, symbols + firstFrameCount);
        free(symbols);
    }
    return report;
}

void RtTrap::resetViolations() noexcept {
    for (auto& count : violationCounts)
        count.store(0, std::memory_order_relaxed);
    firstState.store(kFirstEmpty, std::memory_order_release);
}

// These only touch pthread keys (loads and stores into the thread's TSD array), which neither
// allocate nor block. The effect analysis can't see that through the pthread API.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunknown-warning-option"
#pragma clang diagnostic ignored "-Wfunction-effects"
uint64_t RtTrap::threadViolationCount() DAW_RT {
    uint64_t total = 0;
    for (int kind = 0; kind < kRtViolationKindCount; ++kind)
        total += threadCount(kind);
    return total;
}

uint64_t RtTrap::threadViolationCount(RtViolationKind kind) DAW_RT {
    return threadCount(static_cast<int>(kind));
}

void RtTrap::enterScope() DAW_RT { setScopeDepth(scopeDepth() + 1); }
void RtTrap::exitScope() DAW_RT { setScopeDepth(scopeDepth() - 1); }
#pragma clang diagnostic pop

} // namespace daw

#endif // DAW_RT_TRAP
