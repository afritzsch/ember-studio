// DW-242 (T-097): see PluginReset.h.

#include "plugins/PluginReset.h"

#include <mach/mach.h>
#include <pthread.h>
#include <pthread/qos.h>

#include <algorithm>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

namespace daw {

// One per process, made by the first PluginReset and never destroyed (plugin instances may be
// released during static destruction).
struct PluginResetWorker {
    std::mutex mutex;  // registered; held while a reset runs (either path), so they never overlap
    std::vector<PluginReset*> registered;
    semaphore_t wake = MACH_PORT_NULL;

    PluginResetWorker() {
        semaphore_create(mach_task_self(), &wake, SYNC_POLICY_FIFO, 0);
        std::thread([this] { run(); }).detach();
    }

    static PluginResetWorker& shared() {
        static PluginResetWorker* worker = new PluginResetWorker;
        return *worker;
    }

    void run() {
        pthread_setname_np("daw.pluginreset");
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
        for (;;) {
            if (semaphore_wait(wake) != KERN_SUCCESS) continue;
            std::lock_guard lock(mutex);
            for (PluginReset* reset : registered) {
                uint32_t expected = PluginReset::kRequested;
                if (!reset->state_.compare_exchange_strong(expected, PluginReset::kRunning, std::memory_order_acq_rel))
                    continue;
                reset->runWork();
                reset->state_.store(PluginReset::kIdle, std::memory_order_release);
            }
        }
    }
};

PluginReset::PluginReset(std::function<void()> work) : work_(std::move(work)) {
    PluginResetWorker& worker = PluginResetWorker::shared();
    wake_ = worker.wake;
    std::lock_guard lock(worker.mutex);
    worker.registered.push_back(this);
}

PluginReset::~PluginReset() {
    PluginResetWorker& worker = PluginResetWorker::shared();
    std::lock_guard lock(worker.mutex);  // a reset of this one that is running finishes first
    auto& r = worker.registered;
    r.erase(std::remove(r.begin(), r.end(), this), r.end());
}

void PluginReset::runWork() {
    work_();
    completed_.fetch_add(1, std::memory_order_acq_rel);
}

void PluginReset::resetNow() {
    std::lock_guard lock(PluginResetWorker::shared().mutex);
    runWork();
    fresh_.store(true, std::memory_order_release);
}

namespace {

// The semaphore trap isn't annotated nonblocking; it neither allocates nor takes a lock (the RT
// trap checks at runtime).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
void signal(semaphore_t semaphore) DAW_RT { semaphore_signal(semaphore); }
#pragma clang diagnostic pop

} // namespace

void PluginReset::request() DAW_RT {
    uint32_t expected = kIdle;
    if (state_.compare_exchange_strong(expected, kRequested, std::memory_order_acq_rel))
        signal(static_cast<semaphore_t>(wake_));
}

} // namespace daw
