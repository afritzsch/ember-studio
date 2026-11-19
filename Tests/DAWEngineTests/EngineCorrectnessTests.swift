import DAWEngineTestSupport
import Testing

// T-111: engine correctness fixes from the 2026-11-18 review. The checks are C++
// (Tests/DAWEngineTestSupport/EngineCorrectnessChecks.cpp) because they drive the engine, the
// compiler, MidiDelayLine and the facade's C++ seams directly; each asserts 0 RT violations
// (CONV §5.3). DW-310 is in OfflineResetTests.

@Suite("Engine correctness (T-111)")
struct EngineCorrectnessTests {
    @Test("DW-318: MidiDelayLine reserves one release per held key; unpaired note-ons never make it drop later notes")
    func midiDelayLineHeldKeys() { expectPasses(daw.testing.midiDelayLineCountsHeldKeys()) }

    @Test("DW-311, MIX-024: latency reports drained by a failed build rebuild the last good graph; the rejection stays reported")
    func compilerKeepsReports() { expectPasses(daw.testing.compilerKeepsLatencyReportsOfFailedBuild()) }

    @Test("DW-312, MIX-023: pre-roll clipping, NaN blocks and meter peaks don't reach telemetry; heard audio does")
    func preRollTelemetry() { expectPasses(daw.testing.preRollFeedsNoTelemetry()) }

    @Test("DW-313, TIME-004: with no graph, commands still apply (a locate waits for a map) and block().tempo is null")
    func silentWithoutGraph() { expectPasses(daw.testing.silentBlockWithoutGraph()) }

    @Test("DW-313, TIME-008: an oversize block applies commands without playing; its locate resets the timeline nodes next block")
    func silentOversize() { expectPasses(daw.testing.silentOversizeBlock()) }

    @Test("DW-319, REC-003: a buffer-size change while recording ends the take; the next take has the new latency (loopback ±1)")
    func bufferChangeEndsTakes() { expectPasses(daw.testing.deviceBufferChangeEndsTakes()) }

    @Test("DW-320, IO-010: during an export play/setRecording are ignored, locate/setLoop apply after it, stop cancels it and the queue")
    func transportDuringExport() { expectPasses(daw.testing.transportCallsDuringExport()) }

    @Test("DW-321: destroying a facade mid-export cancels it quickly and leaves no file")
    func destroyCancelsExport() { expectPasses(daw.testing.facadeDestroyCancelsExport()) }
}
