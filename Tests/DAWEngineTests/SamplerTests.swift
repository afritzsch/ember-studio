import DAWEngineTestSupport
import Testing

// T-041: the built-in Sampler (06 DSP-020..023): zones from configJSON, Hermite resampling, 32
// voices with 5 ms steal fades, a sample-accurate ADSR, sustain pedal, All Notes Off (DW-100) and
// pitch bend; plus its registration (DW-096). The checks are C++
// (Tests/DAWEngineTestSupport/SamplerChecks.cpp) because they drive DAW_RT process() in RtScopes,
// GraphBuilder and the Engine; every check asserts its scopes counted 0 RT violations (CONV §5.3).

@Suite("Sampler (DSP-020..023)")
struct SamplerTests {
    @Test("DSP-020: zone config JSON (fields, defaults, invalid input), assets resolved by the factory")
    func parsesZones() { expectPasses(daw.testing.samplerParsesZones()) }

    @Test("DSP-020: key/velocity ranges and layers, gain, mono/stereo, silent assets, one-shot end, loops")
    func zoneMapping() { expectPasses(daw.testing.samplerZoneMapping()) }

    @Test("DSP-021: Hermite resampling; rate 1 bit-exact, A4 root playing A5 peaks at 880 Hz ±1 Hz")
    func pitch() { expectPasses(daw.testing.samplerPitch()) }

    @Test("DSP-022: sample-accurate ADSR in any block size, velocity curve")
    func envelope() { expectPasses(daw.testing.samplerEnvelope()) }

    @Test("DSP-022: 40 notes → 32 voices, oldest stolen with a 5 ms fade, no clicks; released stolen first")
    func voiceStealing() { expectPasses(daw.testing.samplerVoiceStealing()) }

    @Test("DSP-023, DW-100: sustain pedal, CC 123 All Notes Off per channel, pitch bend ±2 semitones")
    func pedalBendAllNotesOff() { expectPasses(daw.testing.samplerPedalBendAllNotesOff()) }

    @Test("DW-096: sampler registered; the midi_tempo shape builds and renders through GraphBuilder + Engine")
    func throughGraphBuilder() { expectPasses(daw.testing.samplerThroughGraphBuilder()) }
}
