import DAWEngineTestSupport
import Testing

// T-054 (09 REC-020..022): input monitoring in the engine. The checks are C++
// (Tests/DAWEngineTestSupport/MonitoringChecks.cpp) because they render the engine with a
// hand-made device input in RtScopes and reach the fake driver behind the facade; each asserts
// 0 RT violations (CONV §5.3).

@Suite("Input monitoring (REC-020..022)")
struct MonitoringTests {
    @Test("REC-020: monitoring truth table (off/on/auto × armed × stopped/playing/recording)")
    func truthTable() { expectPasses(daw.testing.monitoringTruthTable()) }

    @Test("REC-020, REC-021: monitored input replaces the clip player's output (no clip leak), crossfades on switches, auto follows the transport; offline renders play the clip")
    func monitorsInputInPlaceOfClip() { expectPasses(daw.testing.engineMonitorsInputInPlaceOfClip()) }

    @Test("REC-021, MIX-023: the pre-roll of a monitored track behind PDC leaks no clip audio")
    func preRollLeaksNoClip() { expectPasses(daw.testing.monitoringPreRollLeaksNoClip()) }

    @Test("REC-022: monitors are validated; the mode is a slot (no new graph), arming is a new description")
    func validatedAndSlot() { expectPasses(daw.testing.monitorsAreValidatedAndModeIsASlot()) }

    @Test("REC-020..022: fake-device loopback: input audible when monitoring, silent when not; mode changes don't rebuild; monitoringLatency = in + out + graph")
    func facadeLoopback() { expectPasses(daw.testing.facadeMonitorsThroughLoopback()) }
}
