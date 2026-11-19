#include "graph/GraphCompiler.h"

#include <pthread.h>
#include <pthread/qos.h>

#include <algorithm>
#include <utility>

namespace daw {

GraphCompiler::GraphCompiler(Engine& engine, NodeRegistry registry, double sampleRate, uint32_t maxBlock)
    : engine_(engine), builder_(std::move(registry), sampleRate, maxBlock), thread_([this] { run(); }) {
    builder_.latencyRelay()->attach(this);
}

// DW-211 (T-097).
GraphCompiler::GraphCompiler(Engine& engine, NodeRegistry registry, double sampleRate, uint32_t maxBlock, bool offline)
    : engine_(engine), builder_(std::move(registry), sampleRate, maxBlock, offline), thread_([this] { run(); }) {
    builder_.latencyRelay()->attach(this);
}

GraphCompiler::~GraphCompiler() {
    // MIX-024: nodes may outlive the compiler (the engine's pool); their reports go nowhere now.
    builder_.latencyRelay()->detach();
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

std::vector<LatencyEvent> GraphCompiler::takeEvents() {
    std::lock_guard lock(mutex_);
    return std::exchange(events_, {});
}

void GraphCompiler::nodeLatencyChanged(NodeID node) {
    {
        std::lock_guard lock(mutex_);
        if (std::find(latencyReports_.begin(), latencyReports_.end(), node) == latencyReports_.end())
            latencyReports_.push_back(node);
    }
    wake_.notify_one();
}

void GraphCompiler::run() {
    // 00-conventions §3. A rebuild follows a user edit, so it should land promptly.
    pthread_setname_np("daw.compile");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);

    for (;;) {
        GraphDescription desc;
        uint64_t ticket = 0;  // 0: a latency rebuild (MIX-024), which has no ticket
        std::vector<NodeID> reports;
        {
            std::unique_lock lock(mutex_);
            wake_.wait(lock, [this] {
                return stop_ || pending_.has_value() || (!latencyReports_.empty() && last_.has_value());
            });
            if (stop_) return;
            if (pending_) {
                desc = std::move(*pending_);
                pending_.reset();
                ticket = pendingTicket_;
            } else {
                desc = *last_;
            }
            // Any build re-reads every node's latency, so it answers the reports so far, and those
            // a failed latency rebuild carried over (DW-311).
            reports = std::exchange(latencyReports_, {});
            for (NodeID node : std::exchange(carriedReports_, {}))
                if (std::find(reports.begin(), reports.end(), node) == reports.end()) reports.push_back(node);
        }

        auto graph = builder_.build(desc, engine_.nodes(), engine_.params());
        std::vector<LatencyEvent> events;
        if (graph) {
            const RenderGraph& built = *graph.value();
            for (NodeID node : reports) {
                LatencyEvent event{node, 0, built.latency(), desc.version};
                for (const NodeLatency& n : built.nodeLatencies())
                    if (n.node == node) event.nodeLatency = n.samples;
                events.push_back(event);
            }
            engine_.publish(std::move(graph).value());
            last_ = desc;
        }

        {
            std::lock_guard lock(mutex_);
            if (ticket != 0) status_.completed = ticket;
            else ++status_.latencyRebuilds;
            if (graph) {
                status_.publishedVersion = desc.version;
                // DW-311: a latency rebuild doesn't clear the error of a rejected submission, so
                // the rejection is still there for the poll that sees its ticket completed.
                if (ticket != 0) status_.lastError.reset();
            } else {
                status_.lastError = graph.error();
                // DW-311 (T-111), MIX-024: the reports this build drained are still unanswered and
                // PDC still has the old latency. After a rejected submission they go back to the
                // queue, so the last good description is rebuilt with the new latency at once.
                // After a failed latency rebuild (of that same description) they wait for the
                // next build instead, so a description that keeps failing doesn't spin.
                std::vector<NodeID>& into = ticket != 0 ? latencyReports_ : carriedReports_;
                for (NodeID node : reports)
                    if (std::find(into.begin(), into.end(), node) == into.end()) into.push_back(node);
            }
            for (const LatencyEvent& event : events) {
                if (events_.size() < kMaxEvents) events_.push_back(event);
                else ++status_.eventsDropped;
            }
        }
        done_.notify_all();
    }
}

} // namespace daw
