// Debug RT safety trap (ENG-030..033). See RtTrap.h for the approach.
#include "RtTrap.h"

#if DAW_RT_TRAP

#include <array>
#include <atomic>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
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
// re-enter the malloc hook below.
pthread_key_t makeDepthKey() {
    pthread_key_t key{};
    if (pthread_key_create(&key, nullptr) != 0)
        abort();
    return key;
}
const pthread_key_t depthKey = makeDepthKey();

uintptr_t scopeDepth() noexcept {
    return reinterpret_cast<uintptr_t>(pthread_getspecific(depthKey));
}
void setScopeDepth(uintptr_t depth) noexcept {
    pthread_setspecific(depthKey, reinterpret_cast<void*>(depth));
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
    violationCounts[static_cast<int>(kind)].fetch_add(1, std::memory_order_relaxed);

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

// The scope only touches the pthread key (a store into the thread's TSD array), which neither
// allocates nor blocks. The effect analysis can't see that through the pthread API.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunknown-warning-option"
#pragma clang diagnostic ignored "-Wfunction-effects"
void RtTrap::enterScope() DAW_RT_TRAP_SCOPE_RT { setScopeDepth(scopeDepth() + 1); }
void RtTrap::exitScope() DAW_RT_TRAP_SCOPE_RT { setScopeDepth(scopeDepth() - 1); }
#pragma clang diagnostic pop

} // namespace daw

// MARK: C entry points for tests (Debug only)
//
// The Swift test target can't include engine headers (01-build-layout Interfaces: the module map
// exposes only EngineFacade.h) and SwiftPM test targets can't hold C++ files, so
// Tests/DAWEngineTests resolves these with dlsym. The probes are the deliberate violations the
// tests run inside a scope; they are written in C++ so the C++ allocation and lock paths are the
// ones exercised.

namespace {

using daw::RtScope;
using daw::RtTrap;
using daw::RtViolationKind;

// Keeps the optimizer from eliding allocation pairs.
void* volatile probeSink = nullptr;

enum Probe : int {
    probeNone,
    probeMalloc,
    probeCalloc,
    probeRealloc,
    probePosixMemalign,
    probeNewDelete,
    probeVectorGrowth,
    probeString,
    probeFunction,
    probePthreadMutex,
    probeStdMutex,
    probeUnfairLock,
    probeCount,
};

pthread_mutex_t probePthreadMutexLock = PTHREAD_MUTEX_INITIALIZER;
std::mutex probeStdMutexLock;
os_unfair_lock probeUnfairLockLock = OS_UNFAIR_LOCK_INIT;

bool runProbe(int probe) {
    switch (probe) {
    case probeNone: {
        float x = 1.0f;
        for (int i = 0; i < 64; ++i)
            x = x * 0.5f + 1.0f;
        probeSink = reinterpret_cast<void*>(static_cast<uintptr_t>(x));
        return true;
    }
    case probeMalloc: {
        void* p = malloc(64);
        probeSink = p;
        free(p);
        return true;
    }
    case probeCalloc: {
        void* p = calloc(16, 16);
        probeSink = p;
        free(p);
        return true;
    }
    case probeRealloc: {
        void* p = malloc(16);
        probeSink = p;
        p = realloc(p, 1 << 20);
        probeSink = p;
        free(p);
        return true;
    }
    case probePosixMemalign: {
        void* p = nullptr;
        if (posix_memalign(&p, 128, 4096) != 0)
            return false;
        probeSink = p;
        free(p);
        return true;
    }
    case probeNewDelete: {
        auto* p = new double[32];
        probeSink = p;
        delete[] p;
        return true;
    }
    case probeVectorGrowth: {
        std::vector<float> v;
        for (int i = 0; i < 100; ++i)
            v.push_back(static_cast<float>(i));
        probeSink = v.data();
        return true;
    }
    case probeString: {
        std::string s(100, 'x');
        s += " grows past the small-string buffer";
        probeSink = s.data();
        return true;
    }
    case probeFunction: {
        std::array<double, 16> capture{};
        std::function<double()> f = [capture] { return capture[0]; };
        probeSink = &f;
        return f() == 0.0;
    }
    case probePthreadMutex:
        pthread_mutex_lock(&probePthreadMutexLock);
        pthread_mutex_unlock(&probePthreadMutexLock);
        return true;
    case probeStdMutex:
        probeStdMutexLock.lock();
        probeStdMutexLock.unlock();
        return true;
    case probeUnfairLock:
        os_unfair_lock_lock(&probeUnfairLockLock);
        os_unfair_lock_unlock(&probeUnfairLockLock);
        return true;
    default: return false;
    }
}

} // namespace

