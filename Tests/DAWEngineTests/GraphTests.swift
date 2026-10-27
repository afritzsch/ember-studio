import DAWEngineTestSupport
import Testing

// T-012: GraphDescription → GraphBuilder → RenderGraph (05 MIX-001..004, MIX-009). The checks are
// C++ (Tests/DAWEngineTestSupport/GraphChecks.cpp) because they need the NodePool and Engine,
// DAW_RT test nodes, daw.compile and RtScope. Every check that renders also asserts that its
// render scope counted 0 RT violations (CONV §5.3).

@Suite("GraphBuilder (MIX-001)")
struct GraphBuilderTests {
    @Test("MIX-001: a description builds into a graph that renders; nodes prepared before publish")
    func buildsAndRenders() { expectPasses(daw.testing.graphBuildsAndRenders()) }

    @Test("MIX-001: GraphCompiler builds on daw.compile, publishes, coalesces, reports failures")
    func compileThread() { expectPasses(daw.testing.graphCompilesOnCompileThread()) }

    @Test("MIX-001, MIX-004, MIX-009: malformed descriptions are rejected before the pool is touched")
    func rejectsMalformed() { expectPasses(daw.testing.graphRejectsMalformed()) }

    @Test("DW-036: configVersion bump → new prepared instance; unchanged reused; dropped nodes leave the pool")
    func nodeInstances() { expectPasses(daw.testing.nodeInstancesAcrossBuilds()) }

    @Test("DW-030: param ranges outside the table or unallocated are rejected at build time")
    func paramRanges() { expectPasses(daw.testing.paramRangesValidated()) }

    @Test("TIME-003, TIME-008: the graph owns its tempo map; clip players are flagged resetOnLocate")
    func tempoAndLocateReset() { expectPasses(daw.testing.tempoMapAndLocateReset()) }
}

@Suite("Graph topological sort (MIX-002)")
struct GraphTopoSortTests {
    @Test("MIX-002: a crafted cycle fails with the NodeIDs on it (audio, sidechain, MIDI edges)")
    func cycle() { expectPasses(daw.testing.graphCycleRejected()) }

    @Test("MIX-002: random DAGs sort with every edge forward and the master last")
    func randomDAGs() { expectPasses(daw.testing.topoSortRandomDAGs()) }
}

@Suite("Graph buffers and summing (MIX-003, MIX-004)")
struct GraphBufferTests {
    @Test("MIX-003: a 100-track project uses <= max fan-in + depth buffers")
    func hundredTracks() { expectPasses(daw.testing.bufferLivenessHundredTracks()) }

    @Test("MIX-003, MIX-004: random mixer projects stay within the bound and render the predicted sums")
    func randomMixers() { expectPasses(daw.testing.bufferLivenessRandomMixers()) }

    @Test("MIX-003, MIX-004: random DAGs render exactly the predicted sums (no buffer clobbered)")
    func randomGraphs() { expectPasses(daw.testing.bufferLivenessRandomGraphs()) }

    @Test("MIX-004: edges into a port are summed; sidechain edges feed the sidechain port")
    func summing() { expectPasses(daw.testing.summingAndPorts()) }

    @Test("RenderGraph::create validates fed ports and feeds")
    func feedValidation() { expectPasses(daw.testing.renderGraphFeedValidation()) }
}

@Suite("Master (MIX-009)")
struct GraphMasterTests {
    @Test("MIX-009: master runs last; hard-clip limiter off by default, clips and counts overs when on")
    func masterLimiter() { expectPasses(daw.testing.masterNodeAndLimiter()) }
}
