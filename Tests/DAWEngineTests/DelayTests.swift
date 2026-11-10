import DAWEngineTestSupport
import Testing

// T-072: the built-in delay (06 DSP-032, DSP-040, DSP-041), NodeKind::delay through
// registerBuiltinNodes, GraphBuilder and the Engine (TIME-008, DW-162). The checks are C++
// (Tests/DAWEngineTestSupport/DelayChecks.cpp) because they call DAW_RT process() inside an
// RtScope; every check asserts 0 RT violations (CONV §5.3, DSP-040).

@Suite("Delay (DSP-032, DSP-040, DSP-041)")
struct DelayTests {
    @Test("DSP-041: ParamInfo table via paramInfoJSON; note values; delay times (ms, synced, clamped); defaults beyond numParams, NaN slots, clamping")
    func params() { expectPasses(daw.testing.delayParams()) }

    @Test("DSP-032: per-sample oracle; params and tempo changing between random-size blocks; mono and no input")
    func oracle() { expectPasses(daw.testing.delayOracle()) }

    @Test("DSP-032: echoes at k·T with feedback decay; ping-pong; ms and synced times; lowpass in the loop; mix; time change crossfades without click or pitch bend")
    func response() { expectPasses(daw.testing.delayResponse()) }

    @Test("DSP-040, ENG-004: block-size fuzz bit-exact, silence → exact 0 after the tail (no denormals), NaN/Inf guard, echoes without input, cleared by reset (DW-063), RT trap 0")
    func robustness() { expectPasses(daw.testing.delayRobustness()) }

    @Test("DSP-032, TIME-008, DW-162: registered NodeKind::delay through the Engine matches the node; a locate keeps the echoes; a tempo change crossfades the synced time")
    func throughEngine() { expectPasses(daw.testing.delayThroughEngine()) }
}
