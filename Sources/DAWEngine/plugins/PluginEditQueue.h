#pragma once
// PLUG-015 second half, DW-204 (T-063): edits a hosted plugin makes itself (its editor's knobs:
// VST3 IComponentHandler::beginEdit/performEdit/endEdit, an AU's parameter automation events
// Touch/Value/Release), on their way to the model. Instances push here from whatever thread the
// plugin calls on (its UI thread, an AU's notification queue), never from the audio thread; the
// facade drains the queue into `pluginParamEdited` events when it is polled (BRIDGE-004), and the
// model turns each begin…end into one undoable SetParam gesture (MODEL-003).
//
// A `value` outside any begin…end is an ungestured edit (a menu, a preset); the model groups those
// per poll. Consecutive values of one parameter of one slot coalesce into the newest, so a fast
// drag between two polls costs one entry, and the queue stays bounded: past `kCapacity` entries the
// oldest are dropped (and counted).
//
// Threads: any (one mutex), non-RT.

#include <cstddef>
#include <cstdint>
#include <deque>
#include <mutex>
#include <vector>

#include "core/Result.h"  // NodeID

namespace daw {

// Mirrors daw::PluginEditPhase (daw/EngineFacade.h); the facade maps one onto the other.
enum class PluginEditKind : uint8_t { begin, value, end };

struct PluginParamEdit {
    NodeID slot = 0;
    uint32_t index = 0;  // the parameter's index in pluginInfoJSON's params (= its param slot)
    float value = 0;     // value: AU in its own range, VST3 normalized; begin/end: the current value
    PluginEditKind phase = PluginEditKind::value;
};

class PluginEditQueue {
public:
    static constexpr std::size_t kCapacity = 4096;

    void push(const PluginParamEdit& edit);
    std::vector<PluginParamEdit> take();
    uint64_t dropped() const;

private:
    mutable std::mutex mutex_;
    std::deque<PluginParamEdit> edits_;
    uint64_t dropped_ = 0;
};

} // namespace daw
