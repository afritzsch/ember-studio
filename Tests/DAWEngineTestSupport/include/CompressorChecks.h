#pragma once
// T-071 checks for the built-in compressor (06 DSP-031, DSP-040, DSP-041; MIX-008 sidechain).
// Run from Tests/DAWEngineTests/CompressorTests.swift. C++ because they call DAW_RT process()
// inside an RtScope and drive the Engine; each asserts its scopes counted 0 RT violations
// (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// DSP-041: the ParamInfo table (indices, ranges, defaults), published through the facade's
// paramInfoJSON; the registry entry meters; 0 latency; defaults for slots beyond numParams and
// for NaN slots, clamping.
CheckResult compressorParams();

// DSP-031: the static curve. A settled constant key at every level −80 … +6 dB, for a grid of
// thresholds, ratios and knees (hard and soft), gives the gain the threshold/ratio/knee formula
// states, with both detectors; the curve is continuous and monotonic, makeup adds exactly.
CheckResult compressorStaticCurve();

// DSP-031: attack and release ballistics against an independent per-sample oracle (peak and RMS
// detectors, a key stepping above and below threshold, param changes ramped per block).
CheckResult compressorBallistics();

// DSP-031, MIX-008: a routed sidechain keys the detector and the input doesn't; without one the
// input keys itself; stereo-linked (one gain for both channels, keyed by either).
CheckResult compressorSidechain();

// DSP-040, ENG-004: block-size fuzz (random sizes 0 … 4096 match one fixed size bit for bit),
// silence in → silence out with the envelope settling to exactly 0 dB, NaN/Inf guard.
CheckResult compressorRobustness();

// DSP-031, MIX-008, DW-096: NodeKind::compressor through registerBuiltinNodes, GraphBuilder and
// the Engine, keyed by a sidechain edge from another clip player; the gain-reduction meter in
// Telemetry; 0 latency.
CheckResult compressorThroughEngine();

} // namespace daw::testing
