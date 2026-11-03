import DAWEngineTestSupport
import Testing

// T-071: the built-in compressor (06 DSP-031, DSP-040, DSP-041) with its sidechain input
// (05 MIX-008), NodeKind::compressor through registerBuiltinNodes, GraphBuilder and the Engine.
// The checks are C++ (Tests/DAWEngineTestSupport/CompressorChecks.cpp) because they call DAW_RT
// process() inside an RtScope; every check asserts 0 RT violations (CONV §5.3, DSP-040).

@Suite("Compressor (DSP-031, DSP-040, DSP-041)")
struct CompressorTests {
    @Test("DSP-041: ParamInfo table via paramInfoJSON; meters; 0 latency; defaults beyond numParams, NaN slots, clamping")
    func params() { expectPasses(daw.testing.compressorParams()) }

    @Test("DSP-031: static curve (threshold, ratio, hard/soft knee) through the node, peak and RMS detectors; makeup")
    func staticCurve() { expectPasses(daw.testing.compressorStaticCurve()) }

    @Test("DSP-031: attack/release ballistics per sample vs closed form and an oracle; block-ramped params")
    func ballistics() { expectPasses(daw.testing.compressorBallistics()) }

    @Test("DSP-031, MIX-008: sidechain keys the detector (0 latency), input doesn't; self-keyed without one; stereo link")
    func sidechain() { expectPasses(daw.testing.compressorSidechain()) }

    @Test("DSP-040, ENG-004: block-size fuzz bit-exact, silence → silence with exact 0 dB settle, NaN/Inf guard, RT trap 0")
    func robustness() { expectPasses(daw.testing.compressorRobustness()) }

    @Test("DSP-031, MIX-008, DW-096: registered NodeKind::compressor keyed by a sidechain edge in the Engine; GR meter in Telemetry")
    func throughEngine() { expectPasses(daw.testing.compressorThroughEngine()) }
}
