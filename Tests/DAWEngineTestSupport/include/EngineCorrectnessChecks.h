#pragma once
// T-111 checks (EngineCorrectnessChecks.cpp), run from
// Tests/DAWEngineTests/EngineCorrectnessTests.swift: the engine correctness fixes from the
// 2026-11-18 review (DW-311..321; DW-310 is in OfflineResetChecks.h). Every render asserts 0 RT
// violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// DW-318: MidiDelayLine reserves one release per held (channel, key), so unpaired note-ons on one
// key never make the line drop later note-ons; paired notes still never lose an off.
CheckResult midiDelayLineCountsHeldKeys();

// DW-311, MIX-024: a latency report drained by a build that fails isn't lost: the last good
// description is rebuilt with the new latency (and its LatencyEvent queued), and the rejection
// stays in the status.
CheckResult compilerKeepsLatencyReportsOfFailedBuild();

// DW-312, MIX-023: clipping, NaN and meter peaks in the discarded pre-roll don't reach telemetry;
// the same audio outside the pre-roll does.
CheckResult preRollFeedsNoTelemetry();

// DW-313, TIME-004: a block without a graph still applies transport commands (a locate waits for
// a map), never leaves block().tempo pointing at a map, and doesn't move the position.
CheckResult silentBlockWithoutGraph();
// DW-313: an oversize block applies commands and publishes the playhead but doesn't play; a locate
// applied in it still resets the timeline nodes at the next block that renders (TIME-008).
CheckResult silentOversizeBlock();

// DW-319, REC-003: a buffer-size change while recording ends the take at the change; the take
// after it is placed with the new latency (loopback on the fake device, ±1 sample).
CheckResult deviceBufferChangeEndsTakes();

// DW-320, IO-010: during an export, play and setRecording are ignored, locate and setLoop take
// effect after it, and stop cancels it and the queued exports (files removed).
CheckResult transportCallsDuringExport();

// DW-321: destroying a facade mid-export cancels the export: it returns quickly, no file is left.
CheckResult facadeDestroyCancelsExport();

} // namespace daw::testing
