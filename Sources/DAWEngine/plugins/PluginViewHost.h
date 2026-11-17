#pragma once
// PLUG-017 (T-063): a facade's open plugin editors, one per device slot. Plain C++ API over an
// Objective-C++ implementation (PluginViewHost.mm), so the facade never sees AppKit types.
//
// Each editor is a container NSView the facade owns (the app puts it in a floating panel):
//   - AU: `requestViewController`; a unit without one gets CoreAudioKit's AUGenericViewController.
//     The controller arrives asynchronously (on the main queue), so the container starts at a
//     placeholder size and takes the controller view's preferred size when it comes (`ready`).
//   - VST3: the controller's IPlugView ("editor", kPlatformTypeNSView) attached to the container.
//     IPlugFrame::resizeView resizes the container (then onSize); a resize of the container from
//     outside (the user resizing the panel) goes through checkSizeConstraint and onSize when the
//     view canResize. A 30 Hz main-queue timer writes the model's values into the controller
//     (VST3Instance::syncEditor), so undo and automation show in the editor (DW-204).
// An editor holds its plugin instance, so the plugin can't go away under its view; the app closes
// editors whose slot left the project.
//
// Threads: open/close/closeAll on the main thread only; json/openSlots from any thread.

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "core/Result.h"

namespace daw {

class AUInstance;
class VST3Instance;

class PluginViewHost {
public:
    PluginViewHost();
    ~PluginViewHost();  // main thread, or the views are released on the main queue
    PluginViewHost(const PluginViewHost&) = delete;
    PluginViewHost& operator=(const PluginViewHost&) = delete;

    // Returns the slot's container NSView (unretained; the host keeps it until close), or null:
    // no instance, a VST3 without an editor, not the main thread. An editor already open for the
    // same instance is returned as it is; one for another instance is closed first.
    void* open(NodeID slot, const std::shared_ptr<AUInstance>& au, const std::shared_ptr<VST3Instance>& vst3);
    void close(NodeID slot);
    void closeAll();

    // The instance the slot's editor shows (to tell a stale editor), or null.
    const void* instanceOf(NodeID slot) const;
    // pluginViewJSON's shape without "stale" (the facade adds it).
    std::string json(NodeID slot, bool stale) const;
    std::vector<NodeID> openSlots() const;

    struct Editor;  // PluginViewHost.mm

private:
    void startSyncTimer();
    void stopSyncTimerIfIdle();

    // The editor list, shared with the sync timer's handler (which may run once more after the host
    // is gone). The mutex guards the list; the views themselves are main-thread only.
    struct Shared {
        std::mutex mutex;
        std::vector<std::shared_ptr<Editor>> editors;
    };
    std::shared_ptr<Shared> shared_;
    void* syncTimer_ = nullptr;  // dispatch_source_t on the main queue (VST3 editors open), retained
};

} // namespace daw
