#pragma once
// T-024 checks for the metronome (03 TIME-010, 06 DSP-011): NodeKind::metronome registered by
// registerBuiltinNodes, driven through GraphBuilder and the Engine. Run from
// Tests/DAWEngineTests/MetronomeTests.swift. C++ because they call DAW_RT process() inside an
// RtScope and drive the Engine; each asserts its scopes counted 0 RT violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// TIME-010, DSP-011: the click shapes, the ParamInfo table, defaults for slots beyond numParams,
// clamping and NaN, a mono output, 0-frame blocks; reset() (TIME-008) fades a click in progress
// over 64 frames.
CheckResult metronomeNodeBasics();

// TIME-010, TIME-006/007: over a tempo map with three tempo changes and 3/4 → 4/4 (cutting a 3/4
// bar short) → 6/8, in random block sizes 0 … 1024, every beat clicks on exactly
// tickToSample(beat) (equal to an independent beat-grid oracle on every sample), downbeats
// accented. Through the Engine.
CheckResult metronomeClicksOnTempoMap();

// TIME-005/006: loop wraps mid-block, in random and fixed block sizes: each pass clicks from its
// own ticks, a click at the loop end rings out across the wrap, a loop starting on a beat clicks
// on the wrap frame.
CheckResult metronomeLoopWrap();

// TIME-010: the on switch and levels are latched when a click starts: off never cuts a click,
// on starts at the next beat (no partial click), a level change applies from the next click.
CheckResult metronomeSwitchAndLevels();

// TIME-008, DW-085: a locate while playing cuts the click in progress with a 64-frame fade and
// clicks from the new position (a locate onto a beat clicks on the locate frame); stop fades
// out and stays silent.
CheckResult metronomeLocateAndStop();

// MIX-023, DW-085: a timeline node, scheduled graph-latency ahead: behind a 2048-sample latent
// node on the master path, beat 1 still clicks on frame 0 and every click is on its sample.
CheckResult metronomeWithGraphLatency();

} // namespace daw::testing
