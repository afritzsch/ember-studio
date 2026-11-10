#pragma once
// T-054 checks for input monitoring (09 REC-020..022). Run from Tests/DAWEngineTests/
// MonitoringTests.swift. C++ because they render the engine with a hand-made device input in
// RtScopes and reach the fake driver behind the facade; every render must count 0 RT violations
// (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// REC-020: the truth table. off never monitors, on always does, auto does when armed and the
// transport is stopped or recording (not while it plays without recording); unarmed auto never
// does. Slot values 0/1/2 map to off/on/auto, anything else to off.
CheckResult monitoringTruthTable();

// REC-020, REC-021: an Engine renders a track whose clip plays a constant while a 4-channel device
// input carries other constants. Monitoring active: the track outputs exactly input pair 1
// (channels 2, 3), never the clip (no leak, also while playing over the clip with `on`), and the
// input pair 0 doesn't reach it. Inactive: exactly the clip. Switching crossfades over
// kMonitorFadeFrames, monotonically. auto follows play/stop/record per block. An offline render
// (no device input) plays the clip whatever the mode. 0 RT violations.
CheckResult engineMonitorsInputInPlaceOfClip();

// REC-021, MIX-023: with 300 samples of PDC after the monitored track, starting playback with
// `on` pre-rolls silence for the track, so not one sample of its clip reaches the master.
CheckResult monitoringPreRollLeaksNoClip();

// REC-022: a description's monitors are validated (known audioClipPlayer, allocated mode slot,
// pair < 16, no duplicates). The mode is a slot: writing it changes what is heard with no new
// graph (same RenderGraph serial); arming is a new description.
CheckResult monitorsAreValidatedAndModeIsASlot();

// REC-020..022 end to end: a realtime facade on a fake device whose output loops back to its input
// (TEST-005). A metronome click goes out and comes back as input; a monitored track (gain 0.25 to
// the master) makes it audible again one loopback later when monitoring is on, and not when it is
// off, auto unarmed, or auto armed while playing; auto armed while recording hears it. The mode
// changes are setParam calls (published graph version unchanged); setMonitorInput runs the input
// without an arm; telemetry's monitoringLatency = input + output + graph latency. 0 RT violations.
CheckResult facadeMonitorsThroughLoopback();

} // namespace daw::testing
