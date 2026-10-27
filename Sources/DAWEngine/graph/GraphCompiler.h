#pragma once
// MIX-001: runs GraphBuilder on daw.compile (00-conventions §3) and publishes what it builds to
// the Engine. This is how a GraphDescription becomes the live graph; the facade's applyGraph
// (08, T-014) submits here.
//
// Submissions coalesce: a description still waiting when a newer one arrives is dropped, since
// only the latest structure matters (the model debounces too, MODEL-021). A description that
// fails to build leaves the current graph in place and is reported through status().
//
// Threads: submit(), wait() and status() from any non-RT thread. Destroy the compiler before
// the Engine it publishes to.

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <optional>
#include <thread>

#include "core/Engine.h"
#include "core/Result.h"
#include "daw/GraphDescription.h"
#include "graph/GraphBuilder.h"
#include "graph/NodeRegistry.h"

namespace daw {

class GraphCompiler {
public:
    struct Status {
        uint64_t completed = 0;         // highest ticket built, failed or dropped as superseded
        uint64_t publishedVersion = 0;  // GraphDescription::version of the last published graph
        std::optional<Error> lastError; // from the most recent build; cleared by a success
    };

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

private:
    void run();

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
    std::thread thread_;  // last: started once everything above exists
};

} // namespace daw
