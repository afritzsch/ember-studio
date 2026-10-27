// RT trap test support (ENG-030..033, DW-019). See RtTrapTestSupport.h.

#include "RtTrapTestSupport.h"

#include <array>
#include <atomic>
#include <cstdlib>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <os/lock.h>
#include <pthread.h>

namespace daw::testing {

namespace {

// Keeps the optimizer from eliding allocation pairs.
void* volatile probeSink = nullptr;

pthread_mutex_t probePthreadMutexLock = PTHREAD_MUTEX_INITIALIZER;
std::mutex probeStdMutexLock;
os_unfair_lock probeUnfairLockLock = OS_UNFAIR_LOCK_INIT;

ScopeCounts counted(const RtScope& scope, bool ok) {
    return {ok, scope.violations(RtViolationKind::allocation),
            scope.violations(RtViolationKind::deallocation),
            scope.violations(RtViolationKind::lock)};
}

} // namespace

bool runProbe(RtProbe probe) {
    switch (probe) {
    case RtProbe::clean: {
        float x = 1.0f;
        for (int i = 0; i < 64; ++i)
            x = x * 0.5f + 1.0f;
        probeSink = reinterpret_cast<void*>(static_cast<uintptr_t>(x));
        return true;
    }
    case RtProbe::malloc: {
        void* p = ::malloc(64);
        probeSink = p;
        free(p);
        return true;
    }
    case RtProbe::calloc: {
        void* p = ::calloc(16, 16);
        probeSink = p;
        free(p);
        return true;
    }
    case RtProbe::realloc: {
        void* p = ::malloc(16);
        probeSink = p;
        p = ::realloc(p, 1 << 20);
        probeSink = p;
        free(p);
        return true;
    }
    case RtProbe::posixMemalign: {
        void* p = nullptr;
        if (posix_memalign(&p, 128, 4096) != 0)
            return false;
        probeSink = p;
        free(p);
        return true;
    }
    case RtProbe::newDelete: {
        auto* p = new double[32];
        probeSink = p;
        delete[] p;
        return true;
    }
    case RtProbe::vectorGrowth: {
        std::vector<float> v;
        for (int i = 0; i < 100; ++i)
            v.push_back(static_cast<float>(i));
        probeSink = v.data();
        return true;
    }
    case RtProbe::string: {
        std::string s(100, 'x');
        s += " grows past the small-string buffer";
        probeSink = s.data();
        return true;
    }
    case RtProbe::function: {
        std::array<double, 16> capture{};
        std::function<double()> f = [capture] { return capture[0]; };
        probeSink = &f;
        return f() == 0.0;
    }
    case RtProbe::pthreadMutex:
        pthread_mutex_lock(&probePthreadMutexLock);
        pthread_mutex_unlock(&probePthreadMutexLock);
        return true;
    case RtProbe::stdMutex:
        probeStdMutexLock.lock();
        probeStdMutexLock.unlock();
        return true;
    case RtProbe::unfairLock:
        os_unfair_lock_lock(&probeUnfairLockLock);
        os_unfair_lock_unlock(&probeUnfairLockLock);
        return true;
    }
    return false;
}

ScopeCounts runProbeInScope(RtProbe probe) {
    RtScope scope;
    const bool ok = runProbe(probe);
    return counted(scope, ok);
}

ScopeCounts runProbeOnRtThread(RtProbe probe) {
    ScopeCounts result;
    std::thread worker([&] { result = runProbeInScope(probe); });
    worker.join();
    return result;
}

ScopeCounts runProbeBesideRtThread(RtProbe probe) {
    // Synchronized with atomics only, so the scoped thread itself stays clean.
    std::atomic<int> stage{0};
    bool ok = false;
    std::thread worker([&] {
        while (stage.load(std::memory_order_acquire) != 1)
            std::this_thread::yield();
        ok = runProbe(probe);
        stage.store(2, std::memory_order_release);
    });
    ScopeCounts result;
    {
        RtScope scope;
        stage.store(1, std::memory_order_release);
        while (stage.load(std::memory_order_acquire) != 2) {
        }
        result = counted(scope, true);
    }
    worker.join();
    result.ok = ok;
    return result;
}

ScopeCounts runInRtScope(void (*body)(void*), void* context) {
    RtScope scope;
    body(context);
    return counted(scope, true);
}

int32_t nestedScopeFlags() {
    int32_t flags = RtTrap::inRealtimeContext() << 0;
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

ConcurrentScopes cleanScopeBesideViolatingScope(RtProbe probe, int32_t repeats) {
    // Both scopes are open at once: the clean thread enters first and stays inside until the
    // violating thread is done. Only atomics in between, so the clean thread stays clean.
    std::atomic<bool> cleanInScope{false};
    std::atomic<bool> violatingDone{false};
    ConcurrentScopes result;
    std::thread clean([&] {
        RtScope scope;
        cleanInScope.store(true, std::memory_order_release);
        float x = 1.0f;
        while (!violatingDone.load(std::memory_order_acquire))
            x = x * 0.5f + 1.0f;
        probeSink = reinterpret_cast<void*>(static_cast<uintptr_t>(x));
        result.clean = counted(scope, true);
    });
    std::thread violating([&] {
        while (!cleanInScope.load(std::memory_order_acquire))
            std::this_thread::yield();
        RtScope scope;
        bool ok = true;
        for (int32_t i = 0; i < repeats; ++i)
            ok = runProbe(probe) && ok;
        result.violating = counted(scope, ok);
        violatingDone.store(true, std::memory_order_release);
    });
    violating.join();
    clean.join();
    return result;
}

bool rtTrapCompiledIn() { return DAW_RT_TRAP != 0; }

} // namespace daw::testing
