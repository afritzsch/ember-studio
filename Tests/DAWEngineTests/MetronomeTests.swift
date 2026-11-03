import DAWEngineTestSupport
import Testing

// T-024: the metronome (03 TIME-010, 06 DSP-011), NodeKind::metronome through registerBuiltinNodes,
// GraphBuilder and the Engine. The checks are C++ (Tests/DAWEngineTestSupport/MetronomeChecks.cpp)
// because they call DAW_RT process() inside an RtScope; every check asserts 0 RT violations
// (CONV §5.3).

@Suite("Metronome (TIME-010, DSP-011)")
struct MetronomeTests {
    @Test("TIME-010, DSP-011: click shapes, param table and defaults, clamping/NaN, mono, 0-frame blocks, reset fade")
    func nodeBasics() { expectPasses(daw.testing.metronomeNodeBasics()) }

    @Test("TIME-010, TIME-007: clicks sample-exact over tempo changes and 3/4 → 4/4 → 6/8, accented bar starts, random blocks")
    func clicksOnTempoMap() { expectPasses(daw.testing.metronomeClicksOnTempoMap()) }

    @Test("TIME-005, TIME-006: loop wrap mid-block; each pass clicks from its own ticks, clicks ring across the wrap")
    func loopWrap() { expectPasses(daw.testing.metronomeLoopWrap()) }

    @Test("TIME-010: on switch and levels latched per click; off never cuts, on never starts a partial click")
    func switchAndLevels() { expectPasses(daw.testing.metronomeSwitchAndLevels()) }

    @Test("TIME-008, DW-085: locate cuts the click in progress with a 64-frame fade; stop fades and stays silent")
    func locateAndStop() { expectPasses(daw.testing.metronomeLocateAndStop()) }

    @Test("MIX-023, DW-085: timeline node scheduled graph-latency ahead; beat 1 on frame 0 behind 2048 samples of latency")
    func withGraphLatency() { expectPasses(daw.testing.metronomeWithGraphLatency()) }
}
