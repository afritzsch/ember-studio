#pragma once
// T-074 checks for automation (11). Run from Tests/DAWEngineTests/AutomationTests.swift. C++
// because they evaluate DAW_RT code inside an RtScope and drive the Engine; each asserts its
// scopes counted 0 RT violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// AUTO-004: linear, hold and exponential segments (both shape signs, ~0 shape is linear, shapes
// clamped), before the first and after the last point, clamping to 0…1; the player's cursor
// moves forward without searching and seeks back with a binary search; ParamMapping linear, log
// and db (0 → silence, 5/6 → unity for the +12 dB fader). Evaluation allocates nothing.
CheckResult automationCurves();

// AUTO-001/008: GraphBuilder rejects lanes with unsorted or repeated ticks, non-finite values or
// shapes, unknown curves and targets outside the table (and changes nothing); it compiles enabled
// lanes into players, mapped through the owning node's ParamInfo (strip gain db, pan linear,
// compressor threshold), and leaves out disabled (AUTO-005 off), empty, unowned and
// non-automatable (strip phase) lanes.
CheckResult automationCompile();

// AUTO-002/005 through the Engine: a strip-gain lane is written into the slot before the strip
// processes, at each block's start tick, so the output follows the lane within one block; a slot
// write between blocks (SetParam) is overridden in read mode; an off lane leaves the slot alone;
// while stopped the lane's value at the playhead is written once per position (a locate moves it,
// a write while stopped holds); a value that doesn't change isn't rewritten (generation still).
CheckResult automationDrivesSlots();

// AUTO-003: a loop wrap inside a block evaluates the lane at both segment starts; the strip and a
// gain (send) node ramp to the first value over segment 1 and jump to the second at the wrap
// frame, never ramping across it; the next block ramps on from there. A node without a jump
// entry (no lane) ramps as before.
CheckResult automationLoopWrapJump();

} // namespace daw::testing
