#pragma once
// T-073 checks for the built-in reverb (06 DSP-033, DSP-040, DSP-041; IO-011). Run from
// Tests/DAWEngineTests/ReverbTests.swift. C++ because they call DAW_RT process() inside an
// RtScope and drive the Engine; each asserts its scopes counted 0 RT violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// DSP-041: the ParamInfo table (indices, ranges, defaults), published through the facade's
// paramInfoJSON; 0 latency; defaults for slots beyond numParams and for NaN slots, clamping.
CheckResult reverbParams();

// DSP-033: the node matches an independent per-sample model of 06's signal path (written from
// the spec text, in double, with the Hadamard product as a matrix) on noise bursts, with every
// param changing between blocks of random sizes (size/pre-delay glides, decay/mix ramps).
CheckResult reverbOracle();

// DSP-033: what the params do, measured on impulse responses: the first wet sample arrives at
// pre-delay + the shortest line; the low-frequency RT60 (Schroeder decay curve) is the decay
// param; damping shortens the high-frequency tail; size lengthens the lines; L/R are
// decorrelated; mix 0 is the input bit for bit, mix 1 has no dry; a mono input feeds both sides.
CheckResult reverbResponse();

// DSP-040, ENG-004, TIME-008: block-size fuzz (random sizes 0 … 4096 match one fixed size bit for
// bit), silence in → exactly 0 out after the tail (no denormals), NaN/Inf guard, the tail rings
// on without an input and across reset().
CheckResult reverbRobustness();

// DSP-033, IO-011, TIME-008: NodeKind::reverb through registerBuiltinNodes, GraphBuilder and the
// Engine matches the node driven directly; two fresh engines render the same bits; a locate
// while playing keeps the tail.
CheckResult reverbThroughEngine();

} // namespace daw::testing
