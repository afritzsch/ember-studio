#pragma once
// MIX-024: how a node tells the engine that its latencySamples() changed after prepare (a plugin
// whose latency depends on its settings, T-061/T-062). GraphBuilder hands every node factory a
// LatencyReporter for that node (NodeCreateInfo::latency); the node keeps it and calls changed()
// once latencySamples() returns the new value. GraphCompiler listens: it rebuilds the current
// description on daw.compile, which re-reads every node's latency and re-plans PDC (MIX-020..022),
// then reports the change as an event.
//
// Threads: changed() from any non-RT thread. A plugin that learns of the change on the audio
// thread (VST3 restartComponent from process) must defer the call, e.g. to the main thread.
// Reports made while nobody listens (a builder without a compiler, or after the compiler is
// gone) are dropped.

#include <memory>
#include <mutex>

#include "core/Node.h"

namespace daw {

class LatencyListener {
public:
    virtual ~LatencyListener() = default;
    // Called with the relay's lock held: don't call back into the relay.
    virtual void nodeLatencyChanged(NodeID node) = 0;
};

// Shared by a builder, its listener and every reporter it handed out, so a node that outlives
// the compiler reports into nothing rather than into a dangling pointer.
class LatencyRelay {
public:
    void attach(LatencyListener* listener) {
        std::lock_guard lock(mutex_);
        listener_ = listener;
    }
    // After detach() returns, no report is running in the old listener.
    void detach() { attach(nullptr); }
    void report(NodeID node) {
        std::lock_guard lock(mutex_);
        if (listener_) listener_->nodeLatencyChanged(node);
    }

private:
    std::mutex mutex_;
    LatencyListener* listener_ = nullptr;
};

class LatencyReporter {
public:
    LatencyReporter() = default;  // reports nowhere
    LatencyReporter(std::shared_ptr<LatencyRelay> relay, NodeID node)
        : relay_(std::move(relay)), node_(node) {}

    // Non-RT, any thread: this node's latencySamples() has changed.
    void changed() const {
        if (relay_) relay_->report(node_);
    }

private:
    std::shared_ptr<LatencyRelay> relay_;
    NodeID node_ = 0;
};

} // namespace daw
