#pragma once
// Test support for the RT trap (02-engine-core ENG-030..033, DW-019): deliberate violations
// ("probes") and helpers that run code inside an RtScope and report what that scope counted.
// Swift can't hold an RtScope (it's neither copyable nor movable, and Swift doesn't promise when
// a value is destroyed), so every scope is opened and closed here, in C++.
//
// Tests/DAWEngineTests/RtTrapTests.swift is the only suite that provokes violations on purpose.

#include <cstdint>

#include "core/RtTrap.h"

namespace daw::testing {

// The deliberate violations. Written in C++ so the C++ allocation and lock paths are the ones
// exercised.
enum class RtProbe : int32_t {
    clean, // arithmetic only
    malloc,
    calloc,
    realloc,
    posixMemalign,
    newDelete,
    vectorGrowth,
    string,
    function,
    pthreadMutex,
    stdMutex,
    unfairLock,
};
inline constexpr int32_t kRtProbeCount = 12;

// Runs a probe on the calling thread, outside any RtScope. Returns whether it did its work.
bool runProbe(RtProbe probe);

// What one RtScope counted (RtScope::violations), and whether the code inside it did its work.
struct ScopeCounts {
    bool ok = false;
    uint64_t allocations = 0;
    uint64_t deallocations = 0;
    uint64_t locks = 0;

    uint64_t total() const { return allocations + deallocations + locks; }
};

// Runs a probe on the calling thread inside an RtScope.
ScopeCounts runProbeInScope(RtProbe probe);
// Runs a probe on a new thread inside its own RtScope; the calling thread isn't in one, so
// creating and joining the thread must not count.
ScopeCounts runProbeOnRtThread(RtProbe probe);
// The calling thread enters an RtScope while another thread runs the probe outside one. Returns
// the calling thread's scope: the flag is per thread (ENG-030), so it must count nothing.
ScopeCounts runProbeBesideRtThread(RtProbe probe);
// Runs body(context) on the calling thread inside an RtScope, so tests can check what arbitrary
// code would count.
ScopeCounts runInRtScope(void (*body)(void*), void* context);

// inRealtimeContext() sampled before, inside an outer scope, inside a nested scope, after the
// nested scope and after the outer scope, as bits 0..4.
int32_t nestedScopeFlags();

// DW-019: two threads in RtScopes at the same time, one doing clean work and one running
// `probe` `repeats` times. Each scope must see only its own thread's violations.
struct ConcurrentScopes {
    ScopeCounts clean;
    ScopeCounts violating;
};
ConcurrentScopes cleanScopeBesideViolatingScope(RtProbe probe, int32_t repeats);

// BUILD-005: whether the trap is compiled in, as seen by the out-of-line test support (built with
// the engine's flags) and by whoever compiles this header (for Swift, the clang importer with
// DAWEngineTests' -Xcc flags). They must agree, or the Swift side sees no-op inline RtTrap code.
bool rtTrapCompiledIn();
inline bool rtTrapCompiledInHeader() { return DAW_RT_TRAP != 0; }

} // namespace daw::testing
