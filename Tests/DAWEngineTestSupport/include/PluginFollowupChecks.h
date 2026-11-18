#pragma once
// T-097 checks for the hosted-plugin follow-ups (10 "Contract delta (T-097)"), run from
// Tests/DAWEngineTests/PluginFollowupTests.swift. Plugins: EmberTest (Tests/VST3TestPlugin, built by
// scripts/build-test-vst3.sh), the fake AUv3 (FakeAudioUnit.mm) and Apple's AUDelay. Their knobs and
// counters are process-wide, so the Swift suite is serialized. Every check that renders asserts its
// render scopes counted 0 RT violations (CONV §5.3).

#include <cstdint>

#include "Checks.h"

namespace daw::testing {

// DW-242 / DW-063: a VST3 effect's tail (EmberTest's delay ring) is gone after a reset. Control:
// without one the tail plays. The export path (VST3PluginHost::resetAll on the non-RT thread, then
// the engine's reset-all) clears it before the first block, deterministically; the fallback (the
// engine's reset-all alone) never waits on the render thread, renders the plugin as absent until
// the reset worker is done, and plays no tail either.
CheckResult vst3ResetClearsTail();

// DW-242: the same for AUs: the fake AU's delay line (its -reset clears it) on both paths, and
// Apple's AUDelay (a V2 unit: AudioUnitReset through the bridge) on the export path, whose pending
// echo doesn't come.
CheckResult auResetClearsTail();

// DW-242 / DW-211 through the facade: an offline engine prepares VST3 plugins in kOffline mode
// (setupProcessing and every process call) and an AU with renderingOffline; each export resets
// every hosted plugin once before its first block (a setActive cycle; the fake AU's -reset). A
// realtime builder (no PrepareInfo::offline) prepares kRealtime.
CheckResult pluginOfflineModeAndExportReset(bool au);  // the AU half (builder only) or the VST3 half

// DW-233 / AUTO-003: in a block where automation wraps, a VST3 parameter gets the block's value at
// offset 0, held up to the frame before the wrap and the after-wrap value at the wrap frame
// (EmberTest's point log); an AU (the fake, which applies events at their frame) jumps at exactly
// the wrap frame. 0 RT violations.
CheckResult pluginWrapJump(bool au);  // the AU half or the VST3 half

// DW-210: VST3 MIDI CC, channel aftertouch and pitch bend become points of the parameters the
// plugin maps them to (IMidiMapping) at their frames; unmapped controllers and channels are
// dropped; the controller follows the mapped value. 0 RT violations.
CheckResult vst3MidiMapping();

// DW-225: bypassing an instrument plugin that holds a note sends the note-off (and CC 123 on its
// channel: raw for AU, through the mapping for VST3) in its last processed block; notes that end
// while bypassed send nothing more, and enabling it again sends nothing. VST3 (EmberTest synth)
// and AU (the fake). 0 RT violations.
CheckResult pluginBypassReleasesNotes(bool au);  // the AU half or the VST3 half

// DW-218 audit: a VST3 instance destroyed while its latency timer is active (restartComponent from
// this thread and from process()) is torn down on the destroying thread, every time: EmberTest's
// processor count drops as the instance goes, never later on the timer's thread. `iterations`.
CheckResult vst3TeardownVsLatencyTimer(uint32_t iterations);

// DW-217 audit: one thread instantiates and destroys V2 AUs (AudioComponentInstanceNew, outside the
// lifecycle lock) while another instantiates, prepares (AudioUnitInitialize), renders and destroys
// (AudioUnitUninitialize) them, `iterations` times each: no abort, no render error, every bridge
// released.
CheckResult auInstantiateVsLifecycle(uint32_t iterations);

} // namespace daw::testing
