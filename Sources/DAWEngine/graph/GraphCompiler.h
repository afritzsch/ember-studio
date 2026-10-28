#pragma once
// MIX-001: runs GraphBuilder on daw.compile (00-conventions §3) and publishes what it builds to
// the Engine. This is how a GraphDescription becomes the live graph; the facade's applyGraph
// (08, T-014) submits here.
//
// Submissions coalesce: a description still waiting when a newer one arrives is dropped, since
// only the latest structure matters (the model debounces too, MODEL-021). A description that
// fails to build leaves the current graph in place and is reported through status().
//
// MIX-024: the compiler listens to its builder's LatencyRelay. When a node reports a latency
// change it rebuilds the description it last built successfully (unless a newer one is waiting,
// which picks the change up anyway), so PDC is re-planned with every node's current latency, and
// once that graph is published it queues a LatencyEvent per reporting node for takeEvents().
//
// Threads: submit(), wait(), status() and takeEvents() from any non-RT thread. Destroy the
// compiler before the Engine it publishes to.

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <optional>
#include <thread>
#include <vector>

#include "core/Engine.h"
#include "core/Result.h"
#include "daw/GraphDescription.h"
#include "graph/GraphBuilder.h"
#include "graph/NodeRegistry.h"

namespace daw {

// MIX-024: a node's latency changed and the graph built with it is published.
struct LatencyEvent {
    NodeID node = 0;
    uint32_t nodeLatency = 0;   // its latencySamples() in that graph
    uint32_t graphLatency = 0;  // that graph's total latency (MIX-023)
    uint64_t version = 0;       // GraphDescription::version of that graph
};

class GraphCompiler final : private LatencyListener {
public:
    struct Status {
        uint64_t completed = 0;         // highest ticket built, failed or dropped as superseded
        uint64_t publishedVersion = 0;  // GraphDescription::version of the last published graph
        std::optional<Error> lastError; // from the most recent build; cleared by a success
        uint64_t latencyRebuilds = 0;   // MIX-024: builds done for latency reports
        uint64_t eventsDropped = 0;     // events beyond kMaxEvents nobody took
    };
    static constexpr std::size_t kMaxEvents = 1024;

    // Starts daw.compile. Graphs are built for `sampleRate` and `maxBlock` (see GraphBuilder).
    GraphCompiler(Engine& engine, NodeRegistry registry, double sampleRate, uint32_t maxBlock = kMaxBlock);
    // Finishes the build in progress, drops anything still queued, and joins daw.compile.
    ~GraphCompiler();
    GraphCompiler(const GraphCompiler&) = delete;
    GraphCompiler& operator=(const GraphCompiler&) = delete;

    // Queues `desc` for daw.compile and returns its ticket (1, 2, …).
    uint64_t submit(GraphDescription desc);

    // Blocks until `ticket` is completed. False on timeout.
    bool wait(uint64_t ticket, std::chrono::milliseconds timeout);

    Status status() const;

    // MIX-024: moves out the queued latency events, oldest first.
    std::vector<LatencyEvent> takeEvents();

private:
    void run();
    void nodeLatencyChanged(NodeID node) override;  // LatencyListener, any non-RT thread

    Engine& engine_;
    GraphBuilder builder_;  // only daw.compile touches it

    mutable std::mutex mutex_;
    std::condition_variable wake_;  // daw.compile: work or stop
    std::condition_variable done_;  // waiters: completed advanced
    std::optional<GraphDescription> pending_;
    uint64_t pendingTicket_ = 0;
    uint64_t nextTicket_ = 1;
    bool stop_ = false;
    Status status_;
    // MIX-024: nodes that reported since the last build started; events for takeEvents().
    std::vector<NodeID> latencyReports_;
    std::vector<LatencyEvent> events_;
    // daw.compile only: the last description built successfully, for latency rebuilds.
    std::optional<GraphDescription> last_;
    std::thread thread_;  // last: started once everything above exists
};

} // namespace daw
