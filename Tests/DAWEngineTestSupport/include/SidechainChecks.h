#pragma once
// T-023 checks for sidechain edges and ports (05 MIX-008, keeping MIX-004 and MIX-021 green),
// run from Tests/DAWEngineTests/SidechainTests.swift. The built-in compressor that MIX-008's
// golden needs is T-071, so a test-only node stands in for it: SidechainMixNode (TestNodes.h,
// TEST-004 style), out = in + level · sidechain, registered under NodeKind::compressor. C++
// because they need the NodePool/Engine (non-movable), DAW_RT test nodes, daw.compile and
// RtScope; every check that renders asserts its render scopes counted 0 RT violations
// (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// TEST-004 / MIX-008: SidechainMixNode adds level · sidechain per channel, passes the main input
// alone when the sidechain is empty (or lacks a channel), treats an empty main input as silence,
// and counts routed blocks; registered under compressor through TestNodeSpec. 0 RT violations.
CheckResult sidechainMixNode();

// MIX-008 / MIX-004 / ENG-003: through GraphBuilder + Engine, a node's NodeIO sidechain is empty
// when no sidechain edge reaches it and otherwise carries the sum of every sidechain edge into
// it, separate from the main input: a source read directly, one that fans out (fed), several
// summed, one through a bus, the same producer on both ports, a node with only a sidechain, one
// source keying two nodes. toPort != 0 is rejected (invalidArgument).
CheckResult sidechainPortDelivery();

// MIX-008: pre/post-fader tap with real channel strips and clip players. The sidechain edge
// starts at the node feeding the source's strip (pre) or at the strip (post), as
// GraphDescriptionBuilder emits it (MODEL-020): post follows the source's fader, mute, phase and
// pan; pre ignores them. Switching the tap is a rebuild that keeps the keyed node's instance.
CheckResult sidechainPreAndPostFaderTap();

// MIX-021 on sidechain merges, with the test node: a latent main path against a dry sidechain,
// a latent sidechain against a dry main, and a sidechain summed from a latent and a dry path,
// each nulled exactly (level −1 / −0.5) for random block sizes; the graph latency is the
// latent path's.
CheckResult sidechainPdcAlignment();

// MIX-003 with sidechain ports: a symbolic run of planBuffers over random DAGs with many
// sidechain edges (some delayed, MIX-021) proves no buffer is overwritten between the feed into
// a main or sidechain port and the step that reads it, that every edge arrives, and that direct
// reads stay intact; plus a rendered shape whose sidechain must survive a long chain.
CheckResult sidechainBufferLiveness();

// MIX-008 across rebuilds: GraphCompiler (daw.compile) adds, moves and removes a sidechain edge
// while the engine renders; the keyed node keeps its instance and sees an empty port again once
// the edge is gone. MIX-022 for a delayed sidechain edge: an unrelated structural rebuild
// during playback is bit-identical to no rebuild; a renamed edge (the control) starts silent.
CheckResult sidechainRebuild();

// MIX-008 end to end through the facade (BRIDGE, offline export): a GraphDescription laid out
// exactly as GraphDescriptionBuilder emits a project with SetSidechain (track A's tap → an insert
// on track B, through the master bus and strip) renders with the test node under compressor
// (makeTestFacade): pre-fader keys from a muted track, post-fader doesn't; rtViolations 0.
CheckResult sidechainThroughFacade();

} // namespace daw::testing
