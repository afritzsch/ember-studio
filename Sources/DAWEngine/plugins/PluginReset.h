#pragma once
// DW-242 (T-097): a hosted plugin's reset, never run or waited for on the render thread.
//
// Really clearing a plugin's state isn't RT work: VST3 setActive is a UI-thread call that
// allocates in most plugins (the SDK's `again` sends text messages), and AU -reset is an
// Objective-C message. Two paths:
//   - Normal (exports): the non-RT thread that starts an offline render resets every plugin
//     synchronously before the first block (EngineFacade::Impl::runExport → AUPluginHost /
//     VST3PluginHost::resetAll → resetNow()), with the device stopped and nothing rendering. It
//     marks the reset `fresh`, so the DW-063 Node::reset() of the first block (RT) has nothing left
//     to do (consumeFresh). Deterministic: the export starts from a clean plugin (IO-011).
//   - Fallback (an engine reset with no host reset before it, e.g. a bare Engine): Node::reset()
//     only flags the reset (request(): an atomic and a Mach semaphore signal, one trap with no lock
//     and no allocation) and returns at once. The worker thread ("daw.pluginreset") runs it; until
//     it is done busy() is true and the node renders as if absent (silence for an instrument, its
//     input passed through for an effect). Nothing waits on the render thread.

#include <atomic>
#include <cstdint>
#include <functional>

#include "core/Realtime.h"

namespace daw {

class PluginReset {
public:
    // Non-RT. Registers with the worker (started on first use). `work` clears the plugin; it runs
    // on the worker (request) or on the caller's thread (resetNow), one at a time.
    explicit PluginReset(std::function<void()> work);
    // Non-RT. Unregisters; waits for a reset that is running.
    ~PluginReset();
    PluginReset(const PluginReset&) = delete;
    PluginReset& operator=(const PluginReset&) = delete;

    // Non-RT, while nothing renders the plugin: resets now and marks the reset fresh.
    void resetNow();
    // RT. True once after a resetNow() (and clears it): the plugin was just reset.
    bool consumeFresh() DAW_RT { return fresh_.exchange(false, std::memory_order_acq_rel); }
    // RT. Asks the worker to reset the plugin; returns at once (busy() until it is done).
    void request() DAW_RT;
    // RT. A requested reset isn't done yet: don't call the plugin.
    bool busy() const DAW_RT { return state_.load(std::memory_order_acquire) != kIdle; }
    // Non-RT diagnostics and tests: resets completed (either path).
    uint64_t completed() const { return completed_.load(std::memory_order_acquire); }

private:
    friend struct PluginResetWorker;
    static constexpr uint32_t kIdle = 0, kRequested = 1, kRunning = 2;

    void runWork();

    std::function<void()> work_;
    std::atomic<uint32_t> state_{kIdle};
    std::atomic<bool> fresh_{false};
    std::atomic<uint64_t> completed_{0};
    uint32_t wake_ = 0;  // the worker's semaphore_t, read here so request() needs nothing else
};

} // namespace daw
