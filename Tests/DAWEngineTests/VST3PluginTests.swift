import DAWEngineTestSupport
import Testing

// T-062: VST3 hosting (10 PLUG-011..016, VST3 halves). The checks are C++
// (Tests/DAWEngineTestSupport/VST3PluginChecks.cpp) because they need the Engine/GraphBuilder rig,
// daw.compile, RtScope and the plugin host. Plugins: real .vst3 bundles built by
// scripts/build-test-vst3.sh, the SDK's `again` sample and EmberTest (Tests/VST3TestPlugin).
// Serialized: EmberTest's knobs act on every live instance in the process.

@Suite("VST3 hosting (PLUG-011..016)", .serialized)
struct VST3PluginTests {
    @Test("PLUG-011: VST3 identifiers and the vst3Plugin configJSON parse and round-trip")
    func identifierAndConfig() { expectPasses(daw.testing.vst3IdentifierAndConfig()) }

    @Test("PLUG-011/015: the SDK again sample renders input x gain; param slots become block-rate changes; 0 RT violations")
    func againThroughGraph() { expectPasses(daw.testing.vst3AgainThroughGraph()) }

    @Test("PLUG-011: notes reach the plugin as note on/off events at exact frame offsets; 0 RT violations")
    func noteFrameOffsets() { expectPasses(daw.testing.vst3NoteFrameOffsets()) }

    @Test("PLUG-011: the ProcessContext carries tempo, ppq, bar position, time signature and playing")
    func processContext() { expectPasses(daw.testing.vst3ProcessContext()) }

    @Test("PLUG-014: the aux input bus is fed from the node's sidechain port, silence without one")
    func sidechain() { expectPasses(daw.testing.vst3Sidechain()) }

    @Test("PLUG-013/MIX-024: restartComponent(kLatencyChanged), from any thread, rebuilds the graph and PDC stays aligned")
    func latencyChange() { expectPasses(daw.testing.vst3LatencyChange()) }

    @Test("PLUG-016: component + controller state round trip through the facade; setComponentState on restore; survives a rate change")
    func stateRoundTrip() { expectPasses(daw.testing.vst3StateRoundTrip()) }

    @Test("PLUG-011/012: a missing plugin renders as absent and is reported; slots keep their instance; parked instances are adopted")
    func failureAndAdoption() { expectPasses(daw.testing.vst3FailureAndAdoption()) }

    // T-064 (in this serialized suite: they set EmberTest's process-wide knobs too).
    @Test("PLUG-022: a VST3 writing NaN is silenced, counted in nanBlocks, reported once (pluginMisbehaved event); 0 RT violations")
    func nanGuard() { expectPasses(daw.testing.vst3NanGuard()) }

    @Test("PLUG-018: a latent VST3 host-bypassed nulls against its input on the timeline; slot writes toggle it; same instance and state")
    func hostBypass() { expectPasses(daw.testing.vst3HostBypass()) }
}
