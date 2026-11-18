import DAWEngineTestSupport
import Testing

// T-099: the telemetry counters of 08 "Contract delta (T-099)". The checks are C++
// (Tests/DAWEngineTestSupport/EngineCounterChecks.cpp): they need Engine, DAW_RT test nodes and
// the facade's fake device driver. Every render counts 0 RT violations (CONV §5.3).

@Suite("Engine counters (T-099: DW-083, DW-170, DW-192)")
struct EngineCounterTests {
    @Test("DW-083, ENG-050: master limiter overs count into telemetry clippedSamples, across master replacements")
    func clippedSamples() { expectPasses(daw.testing.masterClipsCountIntoTelemetry()) }

    @Test("DW-170, ENG-050: MidiDelayLine overflow drops are summed by Engine::render into midiEventsDropped, once each")
    func midiEventsDropped() { expectPasses(daw.testing.midiDelayLineDropsCountIntoTelemetry()) }

    @Test("DW-192, IO-005: TelemetryPOD.bufferFrames is the running device's buffer, 0 without one")
    func bufferFrames() { expectPasses(daw.testing.facadeReportsDeviceBufferFrames()) }
}
