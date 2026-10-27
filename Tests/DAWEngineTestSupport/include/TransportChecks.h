#pragma once
// T-008 checks for the Transport, TransportBlock segments, the timeline-node helpers and the
// playhead (TransportChecks.cpp), run from Tests/DAWEngineTests/TransportTests.swift. They're C++
// because they need threads, RtScope and DAW_RT test nodes. Every check that advances the
// transport or renders asserts that its own RtScope counted 0 violations (CONV §5.3, DW-019).

#include "Checks.h"

namespace daw::testing {

// TIME-004: commands are queued, applied in order at the start of the next block, and validated;
// a full queue refuses commands; stop keeps the position.
CheckResult transportCommandsApplyAtBlockStart();

// TIME-004: several producer threads send commands while the audio thread advances; every
// command is applied exactly once.
CheckResult transportCommandsFromManyThreads();

// TIME-005: without a loop, one segment per block, contiguous in samples and ticks; stopped and
// 0-frame blocks have no segment but still carry the position.
CheckResult transportLinearSegments();

// TIME-005: a wrap inside the block gives two segments with the right ranges and flags.
CheckResult transportLoopWrapMidBlock();

// TIME-005: a block that ends exactly on the loop end has one segment; the next block's single
// segment starts at the loop start, marked afterWrap.
CheckResult transportLoopWrapAtBlockBoundary();

// TIME-005, ENG-004: random block sizes 0...4096 over several loops and tempo maps, checked frame
// by frame against an independent model of the timeline.
CheckResult transportRandomBlockSizes();

// TIME-005: a playhead past the loop end plays on; an empty loop is off; a loop shorter than the
// block plays once and leaves a gap.
CheckResult transportLoopEdgeCases();

// TIME-006: a test-only timeline node built on TransportSegments.h, rendered through the Engine
// with random block sizes and a loop, puts each event exactly where the timeline says.
CheckResult timelineNodeHonorsSegments();

// TIME-006: SegmentContinuity reports wraps, locates and the first segment as jumps.
CheckResult segmentContinuity();

// TIME-007: a block spanning a tempo change runs at the tempo at its start, but its tick range
// and event frames come from the tempo map.
CheckResult tempoChangeInsideBlock();

// TIME-003: each block uses the tempo map it is given, never one cached from an earlier block;
// loop points and locates resolve through it. Through the Engine, nodes see the current graph's
// own map, and a newly published graph's map from the next block on.
CheckResult tempoMapPerBlock();
CheckResult engineHandsNodesTheTransportBlock();

// TIME-008: locatedWhilePlaying() is set for a locate applied while playing, only for that
// block. Through the Engine, the graph's resetOnLocate steps are reset once before the block at
// the new position; other steps, loop wraps and locates while stopped reset nothing.
CheckResult locateWhilePlayingFlagsReset();

// TIME-009: the playhead is compensated for output latency, clamps to where playback started,
// unwraps into the loop after a wrap, and isn't compensated while stopped.
CheckResult playheadLatencyCompensation();

// TIME-009: a reader thread never sees a torn playhead while the audio thread publishes.
CheckResult playheadIsConsistentAcrossThreads();

} // namespace daw::testing
