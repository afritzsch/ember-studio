#pragma once
// T-020 checks for sends (05 MIX-007): the GainNode (NodeKind::gain, one smoothed level slot) and
// pre/post-fader sends built from it through registerBuiltinNodes, GraphBuilder and the Engine.
// Run from Tests/DAWEngineTests/SendTests.swift. C++ because they call DAW_RT process() inside an
// RtScope and drive the Engine; each asserts its scopes counted 0 RT violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// MIX-007, ENG-022, ENG-004: the level is linear, clamped to 0 … +12 dB (NaN → 0), applied to
// every channel, ramped per block from the previous block's end; the first block doesn't ramp;
// 0-frame blocks keep the ramp state; random block sizes 0 … 4096 stay continuous.
CheckResult gainNodeLevel();

// MIX-007 through the Engine: clip player → insert (gain) → strip → master, with a post-fader
// send (strip → gain → bus) and a pre-fader send (insert → gain → bus), bus → master. The
// post-fader send follows the strip's fader, pan, mute and phase; the pre-fader send ignores all
// of them; send levels, fader and mute are slot writes with no rebuild, each ramped over one
// block. A gain node without a param is rejected.
CheckResult sendsPreAndPostFader();

} // namespace daw::testing
