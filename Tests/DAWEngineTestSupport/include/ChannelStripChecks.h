#pragma once
// T-013 checks for the ChannelStrip's gain and pan (06 DSP-010, 05 MIX-005, ENG-022) and its
// 300 ms meter window (MIX-005, DW-048, strip side), run from
// Tests/DAWEngineTests/ChannelStripTests.swift. C++ because they call DAW_RT process() inside an
// RtScope and drive the Engine; each asserts its scopes counted 0 RT violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// MIX-005: −3 dB constant-power pan law: hard left (1, 0), centre (√½, √½), hard right (0, 1),
// gL² + gR² = 1 everywhere; gain is linear and clamped to 0 … +12 dB; pan clamped to −1 … 1.
CheckResult channelStripPanLaw();

// ENG-022: gain and pan read once per block and ramped linearly from the previous block's end;
// the last frame is exact, the first block after prepare doesn't ramp, a 0-frame block keeps
// the ramp state.
CheckResult channelStripSmoothing();

// MIX-005 (strip side of DW-048): peak and RMS over the last 300 ms, written to Telemetry.
CheckResult channelStripMeter();

// DSP-001 + DSP-010 through registerBuiltinNodes and the Engine: clip player → strip → master
// with pan/gain slot changes; a strip with fewer than 2 params is rejected.
CheckResult channelStripThroughEngine();

} // namespace daw::testing
