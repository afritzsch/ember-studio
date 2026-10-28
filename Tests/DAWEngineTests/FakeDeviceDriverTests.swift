import DAWEngineTestSupport
import Testing

// T-050: FakeDeviceDriver (TEST-005). The checks are C++ (Tests/DAWEngineTestSupport/
// FakeDeviceChecks.cpp): they run the driver's render thread and check every cycle in a DAW_RT
// tap. Each asserts that the IO cycles' RtScopes and the engine's render scopes counted 0
// violations (CONV §5.3). Fast mode plus a cycle limit keeps them deterministic; only the pacing
// check runs in real time (about 0.1 s).

@Suite("FakeDeviceDriver (TEST-005)")
struct FakeDeviceDriverTests {
    @Test("TEST-005: renders exactly the cycles asked for, uneven cycles in buffer-size blocks; latency published (IO-005); stop/restart")
    func runsCycles() { expectPasses(daw.testing.fakeDeviceRunsCycles()) }

    @Test("TEST-005: real-time pacing follows the device clock; as-fast-as-possible doesn't wait")
    func pacesRealtime() { expectPasses(daw.testing.fakeDevicePacesRealtime()) }

    @Test("TEST-005: loopback: input is the output N frames earlier (explicit or input + output latency); off → silence")
    func loopback() { expectPasses(daw.testing.fakeDeviceLoopback()) }

    @Test("TEST-005, IO-020 seam: scripted rate change, overload and device loss on exact frames, notified in order; injected events")
    func scriptedEvents() { expectPasses(daw.testing.fakeDeviceScriptedEvents()) }

    @Test("TEST-005, DW-070: a realtime EngineFacade runs on FakeDeviceDriverAdapter")
    func drivesFacade() { expectPasses(daw.testing.fakeDeviceDrivesFacade()) }
}

#if DEBUG  // the trap exists only in Debug (BUILD-005)
// Deliberate violations belong to the serialized RtTrapTests suite (14-testing, "C++ unit tests").
extension RtTrapTests {
    @Suite("TEST-005: the fake device's IO cycle counts violations")
    struct FakeDeviceViolationTests {
        @Test("DW-019: an allocating tap in the IO cycle is counted by the driver's own scope, not the engine's")
        func allocatingTapCounted() { expectPasses(daw.testing.fakeDeviceCountsCycleViolations()) }
    }
}
#endif
