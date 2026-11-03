import DAWEngineTestSupport
import Testing

// T-023: sidechain edges and ports (05 MIX-008, keeping MIX-004 and MIX-021 green). The checks
// are C++ (Tests/DAWEngineTestSupport/SidechainChecks.cpp) because they need the NodePool and
// Engine, DAW_RT test nodes, daw.compile and RtScope. The built-in compressor (DSP-031, T-071)
// isn't there yet, so SidechainMixNode (TEST-004 style, out = in + level · sidechain) stands in
// under NodeKind::compressor. Every check that renders asserts 0 RT violations (CONV §5.3).
// MIX-008's golden with the real compressor (`sidechain_compressor`) is T-071's.

@Suite("Sidechain (MIX-008)")
struct SidechainTests {
    @Test("TEST-004/MIX-008: SidechainMixNode adds level · sidechain; an empty sidechain passes the input")
    func mixNode() { expectPasses(daw.testing.sidechainMixNode()) }

    @Test("MIX-008/MIX-004/ENG-003: NodeIO sidechain is empty without an edge, else the sum of its sidechain edges")
    func portDelivery() { expectPasses(daw.testing.sidechainPortDelivery()) }

    @Test("MIX-008: pre-fader tap ignores the source's fader/mute/phase/pan, post-fader follows them")
    func preAndPostFaderTap() { expectPasses(daw.testing.sidechainPreAndPostFaderTap()) }

    @Test("MIX-021: PDC aligns sidechain merges (latent main, latent sidechain, summed sidechain nulls)")
    func pdcAlignment() { expectPasses(daw.testing.sidechainPdcAlignment()) }

    @Test("MIX-003: buffer liveness covers sidechain ports (symbolic plan check, long-chain render)")
    func bufferLiveness() { expectPasses(daw.testing.sidechainBufferLiveness()) }

    @Test("MIX-008/MIX-022: rebuilds add, move and remove sidechains; delayed sidechain lines carry over")
    func rebuild() { expectPasses(daw.testing.sidechainRebuild()) }

    @Test("MIX-008: a model-shaped SetSidechain graph renders through the facade (pre/post-fader export)")
    func throughFacade() { expectPasses(daw.testing.sidechainThroughFacade()) }
}
