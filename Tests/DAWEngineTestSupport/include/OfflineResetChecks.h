#pragma once
// T-089 checks for DW-063 (OfflineResetChecks.cpp), run from
// Tests/DAWEngineTests/OfflineResetTests.swift: an offline render resets every node of the graph
// before its first block, so renders on one engine are bit-identical whatever played before,
// while live playback keeps TIME-008 (a locate resets timeline nodes only; effect tails survive).
// Every render asserts 0 RT violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// DW-063, IO-011: a burst through every built-in with state (EQ, compressor, delay, reverb,
// strip). Exports on a fresh engine, after live playback that leaves the delay and reverb
// ringing, and after an export cut off mid-tail, are the same bits; a live locate meanwhile still
// keeps the tails (TIME-008).
CheckResult offlineResetsEveryNode();

// DW-063: each built-in's reset() returns it to its prepared state: after reset() the same input
// gives the same bits as a freshly prepared node, whatever it processed before.
CheckResult builtinResetMatchesFreshNode();

} // namespace daw::testing
