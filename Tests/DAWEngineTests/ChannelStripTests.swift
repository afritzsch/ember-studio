import DAWEngineTestSupport
import Testing

// T-013: the ChannelStrip's gain and pan (06 DSP-010, 05 MIX-005, ENG-022) and its meter window.
// The checks are C++ (Tests/DAWEngineTestSupport/ChannelStripChecks.cpp) because they call DAW_RT
// process() inside an RtScope; every check asserts 0 RT violations (CONV §5.3).

@Suite("ChannelStrip (DSP-010, MIX-005)")
struct ChannelStripTests {
    @Test("MIX-005: −3 dB constant-power pan law; gain linear, clamped to +12 dB")
    func panLaw() { expectPasses(daw.testing.channelStripPanLaw()) }

    @Test("ENG-022: gain and pan ramp per block from the previous block's end")
    func smoothing() { expectPasses(daw.testing.channelStripSmoothing()) }

    @Test("MIX-005: post-fader peak and 300 ms RMS into Telemetry")
    func meter() { expectPasses(daw.testing.channelStripMeter()) }

    @Test("DSP-001, DSP-010: clip player → strip → master through the Engine; slot writes, no rebuild")
    func throughEngine() { expectPasses(daw.testing.channelStripThroughEngine()) }
}
