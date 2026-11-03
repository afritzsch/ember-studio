#pragma once
// T-009 checks for OfflineDriver (IO-010..013), run from Tests/DAWEngineTests/OfflineDriverTests.swift.
// C++ because they build RenderGraphs from DAW_RT test nodes and own Engines. Every clean render
// asserts that the driver's own RT trap count is 0 (CONV §5.3, DW-019).

#include "Checks.h"

#include <cstdint>
#include <string>

namespace daw::testing {

// IO-010: [from, to) becomes tickToSample(to) − tickToSample(from) frames, rendered in blocks of
// exactly the spec's size (the last one cut), with progress after each block; the file and the
// sink hold the same samples the graph produced.
CheckResult offlineRendersRange();

// IO-010: the range follows the tempo map (tempo changes, 44.1 kHz) and the file takes its rate.
CheckResult offlineTempoMapRange();

// IO-010, TIME-004, TIME-008: the export plays through the engine's transport from `from`,
// straight through an enabled loop, after resetting the timeline nodes once; afterwards the
// transport is stopped with its position, loop and output latency restored.
CheckResult offlineFollowsTransport();

// T-036, TIME-005: with ExportSpec::followLoop the export keeps the transport's loop: the range's
// length of playback from `from`, wrapping at the loop end mid-block like live playback, with the
// per-block playhead check following the wrap (also for a loop shorter than a block, which leaves
// a gap). With the loop off it is bit-identical to the default render.
CheckResult offlineFollowsLoop();

// IO-010: the render fails (and removes the file) when the transport doesn't follow
// ExportSpec.tempo: another rate or tempo than the graph's map, blocks above the graph's
// maxBlock, or no graph.
CheckResult offlineTransportMismatch();

// IO-010: invalid ranges, block sizes, channel counts, tail settings and paths fail before any
// block is rendered; an empty range writes an empty file.
CheckResult offlineErrors();

// IO-011: two fresh engines rendering the same graph (sine + seeded noise + decay) produce the
// same bytes, both in the file (16-bit with TPDF dither, and 32-bit float) and in the sink.
CheckResult offlineDeterministic();

// IO-011, TIME-008: two renders on one engine, with playback in between, are bit-identical
// because the pre-render locate resets the timeline nodes; a node not flagged as one differs.
CheckResult offlineRepeatableOnOneEngine();

// IO-012: a decaying source ends the tail exactly quietSeconds after it drops below the
// threshold (defaults and a custom threshold/length).
CheckResult offlineTailQuiet();

// IO-012: quiet frames only count after the range end, and a loud frame restarts the count.
CheckResult offlineTailQuietRunResets();

// IO-012: an endless tone stops at the maximum tail length (default 10 s and a custom one); a
// disabled tail stops at the range end.
CheckResult offlineTailMaxLength();

// IO-013: offline, nodes run inside the RT trap's scope (Debug), and a clean graph counts 0.
CheckResult offlineRunsInRtScope();

// IO-010 acceptance: 60 s of a simple project (8 sines → mix → 24-bit dithered WAV, 512-frame
// blocks) renders in under 10 s. Reports the measurement.
struct OfflinePerformance {
    bool ok = false;
    std::string error;
    double audioSeconds = 0;
    double renderSeconds = 0;
    uint64_t rtViolations = 0;
};
OfflinePerformance offlinePerformance60s();

// IO-013, deliberate violations (RtTrapTests only): a node that allocates in process() is
// counted by the offline driver's own count; a clean graph rendered right after counts 0.
struct OfflineTrapCounts {
    bool ok = false;
    uint64_t blocks = 0;
    uint64_t violations = 0;       // allocating graph
    uint64_t cleanViolations = 0;  // clean graph, same engine, right after
};
OfflineTrapCounts offlineCountsAllocatingNode();

} // namespace daw::testing
