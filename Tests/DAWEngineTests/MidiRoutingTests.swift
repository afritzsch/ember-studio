import DAWEngineTestSupport
import Testing

// T-045 (DW-099): MIDI edges in the RenderGraph carry data. Player → instrument edges point the
// instrument's midiIn at the player's storage; converging edges merge in frame order; storage has
// a fixed capacity in every graph; MIDI edges get PDC delays (05 MIX-021) with carry-over across
// rebuilds. The checks are C++ (Tests/DAWEngineTestSupport/MidiRoutingChecks.cpp) because they
// drive the Engine, GraphBuilder, RenderGraph and RtScope; every check asserts 0 RT violations
// (CONV §5.3).

@Suite("MIDI routing (DW-099)")
struct MidiRoutingTests {
    @Test("DSP-003, MIX-001: a player → instrument MIDI edge delivers the player's events in place, fan-out included")
    func playerToInstrument() { expectPasses(daw.testing.midiRoutingPlayerToInstrument()) }

    @Test("MIX-001: converging MIDI edges merge in frame order, stable in edge order, nothing dropped")
    func mergesInFrameOrder() { expectPasses(daw.testing.midiRoutingMergesInFrameOrder()) }

    @Test("DSP-003, DW-099: fixed-capacity MIDI storage, no hanging notes across snapshot swaps, locates and stops")
    func noHangingNotesAcrossSwaps() { expectPasses(daw.testing.midiRoutingNoHangingNotesAcrossSwaps()) }

    @Test("MIX-021, MIX-022: MIDI edges are PDC-delayed like audio, and the delay line carries over a rebuild")
    func pdcDelaysMidiEdges() { expectPasses(daw.testing.midiRoutingPdcDelaysMidiEdges()) }

    @Test("MIX-021: MidiDelayLine delays exactly, survives delay changes, caps output, never drops a reserved release")
    func midiDelayLine() { expectPasses(daw.testing.midiDelayLineSemantics()) }

    @Test("DW-099, DSP-021: a MIDI track with a sampler renders A5 at 880 Hz through the facade, 0 RT violations")
    func samplerThroughFacade() { expectPasses(daw.testing.midiTrackWithSamplerThroughFacade()) }
}
