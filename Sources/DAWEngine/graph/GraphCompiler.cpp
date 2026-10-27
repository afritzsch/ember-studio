#include "graph/GraphCompiler.h"

#include <pthread.h>
#include <pthread/qos.h>

#include <utility>

namespace daw {

GraphCompiler::GraphCompiler(Engine& engine, NodeRegistry registry, double sampleRate, uint32_t maxBlock)
    : engine_(engine), builder_(std::move(registry), sampleRate, maxBlock), thread_([this] { run(); }) {}

GraphCompiler::~GraphCompiler() {
    {
        std::lock_guard lock(mutex_);
        stop_ = true;
    }
    wake_.notify_one();
    thread_.join();
}

uint64_t GraphCompiler::submit(GraphDescription desc) {
    uint64_t ticket;
    {
        std::lock_guard lock(mutex_);
        ticket = nextTicket_++;
        pending_ = std::move(desc);  // drops a description still waiting
        pendingTicket_ = ticket;
    }
    wake_.notify_one();
    return ticket;
}

bool GraphCompiler::wait(uint64_t ticket, std::chrono::milliseconds timeout) {
    std::unique_lock lock(mutex_);
    return done_.wait_for(lock, timeout, [&] { return status_.completed >= ticket; });
}

GraphCompiler::Status GraphCompiler::status() const {
    std::lock_guard lock(mutex_);
    return status_;
}

void GraphCompiler::run() {
    // 00-conventions §3. A rebuild follows a user edit, so it should land promptly.
    pthread_setname_np("daw.compile");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);

    for (;;) {
        GraphDescription desc;
        uint64_t ticket;
        {
            std::unique_lock lock(mutex_);
            wake_.wait(lock, [this] { return stop_ || pending_.has_value(); });
            if (stop_) return;
            desc = std::move(*pending_);
            pending_.reset();
            ticket = pendingTicket_;
        }

        auto graph = builder_.build(desc, engine_.nodes(), engine_.params());
        if (graph) engine_.publish(std::move(graph).value());

        {
            std::lock_guard lock(mutex_);
            status_.completed = ticket;
            if (graph) {
                status_.publishedVersion = desc.version;
                status_.lastError.reset();
            } else {
                status_.lastError = graph.error();
            }
        }
        done_.notify_all();
    }
}

} // namespace daw
