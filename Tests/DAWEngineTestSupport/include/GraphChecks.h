#pragma once
// T-012 checks for GraphDescription → GraphBuilder → RenderGraph (05 MIX-001..004, MIX-009,
// DW-030, DW-036, TIME-003/008 hooks), run from Tests/DAWEngineTests/GraphTests.swift. They're
// C++ because they need the NodePool/Engine (non-movable), DAW_RT test nodes, threads and RtScope.
// Every check that renders asserts its render scope counted 0 RT violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// MIX-001: a description builds into a graph that renders; nodes are created through the
// registry and prepared at the builder's format before the graph exists (ENG-013).
CheckResult graphBuildsAndRenders();

// MIX-001: GraphCompiler builds on daw.compile and publishes; failures keep the current graph.
CheckResult graphCompilesOnCompileThread();

// MIX-001: malformed descriptions are rejected before the NodePool is touched.
CheckResult graphRejectsMalformed();

// MIX-002: a cycle fails with the NodeIDs on it (not those merely up- or downstream); sidechain
// and MIDI edges count. Random DAGs sort with every edge pointing forward.
CheckResult graphCycleRejected();
CheckResult topoSortRandomDAGs();

// MIX-003: a 100-track project (several shapes) uses <= max fan-in + depth buffers.
CheckResult bufferLivenessHundredTracks();

// MIX-003, MIX-004: random mixer projects (≤ 100 tracks, nested buses, sends, sidechains) stay
// within that bound and render the sums a direct evaluation predicts.
CheckResult bufferLivenessRandomMixers();

// MIX-003, MIX-004: arbitrary random DAGs render exactly the predicted sums, so no buffer is
// reused while something still reads it. (No count bound: dense DAGs with wide fan-out keep many
// summing buffers open, which mixer projects don't.)
CheckResult bufferLivenessRandomGraphs();

// MIX-004: edges into one port are summed; sidechain edges feed the sidechain port; toPort 0.
CheckResult summingAndPorts();

// MIX-009: master is last; its hard-clip limiter is off by default, clips and counts when on.
CheckResult masterNodeAndLimiter();

// DW-036: a configVersion (or param range) change puts a new prepared instance in the pool,
// unchanged nodes are reused as is, and dropped nodes leave the pool; old instances live until
// the graphs using them are reclaimed.
CheckResult nodeInstancesAcrossBuilds();

// DW-030: param ranges outside the table or not allocated are rejected at build time.
CheckResult paramRangesValidated();

// TIME-003: the graph owns the tempo map, built at the builder's rate. TIME-008: clip-player
// steps are flagged resetOnLocate and resetTimelineNodes() resets exactly those.
CheckResult tempoMapAndLocateReset();

// RenderGraph::create checks for the push (fed) ports and feeds T-012 added.
CheckResult renderGraphFeedValidation();

} // namespace daw::testing
