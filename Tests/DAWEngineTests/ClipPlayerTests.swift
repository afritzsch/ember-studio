import DAWEngineTestSupport
import Testing

// T-013: the AudioClipPlayer (06 DSP-001) as a timeline node (03 TIME-005/006/008), and how it
// gets clips and assets (DW-042, DW-051). The checks are C++
// (Tests/DAWEngineTestSupport/ClipPlayerChecks.cpp) because they drive the Engine, GraphBuilder
// and RtScope; every check asserts its render scopes counted 0 RT violations (CONV §5.3).

@Suite("AudioClipPlayer (DSP-001)")
struct ClipPlayerTests {
    @Test("DSP-001: clips play on their sample range from the source offset with clip gain; mono → L/R")
    func placesClips() { expectPasses(daw.testing.clipPlayerPlacesClips()) }

    @Test("DSP-001: linear fades in ticks → samples, clamped; adjacent clips with fades")
    func fades() { expectPasses(daw.testing.clipPlayerFades()) }

    @Test("DSP-001, ENG-004: random clips over a tempo map in random block sizes match an oracle")
    func matchesOracle() { expectPasses(daw.testing.clipPlayerMatchesOracle()) }

    @Test("TIME-005, TIME-006: a loop wrap mid-block crossfades old and new pass, click-free")
    func loopWrapCrossfade() { expectPasses(daw.testing.clipPlayerLoopWrapCrossfade()) }

    @Test("TIME-008: locate while playing, and stop then play, start clean")
    func locateResets() { expectPasses(daw.testing.clipPlayerLocateResets()) }

    @Test("DW-042, DW-051, IO-031: asset refs, missing/wrong-rate assets, clips fixed per instance")
    func assetsAndClipDelivery() { expectPasses(daw.testing.clipPlayerAssetsAndClipDelivery()) }
}
