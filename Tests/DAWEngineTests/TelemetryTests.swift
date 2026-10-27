import DAWEngineTestSupport
import Testing

// T-006: engine telemetry (ENG-050/051) and the counters Engine::render publishes (DW-024, DW-037).
// The checks are C++ (Tests/DAWEngineTestSupport/TelemetryChecks.cpp) because they need Engine,
// threads, RtScope and DAW_RT test nodes. Every check that renders or writes telemetry from RT
// code also asserts that its RtScope counted 0 violations (CONV §5.3).

@Suite("Telemetry (ENG-050, ENG-051)")
struct TelemetryTests {
    @Test("ENG-051: mach_absolute_time clock and timebase conversion")
    func clock() { expectPasses(daw.testing.telemetryClock()) }

    @Test("ENG-050: DSP load = render time / block duration, EMA with a time constant in seconds")
    func dspLoadMath() { expectPasses(daw.testing.telemetryDspLoadMath()) }

    @Test("ENG-050, ENG-051, ENG-041: render publishes epoch, load and rtViolations every block")
    func perBlock() { expectPasses(daw.testing.engineTelemetryPerBlock()) }

    @Test("ENG-050: producer paths for xruns, output latency, per-node latency and meters")
    func producerPaths() { expectPasses(daw.testing.telemetryProducerPaths()) }

    @Test("ENG-050: lock-free readers never see a torn latency table or meter pair")
    func concurrentReaders() { expectPasses(daw.testing.telemetryConcurrentReadersSeeConsistentValues()) }

    @Test("ENG-050: the snapshot is plain data Swift (and the facade's TelemetryPOD) can copy")
    func snapshotFromSwift() {
        let snapshot: daw.TelemetrySnapshot = daw.testing.snapshotAfterRendering(5)
        #expect(snapshot.graphEpoch == 10)
        #expect(snapshot.rtViolations == 0)
        #expect(snapshot.deviceOutputLatency == 256)
        #expect(snapshot.outputLatency == 256)
        #expect(snapshot.dspLoadPercent >= 0)
        #expect(snapshot.oversizeBlocks == 0)
    }
}

@Suite("Telemetry counters (DW-037)")
struct TelemetryCounterTests {
    @Test("DW-037: oversize blocks render silence and are counted")
    func oversizeBlocks() { expectPasses(daw.testing.engineCountsOversizeBlocks()) }

    @Test("DW-037: blocks that end with the RetireQueue full are counted")
    func retireQueueFull() { expectPasses(daw.testing.engineCountsRetireQueueFull()) }
}

#if DEBUG  // the trap exists only in Debug (BUILD-005)
// These read and reset the process-wide trap state and violate on purpose, so they run inside the
// serialized RtTrapTests suite (14-testing, "Process-wide trap state").
extension RtTrapTests {
    @Suite("Telemetry rtViolations (DW-011, DW-024)")
    struct TelemetryViolationTests {
        @Test("DW-011, DW-024: an allocating node's violations reach rtViolations and firstViolation")
        func fromRenderScope() { expectPasses(daw.testing.engineRtViolationsFromRenderScope()) }

        @Test("DW-024: violations outside the engine's render scope don't change its rtViolations")
        func ignoresOtherScopes() { expectPasses(daw.testing.engineRtViolationsIgnoreOtherScopes()) }
    }
}
#endif
