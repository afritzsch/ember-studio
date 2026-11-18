#pragma once
// T-099 checks for the telemetry counters of 08 "Contract delta (T-099)" (EngineCounterChecks.cpp),
// run from Tests/DAWEngineTests/EngineCounterTests.swift. They're C++ because they need Engine,
// test nodes with DAW_RT bodies and the facade's fake device driver. Every render counts 0 RT
// violations.

#include "Checks.h"

namespace daw::testing {

// DW-083: the master's MIX-009 limiter overs reach Telemetry::clippedSamples, equal to the node's
// own count, and keep adding up when the master node is replaced (all masters since the engine
// was created). With the limiter off nothing counts.
CheckResult masterClipsCountIntoTelemetry();

// DW-170: events a MIDI edge's MidiDelayLine drops under its overflow policy reach
// Telemetry::midiEventsDropped, summed by Engine::render: every event the source wrote either
// arrives or is counted, exactly once, also across a rebuild that carries the line over.
CheckResult midiDelayLineDropsCountIntoTelemetry();

// DW-192: TelemetryPOD.bufferFrames is the running device's buffer (the fake device's 256, then
// 128 after setDevice), 0 once no device runs and in offline mode.
CheckResult facadeReportsDeviceBufferFrames();

} // namespace daw::testing
