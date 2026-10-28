import DAWEngineTestSupport
import Foundation
import Testing

// T-051: DeviceMonitor and the hot-swap sequence (IO-020..022), xrun detection (IO-023) and the
// CoreAudio device listener (IO-020, DW-090). The checks are C++ (Tests/DAWEngineTestSupport/
// DeviceMonitorChecks.cpp): they drive a FakeDeviceDriver's render thread through a recording
// DeviceMonitorHost and spin in DAW_RT nodes. Each asserts 0 RT violations (CONV §5.3).

@Suite("DeviceMonitor hot-swap (IO-020..022)")
struct DeviceMonitorTests {
    @Test("IO-021, IO-022: device loss runs the sequence in order on the monitor's thread; falls back to the default")
    func lossFallsBack() { expectPasses(daw.testing.deviceMonitorLossFallsBack()) }

    @Test("IO-021: a rate change on a device that supports the session rate keeps the session rate")
    func rateChangeKeepsSessionRate() { expectPasses(daw.testing.deviceMonitorRateChangeKeepsSessionRate()) }

    @Test("IO-021: a fallback that can't run the session rate switches the session rate before restarting")
    func fallbackChangesSessionRate() { expectPasses(daw.testing.deviceMonitorFallbackChangesSessionRate()) }

    @Test("IO-021: no device to fall back to is reported; quiet retries; restarts when a device returns")
    func waitsForADevice() { expectPasses(daw.testing.deviceMonitorWaitsForADevice()) }

    @Test("IO-020, IO-021: unrelated notifications change nothing; following the default, a default move swaps")
    func ignoresUnrelated() { expectPasses(daw.testing.deviceMonitorIgnoresUnrelatedNotifications()) }
}

@Suite("Xrun detection (IO-023)")
struct XrunDetectionTests {
    @Test("IO-023, DW-068: render overruns count as xruns after the start grace window, only with a device clock")
    func rendererCountsOverruns() { expectPasses(daw.testing.deviceRendererCountsOverruns()) }

    @Test("IO-023: a deliberately slow node on a real-time fake device shows up as xruns")
    func slowNode() { expectPasses(daw.testing.fakeDeviceSlowNodeCountsXruns()) }
}

@Suite("CoreAudio device listener (IO-020, DW-090)")
struct CoreAudioDeviceListenerTests {
    // Changing the device's nominal rate is audible to whatever else is playing, so that part is
    // opt-in: DAW_DEVICE_EVENT_TESTS=1.
    @Test("IO-020: system and device listeners register; opt-in: a rate change is notified")
    func reportsChanges() {
        let env = ProcessInfo.processInfo.environment
        let flip = env["DAW_DEVICE_EVENT_TESTS"] == "1" && env["DAW_SKIP_DEVICE_TESTS"] != "1"
        expectPasses(daw.testing.coreAudioListenerReportsChanges(flip))
    }
}
