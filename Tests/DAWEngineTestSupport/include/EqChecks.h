#pragma once
// T-070 checks for the built-in EQ (06 DSP-030, DSP-040, DSP-041) and the node registry's param
// tables (DSP-041) plus the NaN telemetry counter (DSP-040, DW-142). Run from
// Tests/DAWEngineTests/EqTests.swift. C++ because they call DAW_RT process() inside an RtScope and
// drive the Engine; each asserts its scopes counted 0 RT violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// DSP-041: the EQ's ParamInfo table; NodeRegistry::paramInfo for every built-in kind that has a
// table (strip, gain, compressor, delay, reverb, metronome, sampler, eq) and paramInfoJSON
// reading it; defaults for slots beyond numParams and for NaN slots, clamping; a default EQ is
// exactly flat (bit for bit); 0 latency.
CheckResult eqParams();

// DSP-030: the frequency response of every band type and of the whole chain against the analytic
// RBJ response, within 0.1 dB, at 44.1/48/88.2/96 kHz, up to 30 Hz below Nyquist.
CheckResult eqResponse();

// DSP-030: coefficient changes don't click or blow up: gain and frequency sweeps in several block
// sizes stay within a slew bound, a full-range step in one block stays finite and bounded and
// settles on the new response, and a changing band keeps its TDF-II state.
CheckResult eqSweep();

// DSP-040, ENG-004: block-size fuzz bit-exact, silence → exact 0 after the tail, NaN/Inf guard
// clears the filter state, mono and missing inputs, RT trap 0.
CheckResult eqRobustness();

// DSP-030, DSP-040, DW-142: a registered NodeKind::eq through GraphBuilder and the Engine, 0
// latency; a NaN through the EQ, compressor, reverb and delay reaches Telemetry::nanBlocks and
// the facade's TelemetryPOD.
CheckResult eqThroughEngine();

} // namespace daw::testing
