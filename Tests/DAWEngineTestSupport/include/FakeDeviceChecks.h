#pragma once
// T-050 checks for FakeDeviceDriver (14 TEST-005), run from
// Tests/DAWEngineTests/FakeDeviceDriverTests.swift. C++ because they own Engines, run a render
// thread, and check every cycle in a DAW_RT tap. Each asserts the driver's IO-cycle RtScopes and
// the engine's render scopes counted 0 violations (CONV §5.3, DW-019). No device needed.

#include "Checks.h"

namespace daw::testing {

// TEST-005: as fast as possible with a cycle limit: parks without rendering at the limit, renders
// exactly the cycles asked for (contiguous output, uneven cycles split into blocks of at most the
// buffer), publishes the configured latency (IO-005), stops and restarts with counters going on.
CheckResult fakeDeviceRunsCycles();

// TEST-005: real-time pacing: N cycles take at least (N − 1) cycle periods of wall-clock time,
// while as-fast-as-possible mode doesn't wait.
CheckResult fakeDevicePacesRealtime();

// TEST-005: with input enabled, input is the output N frames earlier (explicit delay, uneven
// cycles; default delay = input + output latency); silence with loopback off; no input unless
// enabled; a delay shorter than a cycle is rejected.
CheckResult fakeDeviceLoopback();

// TEST-005, IO-020 seam: scripted rate change, processor overload (an xrun) and device loss fall
// on exact frames and come out as DeviceNotifications in order; the lost device stops cycling
// and can't be started, the default output moves; injected events (restore, rate change) apply
// synchronously while running; bad specs and events are rejected; a full queue counts drops.
CheckResult fakeDeviceScriptedEvents();

// TEST-005, DW-070: a realtime EngineFacade runs on FakeDeviceDriverAdapter: the device's thread
// renders the facade's graph and transport, latency reaches telemetry, devices() lists the live
// fake devices, setDevice restarts the fake.
CheckResult fakeDeviceDrivesFacade();

// DW-019: the driver's own IO-cycle RtScope covers the whole cycle, not just Engine::render: a tap
// that allocates on every cycle is counted by rtViolations() (and not by the engine's render
// scopes). Makes deliberate violations, so only the serialized RtTrapTests suite runs it.
CheckResult fakeDeviceCountsCycleViolations();

} // namespace daw::testing
