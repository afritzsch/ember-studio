import DAWEngineTestSupport
import Testing

// T-070: the built-in EQ (06 DSP-030, DSP-040, DSP-041), NodeKind::eq through
// registerBuiltinNodes, GraphBuilder and the Engine, and the registry's param tables. The checks
// are C++ (Tests/DAWEngineTestSupport/EqChecks.cpp) because they call DAW_RT process() inside an
// RtScope; every check asserts 0 RT violations (CONV §5.3, DSP-040).

@Suite("EQ (DSP-030, DSP-040, DSP-041)")
struct EqTests {
    @Test("DSP-041: ParamInfo table; NodeRegistry::paramInfo for every built-in kind; paramInfoJSON reads it; flat defaults, NaN slots, clamping; 0 latency")
    func params() { expectPasses(daw.testing.eqParams()) }

    @Test("DSP-030: frequency response vs analytic RBJ within 0.1 dB, every band and the whole chain, at four rates, up to 30 Hz below Nyquist")
    func response() { expectPasses(daw.testing.eqResponse()) }

    @Test("DSP-030: gain and frequency sweeps stay within a slew bound at every block size; a full-range step stays bounded and settles; state carries")
    func sweep() { expectPasses(daw.testing.eqSweep()) }

    @Test("DSP-040, ENG-004: block-size fuzz bit-exact, silence → exact 0, NaN/Inf guard clears state and bumps telemetry, mono and no input, RT trap 0")
    func robustness() { expectPasses(daw.testing.eqRobustness()) }

    @Test("DSP-030: registered NodeKind::eq through GraphBuilder and the Engine, response in place, 0 latency; DW-142 NaN telemetry through the effects and the facade")
    func throughEngine() { expectPasses(daw.testing.eqThroughEngine()) }
}
