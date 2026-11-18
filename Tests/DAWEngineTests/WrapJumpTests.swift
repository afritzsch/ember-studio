import DAWEngineTestSupport
import Testing

// T-092 (DW-232): AUTO-003 for the built-in effects and instruments. The checks are C++
// (Tests/DAWEngineTestSupport/WrapJumpChecks.cpp): they drive each node directly with two-segment
// TransportBlocks and the after-wrap side channel, in RtScopes, and assert 0 RT violations
// (CONV §5.3). The strip and gain node halves are in AutomationTests.

@Suite("Wrap jump in the built-ins (AUTO-003)")
struct WrapJumpTests {
    @Test("AUTO-003: EQ bands jump to the after-wrap gain at the wrap frame; no lane, no jump")
    func eq() { expectPasses(daw.testing.wrapJumpEq()) }

    @Test("AUTO-003: compressor threshold and makeup jump at the wrap frame")
    func compressor() { expectPasses(daw.testing.wrapJumpCompressor()) }

    @Test("AUTO-003: delay mix jumps at the wrap frame and holds into the next block")
    func delay() { expectPasses(daw.testing.wrapJumpDelay()) }

    @Test("AUTO-003: reverb mix jumps at the wrap frame and holds into the next block")
    func reverb() { expectPasses(daw.testing.wrapJumpReverb()) }

    @Test("AUTO-003: a sampler note at the loop start gets the after-wrap attack")
    func sampler() { expectPasses(daw.testing.wrapJumpSampler()) }

    @Test("AUTO-003: the metronome's loop-start click latches the after-wrap level")
    func metronome() { expectPasses(daw.testing.wrapJumpMetronome()) }
}
