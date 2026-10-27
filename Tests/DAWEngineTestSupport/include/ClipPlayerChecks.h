#pragma once
// T-013 checks for the AudioClipPlayer (06 DSP-001, TIME-005/006/008 for timeline nodes, DW-042,
// DW-051), run from Tests/DAWEngineTests/ClipPlayerTests.swift. C++ because they drive the Engine
// (non-movable), GraphBuilder and RtScope. Each renders through the transport with the registered
// built-in nodes and asserts that its render scopes counted 0 RT violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// DSP-001: a clip sounds exactly on [tickToSample(start), tickToSample(end)), reads its asset
// from sourceOffsetSamples with clip gain; mono assets are duplicated to L/R; source frames
// outside the asset are silent.
CheckResult clipPlayerPlacesClips();

// DSP-001: linear fade-in/out in ticks → samples, fades clamped to the clip length; two adjacent
// clips with fades join without a gap or overlap.
CheckResult clipPlayerFades();

// DSP-001, ENG-004: random clips (overlapping, past the asset, negative offsets, missing assets)
// over a tempo map with changes, rendered in random block sizes including 0, match a brute-force
// per-sample oracle, so the binary search finds every clip and placement follows the tempo map.
CheckResult clipPlayerMatchesOracle();

// TIME-005/006: a loop wrap mid-block crossfades the old pass out and the new one in over
// kDeclickFrames; a signal that is the same on both sides of the wrap passes unchanged.
CheckResult clipPlayerLoopWrapCrossfade();

// TIME-008: a locate while playing resets the player (no tail, no fade-in); a stop then play
// starts clean too.
CheckResult clipPlayerLocateResets();

// DW-042, DW-051, IO-031: missing or wrong-rate assets play silence; the player holds its asset
// refs and they go only when the node is reclaimed; clips are fixed per instance, and a
// configVersion bump delivers new ones.
CheckResult clipPlayerAssetsAndClipDelivery();

} // namespace daw::testing
