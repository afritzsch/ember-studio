import DAWEngineTestSupport
import Testing

// T-008: Transport, TransportBlock segments, timeline-node helpers, playhead. The checks are C++
// (Tests/DAWEngineTestSupport/TransportChecks.cpp) because they need threads, RtScope and DAW_RT
// test nodes. Every check that advances the transport or renders also asserts that its own scope
// counted 0 RT violations (CONV §5.3).

@Suite("Transport commands (TIME-004)")
struct TransportCommandTests {
    @Test("TIME-004: commands queue, apply in order at block start, validate; full queue refuses")
    func applyAtBlockStart() { expectPasses(daw.testing.transportCommandsApplyAtBlockStart()) }

    @Test("TIME-004: several producer threads while the audio thread advances; each applied once")
    func manyProducers() { expectPasses(daw.testing.transportCommandsFromManyThreads()) }
}

@Suite("Transport segments (TIME-005)")
struct TransportSegmentTests {
    @Test("TIME-005: one contiguous segment per block without a loop; none while stopped or empty")
    func linear() { expectPasses(daw.testing.transportLinearSegments()) }

    @Test("TIME-005: loop wrap mid-block gives two correct segments")
    func wrapMidBlock() { expectPasses(daw.testing.transportLoopWrapMidBlock()) }

    @Test("TIME-005: wrap exactly at a block boundary")
    func wrapAtBoundary() { expectPasses(daw.testing.transportLoopWrapAtBlockBoundary()) }

    @Test("TIME-005, ENG-004: random block sizes 0...4096 against a frame-by-frame timeline model")
    func randomBlockSizes() { expectPasses(daw.testing.transportRandomBlockSizes()) }

    @Test("TIME-005: past the loop end, loop toggled mid-play, loop shorter than a block, sub-sample ticks")
    func edgeCases() { expectPasses(daw.testing.transportLoopEdgeCases()) }

    @Test("DW-125: loops shorter than a block are laid out in passes of at most two segments, no gap")
    func shortLoopPasses() { expectPasses(daw.testing.transportShortLoopPasses()) }

    @Test("DW-125: through the Engine, every event of a short loop plays on every pass")
    func shortLoopThroughEngine() { expectPasses(daw.testing.engineShortLoopTimelineNode()) }
}

@Suite("Timeline nodes (TIME-006)")
struct TimelineNodeTests {
    @Test("TIME-006: a test timeline node rendered through the Engine places every event exactly")
    func honorsSegments() { expectPasses(daw.testing.timelineNodeHonorsSegments()) }

    @Test("TIME-006: SegmentContinuity reports wraps, locates and the first segment as jumps")
    func continuity() { expectPasses(daw.testing.segmentContinuity()) }
}

@Suite("Tempo and the transport (TIME-003, TIME-007)")
struct TransportTempoTests {
    @Test("TIME-007: a block spanning a tempo change runs at the start tempo; events stay exact")
    func tempoChangeInsideBlock() { expectPasses(daw.testing.tempoChangeInsideBlock()) }

    @Test("TIME-003: each block uses the tempo map it is given; loop and locate resolve through it")
    func mapPerBlock() { expectPasses(daw.testing.tempoMapPerBlock()) }

    @Test("DW-061: a tempo edit keeps the playhead's tick, stopped and playing; the loop follows its ticks")
    func tempoEditKeepsTick() { expectPasses(daw.testing.tempoEditKeepsTick()) }

    @Test("TIME-003, ENG-041: Engine::render hands nodes the block, pointing at the current graph's tempo map")
    func engineBlock() { expectPasses(daw.testing.engineHandsNodesTheTransportBlock()) }
}

@Suite("Locate (TIME-008)")
struct TransportLocateTests {
    @Test("TIME-008: locate while playing resets the graph's timeline nodes once; effects keep their state")
    func locateFlagsReset() { expectPasses(daw.testing.locateWhilePlayingFlagsReset()) }
}

@Suite("Playhead (TIME-009)")
struct PlayheadTests {
    @Test("TIME-009: playhead compensated for output latency, clamped at play start, unwrapped after a wrap")
    func latencyCompensation() { expectPasses(daw.testing.playheadLatencyCompensation()) }

    @Test("TIME-009: a reader thread never sees a torn playhead")
    func consistentAcrossThreads() { expectPasses(daw.testing.playheadIsConsistentAcrossThreads()) }
}
