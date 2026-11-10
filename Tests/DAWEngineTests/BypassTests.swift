import DAWEngineTestSupport
import Testing

// T-064: host-side bypass (10 PLUG-018). The checks are C++
// (Tests/DAWEngineTestSupport/BypassChecks.cpp): they need GraphBuilder, the NodePool, DAW_RT test
// nodes and RtScope. Every check that renders asserts 0 RT violations (CONV §5.3). The plugin halves
// are in VST3PluginTests/AUPluginTests, the model and golden halves in DAWModelTests/GoldenTests.

@Suite("Host bypass (PLUG-018)")
struct BypassTests {
    @Test("PLUG-018: a bypassed latent effect nulls against a plain inverted path; PDC unchanged; a slot write toggles it, no rebuild, no re-creation")
    func latentNull() { expectPasses(daw.testing.bypassLatentNull()) }

    @Test("PLUG-018: a toggle is a one-block crossfade; rebuilds carry the bypass delay line over; a grown latency stays aligned")
    func crossfadeAndRebuild() { expectPasses(daw.testing.bypassCrossfadeAndRebuild()) }
}

