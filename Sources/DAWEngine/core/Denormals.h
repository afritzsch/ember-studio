#pragma once
// ENG-042: denormals are flushed to zero while the engine renders. Decaying feedback paths
// (IIR filters, reverb tails) otherwise end up in subnormal floats, which are much slower on
// many CPUs and are inaudible anyway.
//
// arm64 only (D-23, BUILD-008): FPCR.FZ (bit 24) flushes subnormal inputs and results of scalar
// and NEON float arithmetic to zero.

#include <arm_acle.h>

#include <cstdint>

#include "core/Realtime.h"

#if !defined(__aarch64__)
#error "macDAW targets arm64 only (BUILD-008)"
#endif

namespace daw {

// Sets FZ for the current thread for its lifetime and restores the previous FPCR afterwards, so
// a thread that calls Engine::render offline (OfflineDriver, tests) gets its own float mode back.
class ScopedFlushDenormals {
public:
    static constexpr uint64_t kFZ = uint64_t{1} << 24;

    ScopedFlushDenormals() DAW_RT : saved_(__arm_rsr64("fpcr")) {
        if (!(saved_ & kFZ)) __arm_wsr64("fpcr", saved_ | kFZ);
    }
    ~ScopedFlushDenormals() DAW_RT {
        if (!(saved_ & kFZ)) __arm_wsr64("fpcr", saved_);
    }
    ScopedFlushDenormals(const ScopedFlushDenormals&) = delete;
    ScopedFlushDenormals& operator=(const ScopedFlushDenormals&) = delete;

    // Whether FZ is set on the calling thread.
    static bool active() DAW_RT { return (__arm_rsr64("fpcr") & kFZ) != 0; }

private:
    uint64_t saved_;
};

} // namespace daw
