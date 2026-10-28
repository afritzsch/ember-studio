#pragma once
// T-051 checks for DeviceMonitor (IO-020..022), xrun detection (IO-023) and
// CoreAudioDeviceListener (IO-020, DW-090), run from Tests/DAWEngineTests/DeviceMonitorTests.swift.
// C++ because they own Engines and FakeDeviceDrivers, run render threads and spin in DAW_RT nodes.
// The hot-swap checks drive a real FakeDeviceDriver through a recording DeviceMonitorHost, and
// every one asserts 0 RT violations from the driver's cycle scopes and the engine's render scopes
// (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// IO-021, IO-022: an explicitly chosen device is lost while playing and recording. The sequence
// runs in order (stop transport, finalize recordings, stop driver, restart on the system default
// at the session rate, report deviceLost), once for the three notifications, on the monitor's
// thread rather than the render thread; the fallback renders and the request now follows the
// default.
CheckResult deviceMonitorLossFallsBack();

// IO-021 (5): another app changes the running device's rate. The device supports the session
// rate, so the session keeps it: restart on the same device at the session rate, no session rate
// change, reason sampleRateChanged.
CheckResult deviceMonitorRateChangeKeepsSessionRate();

// IO-021 (5): the fallback device can't run at the session rate, so the session switches to the
// rate it runs at before the driver restarts.
CheckResult deviceMonitorFallbackChangesSessionRate();

// IO-021: the only device is lost, so there is nothing to fall back to (reported with notFound);
// a retry that still finds none stays quiet; once the device comes back it starts again
// (deviceAvailable).
CheckResult deviceMonitorWaitsForADevice();

// IO-020/021: notifications that don't concern the running device change nothing (overloads,
// other devices, the rate the driver runs at, a default move while a device is chosen, anything
// while the device isn't wanted); following the default, a default move swaps devices.
CheckResult deviceMonitorIgnoresUnrelatedNotifications();

// IO-023, DW-068: DeviceRenderer counts a cycle whose render outlasts its audio as an overrun and
// a telemetry xrun, but not during the start grace window, nor without a device clock; fast
// cycles don't count.
CheckResult deviceRendererCountsOverruns();

// IO-023: the acceptance test: a deliberately slow node on a real-time paced FakeDeviceDriver
// shows up as overruns and xruns.
CheckResult fakeDeviceSlowNodeCountsXruns();

// IO-020, DW-090: CoreAudioDeviceListener adds the system listeners and watches the default
// output device (skipped without one). With `flipRate` (opt-in: it changes the device's rate for
// a moment) it sets another nominal rate and expects a nominalRateChanged notification, then
// restores the rate.
CheckResult coreAudioListenerReportsChanges(bool flipRate);

} // namespace daw::testing
