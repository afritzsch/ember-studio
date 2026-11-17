#pragma once
// T-080 checks for loop recording (09 REC-030, REC-034; DW-243). Run from Tests/DAWEngineTests/
// RecordingTests.swift. C++ because they lay blocks out in passes like Engine::render, call the
// recorder's DAW_RT captureBlock in RtScopes and reach the fake driver behind the facade; every
// capture counts 0 RT violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// REC-030, DW-243: blocks laid out in passes exactly as Engine::render does (beginBlock, then
// layOutPass until the block is covered, offsetLastPass), with device input whose samples say
// which transport position they were captured at. For loops longer and much shorter than a block
// (several passes per block, entering the loop from before it, blocks ending right on the loop
// end, recording starting mid-loop, random block sizes), the take's file holds every captured
// frame in order (no pass of a block left out) and passStarts is exactly [0] + each wrap + D
// below the file's length, with the loop's samples; 0 RT violations.
CheckResult recorderLogsLoopPasses();

// REC-030 end to end: a realtime facade on a loopback fake device (metronome out → input) records
// three loop passes (the last partial). recordingFinalized carries passes = 3, the loop's samples
// and passStarts [0, wrap₁ + D, wrap₂ + D], and the click of every pass's loop start is at its
// pass start in the file (±1). A loop shorter than the device buffer (DW-243) reports a pass every
// loop length, none missing; 0 RT violations.
CheckResult facadeReportsLoopPasses();

// REC-034: a MIDI loop recording keeps notes in transport position (one take, merged) and
// reports each note's pass, the number of passes and the loop; setRecordOptions(midiLoopTakes)
// is stamped on the take and read back by transport().
CheckResult midiTakeReportsPasses();

} // namespace daw::testing
