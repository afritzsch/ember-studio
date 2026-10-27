import DAWEngineTestSupport
import Testing

// T-004: node API, RenderGraph, Engine::render, snapshot publish and epoch reclaim, NodePool,
// denormal flushing. The checks are C++ (Tests/DAWEngineTestSupport/EngineChecks.cpp) because
// they need threads, RtScope and DAW_RT test nodes. Every check that renders also asserts that
// its render scope counted 0 RT violations (CONV §5.3).

@Suite("Node API (ENG-001..004)")
struct NodeAPITests {
    @Test("ENG-001, ENG-002, ENG-013: prepare before publish, process, reset, release + destroy on daw.reclaim")
    func lifecycle() { expectPasses(daw.testing.nodeLifecycle()) }

    @Test("ENG-013: a replaced node lives until no published graph references it")
    func replaced() { expectPasses(daw.testing.nodeReplacedOnlyAfterGraphsReleaseIt()) }

    @Test("ENG-003: NodeIO audio in/out, summed input, sidechain, MIDI views")
    func nodeIO() { expectPasses(daw.testing.nodeIOViews()) }

    @Test("ENG-003: MidiEventWriter appends into fixed storage and drops when full")
    func midiWriter() { expectPasses(daw.testing.midiEventWriter()) }

    @Test("ENG-004: fuzz with random block sizes 0...4096; oversize blocks are silent")
    func randomBlockSizes() { expectPasses(daw.testing.randomBlockSizes()) }
}

@Suite("Snapshots (ENG-010..015)")
struct SnapshotTests {
    @Test("ENG-010, ENG-011: 10k publishes during render; one graph per block; everything freed")
    func publishStress() { expectPasses(daw.testing.publishWhileRendering()) }

    @Test("ENG-012: an artificially stalled audio thread keeps its graph alive (no use-after-free)")
    func stalledRender() { expectPasses(daw.testing.stalledRenderKeepsGraphAlive()) }

    @Test("ENG-012: graphs replaced while idle are freed without waiting for a block")
    func idleReclaim() { expectPasses(daw.testing.idleEngineFreesReplacedGraphs()) }

    @Test("ENG-014: RT-retired objects are freed on daw.reclaim; render counts no deallocation")
    func retireQueue() { expectPasses(daw.testing.rtRetireQueue()) }

    @Test("ENG-015, ENG-040: silence without a graph; extra target channels silent")
    func silence() { expectPasses(daw.testing.silenceWithoutGraph()) }
}

@Suite("Engine entry points (ENG-040..042)")
struct EngineRenderTests {
    @Test("ENG-041: sum inputs, topological order, master to target, one epoch per block")
    func renderOrder() { expectPasses(daw.testing.renderOrderAndSumming()) }

    @Test("ENG-042: decaying IIR flushes to zero inside render; caller's FPCR restored")
    func flushToZero() { expectPasses(daw.testing.flushDenormalsInRender()) }

    @Test("ENG-061: RenderGraph::create validates buffer indices and owns its pool")
    func graphValidation() { expectPasses(daw.testing.renderGraphValidation()) }

    #if DEBUG  // the trap exists only in Debug (BUILD-005)
    @Test("DW-011: constructing an Engine installs the RT trap")
    func installsTrap() { #expect(daw.testing.engineInstallsRtTrap()) }
    #endif
}
