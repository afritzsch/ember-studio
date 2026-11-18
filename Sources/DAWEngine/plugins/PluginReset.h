#pragma once
// DW-242 (T-097): a hosted plugin's reset, run off the render thread.
//
// Node::reset() is an RT entry point (02), and the only caller that reaches a plugin node is the
// DW-063 reset before an offline render's first block (RenderGraph::resetAllNodes, on daw.export,
// never on the device's audio thread: live locates reset only timeline nodes, TIME-008). Really
// clearing a plugin's state is not RT work: VST3 setActive is a UI-thread call that allocates in
// most plugins (the SDK's `again` sends text messages), and AU -reset is an Objective-C message.
// So the plugin node's reset() hands the work to one process-wide worker thread
// ("daw.pluginreset") and waits for it:
//   - RT side (run): an atomic state change, a Mach semaphore signal (one trap: no lock, no
//     allocation, so the RT trap stays at 0), then a spin on the atomic, bounded by kWaitNanos.
//     The render thread is an offline one here, so waiting costs time, never a dropout.
//   - Worker: runs every requested reset under its registry lock, then marks it done.
// If the wait times out the reset goes on in the background and busy() stays true until it is
// done; the node renders as if absent meanwhile (it never calls the plugin while it is reset).

#include <atomic>
#include <cstdint>
#include <functional>

#include "core/Realtime.h"

namespace daw {

class PluginReset {
public:
    // How long run() waits for the worker before it gives up (the reset still completes).
    static constexpr uint64_t kWaitNanos = 5'000'000'000;  // 5 s

    // Non-RT. Registers with the worker (started on first use); `work` runs on the worker thread.
    explicit PluginReset(std::function<void()> work);
    // Non-RT. Unregisters; waits for a reset that is running.
    ~PluginReset();
    PluginReset(const PluginReset&) = delete;
    PluginReset& operator=(const PluginReset&) = delete;

    // RT (an offline render's reset). Asks the worker to run `work` and waits for it. True when the
    // reset is done, false when the wait timed out (busy() until it is).
    bool run() DAW_RT;
    // RT. A reset was requested and isn't done yet: don't call the plugin.
    bool busy() const DAW_RT { return state_.load(std::memory_order_acquire) != kIdle; }
    // Non-RT diagnostics and tests: resets the worker has completed.
    uint64_t completed() const { return completed_.load(std::memory_order_acquire); }

private:
    friend struct PluginResetWorker;
    static constexpr uint32_t kIdle = 0, kRequested = 1, kRunning = 2;

    std::function<void()> work_;
    std::atomic<uint32_t> state_{kIdle};
    std::atomic<uint64_t> completed_{0};
    uint32_t wake_ = 0;  // the worker's semaphore_t, read here so run() needs nothing else
};

} // namespace daw
