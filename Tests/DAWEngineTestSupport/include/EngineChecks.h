#pragma once
// T-004 checks for the node API, RenderGraph, Engine::render, snapshot publish/reclaim, NodePool
// and denormal flushing (EngineChecks.cpp), run from Tests/DAWEngineTests/EngineTests.swift.
// They're C++ because they need threads, RtScope, move-only types and DAW_RT test nodes.
// Every check that renders asserts its render scope counted 0 RT violations (CONV §5.3, DW-019).

#include "Checks.h"

namespace daw::testing {

// ENG-001, ENG-002, ENG-013: prepare before publish, process/reset, release + destruction on
// daw.reclaim once no graph references the node (remove and replace).
CheckResult nodeLifecycle();
CheckResult nodeReplacedOnlyAfterGraphsReleaseIt();

// ENG-003
CheckResult nodeIOViews();
CheckResult midiEventWriter();

// ENG-004: random block sizes 0...4096 through a source → gain chain; oversize blocks are silent.
CheckResult randomBlockSizes();

// ENG-010, ENG-011: 10k publishes while another thread renders. Each block sees exactly one graph;
// every retired graph and node is freed (run under ASan/LSan for leaks and use-after-free).
CheckResult publishWhileRendering();

// ENG-012, ENG-011: the audio thread stalls mid-block; publishes and reclaim passes continue, but
// the graph the stalled block holds (and its nodes) stay alive until the block ends.
CheckResult stalledRenderKeepsGraphAlive();

// ENG-012: graphs replaced while nothing renders are freed without waiting for a block.
CheckResult idleEngineFreesReplacedGraphs();

// ENG-014: an object retired from process() is destroyed on daw.reclaim; the render scope
// counts no deallocation.
CheckResult rtRetireQueue();

// ENG-015, ENG-040: silence without a graph; extra target channels are silent.
CheckResult silenceWithoutGraph();

// ENG-041: sources summed into a node's input, topological order, master written to the target,
// epoch bumped once per block.
CheckResult renderOrderAndSumming();

// ENG-042: a decaying IIR never produces a subnormal inside render, reaches exactly 0, and the
// caller's FPCR is restored. Run outside render, the same IIR does produce subnormals.
CheckResult flushDenormalsInRender();

// ENG-061 / MIX-001 shape: RenderGraph::create validates indices and owns its pool.
CheckResult renderGraphValidation();

// DW-011: constructing an Engine installs the RT trap (Debug); false when it's compiled out.
bool engineInstallsRtTrap();

} // namespace daw::testing
