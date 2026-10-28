#pragma once
// T-051 checks for the facade's device handling (08 T-051 delta; IO-020..023, DW-079, DW-089),
// run from Tests/DAWEngineTests/FacadeDeviceTests.swift. C++ because they reach the fake driver
// behind the facade (FakeDeviceDriverAdapter) for its cycle RtScopes' violation count. Every check
// asserts that count and the engine's render scopes are 0 (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// IO-021 through the facade (DeviceDriverKind::fake): losing Fake Device A while playing falls
// back to Fake Device B, which runs only at 44.1 kHz, so the session rate changes. The graph is
// rebuilt at it (new version), the transport is stopped at the same tick, telemetry shows device
// 2 at 44.1 kHz, and a deviceChanged event says deviceLost 1 → 2, 48 → 44.1 kHz.
CheckResult facadeDeviceLossFallsBack();

// IO-021 (5): a rate change on the running device that supports the session rate restarts it at
// the session rate (sampleRateChanged, same device, same rate, same graph).
CheckResult facadeRateChangeKeepsSessionRate();

// IO-021: with both fake devices lost the event carries notFound and nothing runs; a returning
// device starts again (deviceAvailable). The reaction also happens on daw.device by itself: a
// scripted loss (no simulateDeviceEvent) produces the event within a poll or two.
CheckResult facadeWaitsForDeviceAndPollsOnItsOwn();

// IO-023, T-051 telemetry: a simulated processor overload is an xrun, counted in
// processorOverloads, and raises an overload event; outputDeviceID names the running device.
// DW-089: simulateDeviceEvent is unsupported off the fake driver, rejects unknown devices.
CheckResult facadeDeviceTelemetryAndSimulation();

// DW-079: setDevice with another rate changes the session rate (graph rebuilt at it, waits on
// earlier versions return at once); rate 0 keeps the session rate when the device supports it,
// else takes the device's; a rate that isn't a session rate or the device can't do, or another
// driver kind, is refused before anything stops.
CheckResult facadeSetDeviceChangesSessionRate();

} // namespace daw::testing
