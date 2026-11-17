#pragma once
// T-092 (DW-232) checks for AUTO-003 in the built-in effects and instruments: at a loop wrap
// inside a block with automation on the node's params, the node reaches this block's values at
// the frame before the wrap and holds the after-wrap values from the wrap frame on, instead of
// ramping across the loop's discontinuity (automation/WrapJump.h). Run from
// Tests/DAWEngineTests/WrapJumpTests.swift. C++ because they drive the nodes directly with
// two-segment TransportBlocks and the ParamSlotTable's after-wrap side channel, in RtScopes; every
// check asserts 0 RT violations (CONV §5.3).
//
// The oracle is exact: before the wrap the node's output is what the pre-wrap values give (an
// identity or dry path), and from the wrap on it is bit-identical to a node that has run at the
// after-wrap values all along (or from its first block, where a node jumps to its slots).

#include "Checks.h"

namespace daw::testing {

// AUTO-003, DSP-030: peak 1 gain 0 → +12 dB at the wrap; a wrap block without a lane ramps the
// whole block as before.
CheckResult wrapJumpEq();
// AUTO-003, DSP-031: threshold and makeup jump at the wrap.
CheckResult wrapJumpCompressor();
// AUTO-003, DSP-032: mix 0 → 1 at the wrap (the echoes from the wrap frame on, the dry signal
// before it); the next block continues at the after-wrap value.
CheckResult wrapJumpDelay();
// AUTO-003, DSP-033: mix 0 → 1 at the wrap.
CheckResult wrapJumpReverb();
// AUTO-003, DSP-022: a note at the wrap frame (the loop start) gets the after-wrap attack.
CheckResult wrapJumpSampler();
// AUTO-003, DSP-011: the loop start's click latches the after-wrap level.
CheckResult wrapJumpMetronome();

} // namespace daw::testing
