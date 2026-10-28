import DAWEngineTestSupport
import Testing

// T-051: the facade's device handling (08 T-051 delta): IO-021 through DeviceMonitor's facade host
// on the fake driver (DW-089), session-rate changes (IO-021 (5), DW-079), device telemetry
// (IO-023). The checks are C++ (Tests/DAWEngineTestSupport/FacadeDeviceChecks.cpp) to reach the
// fake driver's RT-violation count behind the facade; each asserts 0 (CONV §5.3).

@Suite("Facade devices (IO-020..023, T-051)")
struct FacadeDeviceTests {
    @Test("IO-021: losing the device falls back to the default; a fallback that can't run the session rate changes it and rebuilds the graph")
    func lossFallsBack() { expectPasses(daw.testing.facadeDeviceLossFallsBack()) }

    @Test("IO-021 (5): a rate change on a device that supports the session rate keeps it")
    func rateChangeKeepsSessionRate() { expectPasses(daw.testing.facadeRateChangeKeepsSessionRate()) }

    @Test("IO-021, IO-022: no device → notFound; a returning device starts (deviceAvailable); daw.device reacts on its own")
    func waitsForDevice() { expectPasses(daw.testing.facadeWaitsForDeviceAndPollsOnItsOwn()) }

    @Test("IO-023, DW-089: simulated overload counted as processorOverloads + overload event; fake driver via create; unsupported offline")
    func telemetryAndSimulation() { expectPasses(daw.testing.facadeDeviceTelemetryAndSimulation()) }

    @Test("DW-079: setDevice with another rate changes the session rate; rate 0 keeps it when the device can; bad requests refused up front")
    func setDeviceChangesSessionRate() { expectPasses(daw.testing.facadeSetDeviceChangesSessionRate()) }
}
