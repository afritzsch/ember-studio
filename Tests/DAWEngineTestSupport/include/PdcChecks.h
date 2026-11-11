#pragma once
// T-021 checks for plugin delay compensation (05 MIX-020..024), run from
// Tests/DAWEngineTests/PdcTests.swift. They're C++ because they need the NodePool/Engine
// (non-movable), DAW_RT test nodes (a FakeLatencyNode, TEST-004), daw.compile and RtScope.
// Every check that renders asserts its render scopes counted 0 RT violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// MIX-020: path latency = max over inputs + own latency; the graph latency is the master's; the
// per-node table and graphLatency reach telemetry; MIDI edges count; oversize latency rejected.
CheckResult pdcPathLatency();

// MIX-021: delay lines align every merge (summing input and sidechain input). Null test: a dry
// sine against its negative through a 1000-sample latency node cancels exactly, for random
// block sizes. Random mixers with latent inserts on tracks and buses, sends: one impulse per
// path lands on the same frame, at the graph latency.
CheckResult pdcMergeAlignment();

// MIX-022: a rebuild during playback carries delay lines over by edge ID, so the output is
// bit-identical to rendering without the rebuild (synchronously, and on a render thread while
// GraphCompiler rebuilds); a new edge ID starts from silence (the control).
CheckResult pdcDelayLinesCarryOver();

// MIX-023: timeline nodes run graph-latency samples ahead with a pre-roll at every run start,
// so output frame f is timeline position f from the first frame: play from 0, locate while
// playing, a loop shorter than the latency, and one shorter than the block (DW-125).
CheckResult pdcSourcePreRoll();

// MIX-023: a real AudioClipPlayer behind a latent master insert: an offline export from tick 0
// has the click on beat 1 at sample 0 and the one on beat 2 at sample 24000.
CheckResult pdcClickOnBeatOne();

// MIX-024: a node reporting a latency change makes GraphCompiler rebuild on daw.compile (same
// instances), re-plan PDC, publish, and queue a LatencyEvent; telemetry follows. Reports with
// no compiler (or after it is gone) are dropped safely.
CheckResult pdcLatencyChangeRebuilds();

} // namespace daw::testing
