import DAWEngineTestSupport
import Testing

// T-020: sends (05 MIX-007) — the GainNode (NodeKind::gain) and pre/post-fader sends through the
// Engine. The checks are C++ (Tests/DAWEngineTestSupport/SendChecks.cpp) because they call DAW_RT
// process() inside an RtScope; every check asserts 0 RT violations (CONV §5.3).

@Suite("Sends (MIX-007)")
struct SendTests {
    @Test("MIX-007, ENG-022: gain node level and mute slots, ramped per block; plain gain has no mute; block-size fuzz")
    func gainNodeLevel() { expectPasses(daw.testing.gainNodeLevel()) }

    @Test("MIX-007: post-fader send follows fader/pan/phase, pre-fader doesn't; slots, no rebuild")
    func preAndPostFader() { expectPasses(daw.testing.sendsPreAndPostFader()) }

    @Test("MIX-007, MIX-006: a muted track silences pre- and post-fader sends; unmute fades back, no click")
    func mutedWithTrack() { expectPasses(daw.testing.sendsMutedWithTrack()) }
}
