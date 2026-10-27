#pragma once
// T-002 checks for Result, DAW_RT, SpscQueue and AudioBufferPool (CoreUtilsChecks.cpp), run from
// Tests/DAWEngineTests/CoreUtilsTests.swift. They're C++ because the types are templates or
// move-only, and because DAW_RT bodies are only checked by the C++ compiler.

#include "Checks.h"

namespace daw::testing {

// CONV §4
CheckResult resultValueAndError();
CheckResult resultVoid();
CheckResult resultMoveOnlyAndConverting();

// CONV-RT-06
CheckResult rtAnnotationNonblocking();

// ENG-060
CheckResult spscFifoFullEmpty();
CheckResult spscWraparound();
CheckResult spscBulk();
CheckResult spscTwoThreads();

// ENG-061
CheckResult poolLayout();
CheckResult poolMixedChannelCounts();
CheckResult poolErrorsAndEmpty();
CheckResult poolMove();

} // namespace daw::testing
