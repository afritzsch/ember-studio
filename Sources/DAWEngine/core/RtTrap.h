#pragma once
// Debug RT safety trap (02-engine-core ENG-030..033, enforces CONV-RT-01/02).
//
// While a thread is inside an RtScope, heap allocations/deallocations and lock acquisitions on
// that thread are counted as violations. Engine::render() opens the scope (T-004); telemetry
// copies violationCount() into rtViolations (T-006). In Release (DAW_RT_TRAP=0) everything here
// is an inline no-op and RtTrap.cpp compiles to nothing (BUILD-005).
//
// How calls are caught (macOS has no supported interposition for an already running process):
//   - allocations: libmalloc's malloc_logger hook. It sees every malloc-family call from every
//     image (our code, libc++, the Swift runtime, system frameworks), including malloc, calloc,
//     realloc, posix_memalign, free, operator new/delete and malloc_type_*.
//   - locks: the symbol pointers (__got) of every image outside the dyld shared cache are
//     rebound to counting forwarders. That covers our own code and anything else we link, but
//     not locks taken inside system libraries.
// dyld __interpose would be simpler but only applies to dylibs loaded at launch: it ignores the
// main executable and the dlopen'd test bundles `swift test` uses.

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#ifndef DAW_RT_TRAP
#define DAW_RT_TRAP 0
#endif

// RtScope is entered from Engine::render(), which is DAW_RT (CONV-RT-06), so its constructor and
// destructor must be callable from nonblocking code. TODO(T-002 merge): spell this DAW_RT.
#if defined(__has_cpp_attribute) && __has_cpp_attribute(clang::nonblocking)
#define DAW_RT_TRAP_SCOPE_RT noexcept [[clang::nonblocking]]
#else
#define DAW_RT_TRAP_SCOPE_RT noexcept
#endif

namespace daw {

enum class RtViolationKind : uint8_t {
    allocation,   // malloc, calloc, realloc, posix_memalign, operator new, …
    deallocation, // free, operator delete
    lock,         // pthread_mutex_lock, os_unfair_lock_lock, std::mutex::lock, …
};
inline constexpr int kRtViolationKindCount = 3;

// The first violation since the last reset, symbolized off the audio thread (ENG-032).
struct RtViolationReport {
    RtViolationKind kind;
    std::vector<std::string> frames; // innermost first; starts inside the trap's own hook
};

class RtTrap {
public:
    // Non-RT. Installs the hooks (idempotent; images loaded later are patched as they load) and
    // re-reads DAW_RT_TRAP_ABORT. Returns whether the allocation hook is live. The Engine calls
    // this on construction; call it before the first RtScope.
    static bool install();
    static bool installed();

    // ENG-030: true while the calling thread is inside an RtScope.
    static bool inRealtimeContext() noexcept;

    // ENG-032: relaxed counters, readable from any thread without locks.
    static uint64_t violationCount() noexcept;
    static uint64_t violationCount(RtViolationKind) noexcept;

    // Non-RT. std::nullopt until a violation happened (or when the trap is compiled out).
    static std::optional<RtViolationReport> firstViolation();

    // Non-RT, for tests: zero the counters and re-arm first-violation capture. Call it only
    // while no thread is inside an RtScope.
    static void resetViolations() noexcept;

private:
    friend class RtScope;
    static void enterScope() DAW_RT_TRAP_SCOPE_RT;
    static void exitScope() DAW_RT_TRAP_SCOPE_RT;
};

// ENG-030/033: marks the engine's own render scope. Only work done inside it is checked, so
// CoreAudio's allocations during device start (outside render) aren't violations. Scopes nest.
class RtScope {
public:
#if DAW_RT_TRAP
    RtScope() DAW_RT_TRAP_SCOPE_RT { RtTrap::enterScope(); }
    ~RtScope() DAW_RT_TRAP_SCOPE_RT { RtTrap::exitScope(); }
#else
    RtScope() DAW_RT_TRAP_SCOPE_RT {}
    ~RtScope() DAW_RT_TRAP_SCOPE_RT {}
#endif
    RtScope(const RtScope&) = delete;
    RtScope& operator=(const RtScope&) = delete;
};

#if !DAW_RT_TRAP
// BUILD-005: Release compiles the trap out.
inline bool RtTrap::install() { return false; }
inline bool RtTrap::installed() { return false; }
inline bool RtTrap::inRealtimeContext() noexcept { return false; }
inline uint64_t RtTrap::violationCount() noexcept { return 0; }
inline uint64_t RtTrap::violationCount(RtViolationKind) noexcept { return 0; }
inline std::optional<RtViolationReport> RtTrap::firstViolation() { return std::nullopt; }
inline void RtTrap::resetViolations() noexcept {}
#endif

} // namespace daw
