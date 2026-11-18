import DAWEngineTestSupport
import Testing

// T-097: hosted-plugin follow-ups (10 "Contract delta (T-097)"). The checks are C++
// (Tests/DAWEngineTestSupport/PluginFollowupChecks.cpp) because they need the Engine/GraphBuilder
// rig, RtScope and the plugin hosts. Serialized: EmberTest's and the fake AU's knobs and counters
// are process-wide.

@Suite("Hosted-plugin follow-ups (T-097)", .serialized)
struct PluginFollowupTests {
    @Test("DW-242/DW-063: a VST3 reset clears its tail; export path resets on the non-RT thread, the fallback never waits")
    func vst3ResetClearsTail() { expectPasses(daw.testing.vst3ResetClearsTail()) }

    @Test("DW-242/DW-063: an AU reset clears its tail (fake AU, both paths; AUDelay's pending echo)")
    func auResetClearsTail() { expectPasses(daw.testing.auResetClearsTail()) }

    @Test("DW-211/DW-242: offline engines prepare kOffline / renderingOffline; every export resets each hosted plugin once")
    func offlineModeAndExportReset() { expectPasses(daw.testing.pluginOfflineModeAndExportReset()) }

    @Test("DW-233/AUTO-003: hosted plugins jump at a loop wrap (VST3 points, AU event at the wrap frame); 0 RT violations")
    func wrapJump() { expectPasses(daw.testing.pluginWrapJump()) }

    @Test("DW-210: VST3 MIDI CC, aftertouch and pitch bend become IMidiMapping parameter points at their frames")
    func midiMapping() { expectPasses(daw.testing.vst3MidiMapping()) }

    @Test("DW-225/PLUG-018: bypassing an instrument plugin releases its held notes (note-offs + CC 123), VST3 and AU")
    func bypassReleasesNotes() { expectPasses(daw.testing.pluginBypassReleasesNotes()) }
}

// T-097 audits (DW-217, DW-218).
@Suite("Hosted-plugin lifecycle audits (T-097)", .serialized)
struct PluginLifecycleAuditTests {
    @Test("DW-218: a VST3 instance destroyed while its latency timer runs is torn down on the destroying thread")
    func vst3TeardownVsLatencyTimer() { expectPasses(daw.testing.vst3TeardownVsLatencyTimer(60)) }

    @Test("DW-217: instantiating V2 AUs while others initialize and uninitialize on another thread is safe")
    func auInstantiateVsLifecycle() { expectPasses(daw.testing.auInstantiateVsLifecycle(150)) }
}
