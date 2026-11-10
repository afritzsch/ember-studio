#pragma once
// T-062 checks for VST3 hosting (10 PLUG-011..016), run from Tests/DAWEngineTests/VST3PluginTests.swift.
// C++ because they need the Engine/GraphBuilder rig, daw.compile, RtScope and the plugin host. The
// plugins are real .vst3 bundles built by scripts/build-test-vst3.sh: the SDK's `again` sample and
// EmberTest (Tests/VST3TestPlugin), whose exported knobs are process-wide, so the suite is serialized.
// Every check that renders asserts its render scopes counted 0 RT violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// PLUG-011: the "path#classUID" identifier and the vst3Plugin configJSON parse and round trip.
CheckResult vst3IdentifierAndConfig();

// PLUG-011/015: the SDK `again` sample as an insert through GraphBuilder + Engine: a param slot
// becomes one point per block at offset 0 and the output is exactly input × the gain, including
// after a slot change; read-only parameters aren't pushed; 0 RT violations with random block sizes.
CheckResult vst3AgainThroughGraph();

// PLUG-011: notes from a MidiClipPlayer reach the plugin as note on/off events at their exact frame
// offsets, for random block sizes; 0 RT violations.
CheckResult vst3NoteFrameOffsets();

// PLUG-011: the ProcessContext carries the transport: tempo, ppq position, bar position, time
// signature, playing flag.
CheckResult vst3ProcessContext();

// PLUG-014: the aux input bus is fed from the node's sidechain port, silence without one.
CheckResult vst3Sidechain();

// PLUG-013 / MIX-024: restartComponent(kLatencyChanged) rebuilds the graph and PDC stays aligned,
// whether the plugin calls it on a main thread or on the audio thread (0 RT violations).
CheckResult vst3LatencyChange();

// PLUG-016: component + controller state round trip through the facade, off the RT thread;
// setComponentState reaches the controller on restore; a refused state is a pluginCrashed event;
// a session-rate change keeps the state.
CheckResult vst3StateRoundTrip();

// PLUG-011/012: a missing plugin renders as absent and is reported once; slots keep their instance
// across configVersion bumps; a new identifier is a new instance; instantiatePlugin parks an
// instance the build adopts; a state set before the slot had one is applied to its first one.
CheckResult vst3FailureAndAdoption();

// T-064, PLUG-022: a plugin writing NaN is silenced block by block, counted in telemetry nanBlocks,
// and reported once per node instance (VST3PluginHost::takeMisbehaved; a pluginMisbehaved event
// through the facade); it plays again once it recovers. 0 RT violations.
CheckResult vst3NanGuard();

// T-064, PLUG-018: EmberTest (latency 480, gain 0) host-bypassed: the graph keeps its latency and
// the output nulls against the input on the timeline; slot writes toggle it with no new instance
// and the plugin's state unchanged. 0 RT violations.
CheckResult vst3HostBypass();

} // namespace daw::testing
