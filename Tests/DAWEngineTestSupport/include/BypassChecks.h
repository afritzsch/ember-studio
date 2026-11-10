#pragma once
// T-064 checks for host-side bypass (10 PLUG-018): GraphBuilder's BypassNode around any node with
// a NodeDesc::bypassParam. Run from Tests/DAWEngineTests/BypassTests.swift. C++ because they need
// GraphBuilder, the NodePool, DAW_RT test nodes and RtScope. Every check that renders asserts its
// render scopes counted 0 RT violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// PLUG-018: a latent effect (latency 700, output × 0) bypassed vs a plain phase-inverted copy of
// the same signal nulls exactly, with random block sizes; the graph latency is the same bypassed
// or not; un-bypassing (a slot write, no rebuild) brings the effect back; the wrapped node is
// neither processed while bypassed nor ever re-created; 0 RT violations.
CheckResult bypassLatentNull();

// PLUG-018: a toggle is a one-block linear crossfade; a rebuild while bypassed (the same
// description again, or with another node added) carries the delay line over bit-identically; a
// grown latency gets a new line and still aligns; an unallocated bypass slot is rejected.
CheckResult bypassCrossfadeAndRebuild();

} // namespace daw::testing
