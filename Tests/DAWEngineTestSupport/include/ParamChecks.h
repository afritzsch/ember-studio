#pragma once
// T-005 checks for ParamSlotTable and ParamSmoother (ParamChecks.cpp), run from
// Tests/DAWEngineTests/ParamTests.swift. The table is C++ because it's non-movable (it holds a
// mutex and is shared by address), and the RT checks need RtScope and DAW_RT bodies. The ramp
// math is tested from Swift directly.

#include <cstdint>

#include "Checks.h"

namespace daw::testing {

// ENG-020
CheckResult paramTableDefaultCapacity();
CheckResult paramTableAllocateFree();
CheckResult paramTableContiguousRanges();
CheckResult paramTableErrors();
CheckResult paramTableConcurrentAllocate();

// ENG-021
CheckResult paramSlotReadWrite();
CheckResult paramSlotCrossThread(); // also checks the reader thread's RtScope count

// ENG-022
CheckResult paramSmootherFollowsSlot();

// ENG-023
CheckResult paramWritesLeaveConfigUntouched();

// CONV §5.3: every RT entry point of ParamSlotTable and ParamSmoother inside an RtScope; returns
// that scope's violations. Always 0 when the RT trap is compiled out (Release).
uint64_t paramRtViolations();

} // namespace daw::testing
