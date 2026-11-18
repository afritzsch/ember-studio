import DAWEngineTestSupport
import Testing

// T-097: hosted-plugin follow-ups (10 "Contract delta (T-097)"). The checks are C++
// (Tests/DAWEngineTestSupport/PluginFollowupChecks.cpp) because they need the Engine/GraphBuilder
// rig, RtScope and the plugin hosts. They are extensions of the serialized VST3 and AU hosting
// suites: EmberTest's and the fake AU's process-wide knobs (latency, restart requests) would
// otherwise reach the instances those suites test, and the other way round.

extension VST3PluginTests {
    @Test("DW-242/DW-063: a VST3 reset clears its tail; export path resets on the non-RT thread, the fallback never waits")
    func t097ResetClearsTail() { expectPasses(daw.testing.vst3ResetClearsTail()) }

    @Test("DW-211/DW-242: offline engines prepare kOffline / renderingOffline; every export resets each hosted plugin once")
    func t097OfflineModeAndExportReset() { expectPasses(daw.testing.pluginOfflineModeAndExportReset()) }

    @Test("DW-233/AUTO-003: a VST3 parameter jumps at a loop wrap (block value, hold, after-wrap point); 0 RT violations")
    func t097WrapJump() { expectPasses(daw.testing.pluginWrapJump(false)) }

    @Test("DW-210: VST3 MIDI CC, aftertouch and pitch bend become IMidiMapping parameter points at their frames")
    func t097MidiMapping() { expectPasses(daw.testing.vst3MidiMapping()) }

    @Test("DW-225/PLUG-018: bypassing a VST3 instrument releases its held notes (note-offs + mapped CC 123)")
    func t097BypassReleasesNotes() { expectPasses(daw.testing.pluginBypassReleasesNotes(false)) }

    @Test("DW-218: a VST3 instance destroyed while its latency timer runs is torn down on the destroying thread")
    func t097TeardownVsLatencyTimer() { expectPasses(daw.testing.vst3TeardownVsLatencyTimer(60)) }
}

extension AUPluginTests {
    @Test("DW-242/DW-063: an AU reset clears its tail (fake AU, both paths; AUDelay's pending echo)")
    func t097ResetClearsTail() { expectPasses(daw.testing.auResetClearsTail()) }

    @Test("DW-233/AUTO-003: an AU parameter jumps at exactly the loop wrap frame (second render-thread event); 0 RT violations")
    func t097WrapJump() { expectPasses(daw.testing.pluginWrapJump(true)) }

    @Test("DW-225/PLUG-018: bypassing an AU that holds a note releases it (note-off + CC 123)")
    func t097BypassReleasesNotes() { expectPasses(daw.testing.pluginBypassReleasesNotes(true)) }
}

// With the DW-214 teardown checks: they count the process's pending V2 releases, which this one adds to.
extension AUTeardownStressTests {
    @Test("DW-217: instantiating V2 AUs while others initialize and uninitialize on another thread is safe")
    func t097InstantiateVsLifecycle() { expectPasses(daw.testing.auInstantiateVsLifecycle(150)) }
}
