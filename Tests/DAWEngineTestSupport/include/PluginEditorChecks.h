#pragma once
// T-063 checks for plugin editors (10 PLUG-017, DW-208) and plugin-side parameter edits (PLUG-015
// second half, DW-204), run from Tests/DAWEngineTests/PluginEditorTests.swift. Objective-C++
// (PluginEditorChecks.mm), since editors are NSViews. The VST3 plugin is EmberTest
// (Tests/VST3TestPlugin, its own IPlugView); the AU is Apple's AUDelay. The view checks must run
// on the main thread (the facade's editor calls are main-thread only).

#include <string>

#include "Checks.h"

namespace daw::testing {

// DW-204, VST3: EmberTest's controller edits (beginEdit/performEdit/endEdit) become
// pluginParamEdited events (begin, one coalesced value, end; an ungestured value alone; unknown
// parameters and unbalanced ends dropped). The controller keeps the editor's value while the model
// is behind it (gesture open, or until the model echoes it, ≤ 1 s), then follows the model again
// (pluginInfoJSON, VST3Instance::syncEditor). 0 RT violations.
CheckResult vst3PluginEditsBecomeEvents();

// PLUG-017 / DW-208, VST3, main thread: createPluginView attaches EmberTest's IPlugView to a
// container NSView of its size; a second call returns the same view; off the main thread it is
// null. IPlugFrame::resizeView resizes the container (pluginViewJSON follows); resizing the
// container from outside goes through checkSizeConstraint/onSize. A rate change replaces the
// instance: the editor reports stale, and opening again shows the new one. destroyPluginView and
// the facade's end release the view.
CheckResult vst3EditorView();

// PLUG-017, AU, main thread, in two halves around the main queue (the view controller arrives
// there): auEditorBegin opens AUDelay's editor; the Swift test waits until pluginViewJSON says
// "ready"; auEditorFinish checks it (custom or generic view, a size) and closes it.
bool auEditorBegin();
std::string auEditorJSON();
CheckResult auEditorFinish();

// DW-204, AU: AUDelay's parameter automation events (Touch, Value, Release, as an editor sends
// them) become begin/value/end edits of the slot; a plain value change is an ungestured edit. The
// node doesn't push a gesture's parameter, holds the plugin's value after a release until the model
// matches it (or 300 ms pass), and the echo of a host push isn't an edit. 0 RT violations.
CheckResult auPluginEditsBecomeEvents();

// DW-276 (T-094): a V2 bridge replacing its parameter tree after the instance last looked (a bus
// format set straight on the unit) doesn't strand the edit observer: a Touch on the new tree is
// heard (the instance follows `parameterTree` by KVO).
CheckResult auEditsFollowTreeSwap();

} // namespace daw::testing