extern "C" {

bool daw_rt_trap_install(void) { return RtTrap::install(); }
bool daw_rt_trap_installed(void) { return RtTrap::installed(); }
bool daw_rt_trap_in_realtime_context(void) { return RtTrap::inRealtimeContext(); }
int daw_rt_trap_probe_count(void) { return probeCount; }

// kind < 0: total.
uint64_t daw_rt_trap_violations(int kind) {
    if (kind < 0 || kind >= daw::kRtViolationKindCount)
        return RtTrap::violationCount();
    return RtTrap::violationCount(static_cast<RtViolationKind>(kind));
}

void daw_rt_trap_reset(void) { RtTrap::resetViolations(); }

// The first violation's kind, or -1. Writes its symbolized frames, newline-separated, into
// `buffer` (truncated, NUL-terminated) and returns the full length.
int daw_rt_trap_first_violation(char* buffer, size_t capacity, size_t* length) {
    const auto report = RtTrap::firstViolation();
    if (!report)
        return -1;
    std::string text;
    for (const auto& frame : report->frames)
        text += frame + "\n";
    if (capacity > 0) {
        const size_t n = std::min(text.size(), capacity - 1);
        memcpy(buffer, text.data(), n);
        buffer[n] = '\0';
    }
    if (length)
        *length = text.size();
    return static_cast<int>(report->kind);
}

// inRealtimeContext() sampled before, inside an outer scope, inside a nested scope, after the
// nested scope and after the outer scope, as bits 0..4.
int daw_rt_trap_nested_scope_flags(void) {
    int flags = RtTrap::inRealtimeContext() << 0;
    {
        RtScope outer;
        flags |= RtTrap::inRealtimeContext() << 1;
        {
            RtScope inner;
            flags |= RtTrap::inRealtimeContext() << 2;
        }
        flags |= RtTrap::inRealtimeContext() << 3;
    }
    return flags | RtTrap::inRealtimeContext() << 4;
}

// Runs a probe with the calling thread inside an RtScope (or not).
bool daw_rt_trap_run_probe(int probe, bool inScope) {
    if (!inScope)
        return runProbe(probe);
    RtScope scope;
    return runProbe(probe);
}

// Runs `body(context)` inside an RtScope, so tests can check what arbitrary code would count.
void daw_rt_trap_with_scope(void (*body)(void*), void* context) {
    RtScope scope;
    body(context);
}

// Runs a probe on a new thread that is inside an RtScope; the calling thread isn't, so creating
// and joining the thread must not count.
bool daw_rt_trap_run_probe_on_rt_thread(int probe) {
    bool ok = false;
    std::thread worker([&] {
        RtScope scope;
        ok = runProbe(probe);
    });
    worker.join();
    return ok;
}

// The calling thread enters an RtScope while another thread runs the probe outside one: the flag
// is per thread (ENG-030), so nothing counts. Synchronized with atomics only, so the scoped
// thread itself stays clean.
bool daw_rt_trap_run_probe_beside_rt_thread(int probe) {
    std::atomic<int> stage{0};
    bool ok = false;
    std::thread worker([&] {
        while (stage.load(std::memory_order_acquire) != 1)
            std::this_thread::yield();
        ok = runProbe(probe);
        stage.store(2, std::memory_order_release);
    });
    {
        RtScope scope;
        stage.store(1, std::memory_order_release);
        while (stage.load(std::memory_order_acquire) != 2) {
        }
    }
    worker.join();
    return ok;
}

} // extern "C"

#endif // DAW_RT_TRAP
