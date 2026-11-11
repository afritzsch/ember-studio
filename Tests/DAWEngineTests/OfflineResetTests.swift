import DAWEngineTestSupport
import Testing

// T-089 (DW-063): offline renders reset every node first. The checks are C++
// (Tests/DAWEngineTestSupport/OfflineResetChecks.cpp) because they drive nodes and the
// OfflineDriver directly; each asserts 0 RT violations (CONV §5.3).

@Suite("Offline renders reset every node (DW-063)")
struct OfflineResetTests {
    @Test("DW-063, IO-011: exports on one engine are bit-identical after live playback or a cut-off export leaves tails ringing; a live locate keeps them (TIME-008)")
    func resetsEveryNode() { expectPasses(daw.testing.offlineResetsEveryNode()) }

    @Test("DW-063: each built-in effect's reset() returns it to its freshly prepared state")
    func builtinReset() { expectPasses(daw.testing.builtinResetMatchesFreshNode()) }
}
