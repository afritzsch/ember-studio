import DAWEngineTestSupport
import Testing

// T-021: plugin delay compensation (05 MIX-020..024). The checks are C++
// (Tests/DAWEngineTestSupport/PdcChecks.cpp) because they need the NodePool and Engine, DAW_RT
// test nodes (FakeLatencyNode, TEST-004), daw.compile and RtScope. Every check that renders also
// asserts that its render scopes counted 0 RT violations (CONV §5.3). The goldens
// (pdc_alignment_null, click on beat 1) wait for the T-019 harness.

@Suite("PDC (MIX-020..024)")
struct PdcTests {
    @Test("MIX-020: path latency = max over inputs + own; graph latency and node table reach telemetry")
    func pathLatency() { expectPasses(daw.testing.pdcPathLatency()) }

    @Test("MIX-021: delay lines align summing and sidechain merges (null test, random mixers)")
    func mergeAlignment() { expectPasses(daw.testing.pdcMergeAlignment()) }

    @Test("MIX-022: a rebuild during playback carries delay lines over by edge ID (no discontinuity)")
    func delayLinesCarryOver() { expectPasses(daw.testing.pdcDelayLinesCarryOver()) }

    @Test("MIX-023: timeline nodes run graph-latency ahead, pre-rolled at play/locate, loop-aware")
    func sourcePreRoll() { expectPasses(daw.testing.pdcSourcePreRoll()) }

    @Test("MIX-023: clip on beat 1 behind a latent master insert exports at sample 0")
    func clickOnBeatOne() { expectPasses(daw.testing.pdcClickOnBeatOne()) }

    @Test("MIX-024: a node's latency change rebuilds on daw.compile, re-plans PDC, queues an event")
    func latencyChangeRebuilds() { expectPasses(daw.testing.pdcLatencyChangeRebuilds()) }
}
