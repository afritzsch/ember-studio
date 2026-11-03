#pragma once
// T-061 checks for Audio Unit hosting (10 PLUG-010, 012..016), run from
// Tests/DAWEngineTests/AUPluginTests.swift. C++ because they need the Engine/GraphBuilder rig,
// daw.compile, RtScope and the plugin host; Apple's built-in AUs (AUDelay, AUSampler) and a
// test-only AUv3 (FakeAudioUnit.mm, aumf:fAke:Embr) are the plugins. Every check that renders
// asserts its render scopes counted 0 RT violations (CONV §5.3).
//
// The fake's knobs are process-wide (every live fake), so the Swift suite runs serialized.

#include <cstdint>

#include "Checks.h"

namespace daw::testing {

// The test AU: registers it in this process (idempotent); false if the component manager can't
// find it afterwards.
bool registerFakeAudioUnit();
// How many fakes are alive; sets the latency every live fake reports (KVO, PLUG-013); note-ons
// all live fakes have rendered.
int liveFakeAudioUnits();
void setFakeAudioUnitLatency(double seconds);
uint64_t fakeAudioUnitNoteOns();

// PLUG-010: identifiers parse and format like the scanner's (four-character codes, 0x hex), and
// the auPlugin configJSON parses identifier and base64 state (and refuses malformed configs).
CheckResult auIdentifierAndConfig();

// PLUG-010/015: AUDelay as an insert through GraphBuilder + Engine: param slots become render-thread
// parameter events (mix 100 %, 0.25 s, no feedback), so an impulse comes back 12000 frames later
// and nothing before; random block sizes; 0 RT violations.
CheckResult auDelayThroughGraph();

// PLUG-010: MIDI from a MidiClipPlayer reaches the AU through scheduleMIDIEventBlock at the exact
// frame (the fake writes an impulse at each note-on), for random block sizes; AUSampler sounds from
// its note's frame. 0 RT violations.
CheckResult auMidiFrameOffsets();

// PLUG-014: the AU's aux input bus is fed from the node's sidechain port (graph toPort 0, DW-159);
// without a sidechain edge it hears silence. AUDelay has no aux bus. 0 RT violations.
CheckResult auSidechain();

// PLUG-013 / MIX-024: through the facade, a latency change the AU reports (KVO) rebuilds the graph
// on daw.compile: nodeLatencies and the graph latency follow, and PDC delays a parallel dry path
// to match.
CheckResult auLatencyChange();

// PLUG-016: fullState round trip off the RT thread through the facade: a param pushed from a
// slot shows in getPluginState; a new facade restores it from the configJSON state; setPluginState
// restores another; a refused state is a pluginCrashed event; a session-rate change keeps it.
CheckResult auStateRoundTrip();

// PLUG-010/012: a missing AU builds as an absent node (an effect passes through, an instrument is
// silent) and is reported once; a slot keeps its AU across configVersion bumps and param-range
// changes, and gets a new one when the identifier changes; instantiatePlugin parks an AU that the
// build adopts; a state set before the slot had an AU is applied to its first one.
CheckResult auFailureAndAdoption();

} // namespace daw::testing
