import DAWEngineTestSupport
import Testing

// T-014: EngineFacade checks that need C++ (Tests/DAWEngineTestSupport/FacadeChecks.cpp): a fake
// DriverAdapter rendering on demand, DAW_RT test nodes, facade internals. Everything that
// renders asserts its RtScope counted 0 violations (CONV §5.3). The Swift-facing behaviour is
// tested through EngineClient in Tests/DAWModelTests/EngineClientTests.swift.

@Suite("EngineFacade (C++)")
struct FacadeTests {
    @Test("ENG-023, DW-027: a 1000-step fader sweep reaches the audio thread and publishes no graph")
    func paramSweep() { expectPasses(daw.testing.facadeParamSweepPublishesNothing()) }

    @Test("DW-029: freed ParamIDs are reused only after the graphs reading them stop rendering")
    func deferredFree() { expectPasses(daw.testing.facadeDeferredParamFree()) }

    @Test("DW-057, DW-064, DW-056, BRIDGE-002: export pauses the device, disarms recording, reports through pollJob")
    func exportPausesDevice() { expectPasses(daw.testing.facadeExportPausesDevice()) }

    @Test("DW-050: ErrorCode::cycle crosses as FacadeErrorCode::cycle with the NodeIDs")
    func errorMapping() { expectPasses(daw.testing.facadeErrorMapping()) }

    @Test("BRIDGE-008: realtime mode drives a DriverAdapter; setDevice restarts it; no driver → no devices")
    func driverSeam() { expectPasses(daw.testing.facadeRealtimeDriverSeam()) }
}
