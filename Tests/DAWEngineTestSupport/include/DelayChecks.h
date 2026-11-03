#pragma once
// T-072 checks for the built-in delay (06 DSP-032, DSP-040, DSP-041; TIME-008, DW-162). Run from
// Tests/DAWEngineTests/DelayTests.swift. C++ because they call DAW_RT process() inside an RtScope
// and drive the Engine; each asserts its scopes counted 0 RT violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// DSP-041: the ParamInfo table (indices, ranges, defaults), published through the facade's
// paramInfoJSON; the note-value table; delay times in frames (ms, synced at several tempos,
// clamping); 0 latency; defaults for slots beyond numParams and for NaN slots, clamping.
CheckResult delayParams();

// DSP-032: the node matches an independent per-sample model of 06's signal path (in double, with
// whole histories instead of rings) on stereo noise bursts, with every param and the tempo
// changing between blocks of random sizes (time crossfades, feedback/mix ramps, mode switches).
CheckResult delayOracle();

// DSP-032: what the params do, on impulses and a sine: echoes at k · T with feedback^(k−1)
// (stereo), alternating sides (ping-pong), ms and synced times, the lowpass darkens only the
// repeats, mix 0 is the input bit for bit, a mono input feeds both sides; a time change
// crossfades the taps over 20 ms without a click or a pitch bend.
CheckResult delayResponse();

// DSP-040, ENG-004, TIME-008: block-size fuzz (random sizes 0 … 4096 match one fixed size bit for
// bit), silence in → exactly 0 out after the tail (no denormals), NaN/Inf guard, echoes ring on
// without an input and across reset(), channels beyond stereo silent.
CheckResult delayRobustness();

// DSP-032, TIME-008, DW-162: NodeKind::delay through registerBuiltinNodes, GraphBuilder and the
// Engine matches the node driven directly; a locate while playing keeps the echoes (forward:
// unchanged; back to the click: the old echoes plus the new ones); a tempo change while playing
// crossfades the synced time to the new tempo.
CheckResult delayThroughEngine();

} // namespace daw::testing
