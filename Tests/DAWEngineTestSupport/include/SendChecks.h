#pragma once
// T-020 checks for sends (05 MIX-007): the GainNode (NodeKind::gain, one smoothed level slot) and
// pre/post-fader sends built from it through registerBuiltinNodes, GraphBuilder and the Engine.
// Run from Tests/DAWEngineTests/SendTests.swift. C++ because they call DAW_RT process() inside an
// RtScope and drive the Engine; each asserts its scopes counted 0 RT violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// MIX-007, ENG-022, ENG-004: the level is linear, clamped to 0 … +12 dB (NaN → 0), applied to
// every channel, ramped per block from the previous block's end; the mute slot (1) fades over one
// block, on at ≥ 0.5, NaN off; a plain gain (numParams 1) reads no mute slot; the first block
// doesn't ramp; 0-frame blocks keep the ramp state; random block sizes 0 … 4096 stay continuous.
CheckResult gainNodeLevel();

// MIX-007 through the Engine: clip player → insert (plain gain) → strip → master, with a
// post-fader send (strip → gain → bus) and a pre-fader send (insert → gain → bus), bus → master.
// The post-fader send follows the strip's fader, pan and phase; the pre-fader send doesn't; send
// levels and the fader are slot writes with no rebuild, each ramped over one block. A gain node
// without a param is rejected.
CheckResult sendsPreAndPostFader();

// MIX-007, MIX-006 (strip/send side): a muted track (strip slot 2 + every send's slot 1, as the
// model writes it) silences the strip and both its pre- and post-fader sends, ramped over one
// block; unmuting fades both back in without a click. The strip slot alone leaves the pre-fader
// send open.
CheckResult sendsMutedWithTrack();

} // namespace daw::testing
