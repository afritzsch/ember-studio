import DAWEngineTestSupport
import Testing

// T-073: the built-in reverb (06 DSP-033, DSP-040, DSP-041), NodeKind::reverb through
// registerBuiltinNodes, GraphBuilder and the Engine (IO-011, TIME-008). The checks are C++
// (Tests/DAWEngineTestSupport/ReverbChecks.cpp) because they call DAW_RT process() inside an
// RtScope; every check asserts 0 RT violations (CONV §5.3, DSP-040).

@Suite("Reverb (DSP-033, DSP-040, DSP-041)")
struct ReverbTests {
    @Test("DSP-041: ParamInfo table via paramInfoJSON; 0 latency; line lengths; defaults beyond numParams, NaN slots, clamping")
    func params() { expectPasses(daw.testing.reverbParams()) }

    @Test("DSP-033: per-sample oracle of the FDN signal path; size/pre-delay glides, decay/mix ramps, random blocks")
    func oracle() { expectPasses(daw.testing.reverbOracle()) }

    @Test("DSP-033: first arrival = pre-delay + shortest line; LF RT60 = decay; damping; L/R decorrelated; mix; mono input")
    func response() { expectPasses(daw.testing.reverbResponse()) }

    @Test("DSP-040, ENG-004: block-size fuzz bit-exact, silence → exact 0 after the tail (no denormals), NaN/Inf guard, tail without input, cleared by reset (DW-063), RT trap 0")
    func robustness() { expectPasses(daw.testing.reverbRobustness()) }

    @Test("DSP-033, IO-011, TIME-008: registered NodeKind::reverb through the Engine matches the node; two engines bit-identical; locate keeps the tail")
    func throughEngine() { expectPasses(daw.testing.reverbThroughEngine()) }
}
