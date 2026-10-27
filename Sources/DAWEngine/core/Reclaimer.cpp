#include "core/Reclaimer.h"

#include <pthread.h>
#include <pthread/qos.h>

#include <utility>

#include "core/Node.h"
#include "core/RenderGraph.h"

namespace daw {

Reclaimer::Reclaimer(const std::atomic<uint64_t>& renderEpoch)
    : renderEpoch_(renderEpoch), thread_([this] { run(); }) {}

Reclaimer::~Reclaimer() {
    {
        std::lock_guard lock(mutex_);
        stop_ = true;
    }
    wake_.notify_one();
    thread_.join();
}

void Reclaimer::retireGraph(std::unique_ptr<RenderGraph> graph, uint64_t epochAtSwap) {
    if (!graph) return;
    {
        std::lock_guard lock(mutex_);
        graphs_.push_back({std::move(graph), safeEpoch(epochAtSwap)});
        wakeRequested_ = true;
    }
    wake_.notify_one();
}

void Reclaimer::retireNode(std::shared_ptr<Node> node) {
    if (!node) return;
    {
        std::lock_guard lock(mutex_);
        nodes_.push_back(std::move(node));
        wakeRequested_ = true;
    }
    wake_.notify_one();
}

std::size_t Reclaimer::pendingGraphs() const {
    std::lock_guard lock(mutex_);
    return graphs_.size();
}

void Reclaimer::wake() {
    {
        std::lock_guard lock(mutex_);
        wakeRequested_ = true;
    }
    wake_.notify_one();
}

void Reclaimer::run() {
    // 00-conventions §3. Housekeeping, so utility QoS: it must keep up, but never compete with
    // the UI or the audio thread.
    pthread_setname_np("daw.reclaim");
    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);

    for (;;) {
        bool stopping;
        {
            std::unique_lock lock(mutex_);
            wake_.wait_for(lock, kPollInterval, [this] { return stop_ || wakeRequested_; });
            wakeRequested_ = false;
            stopping = stop_;
        }
        collect(stopping);
        if (stopping) return;
    }
}

void Reclaimer::collect(bool all) {
    // RT-retired objects first: the audio thread is done with them by definition (ENG-014).
    // Bounded by the queue capacity, so a busy producer can't keep this pass going forever.
    uint64_t rtFreed = 0;
    RetireQueue::Item item;
    for (std::size_t i = 0; i < RetireQueue::kCapacity && rtQueue_.pop(item); ++i) {
        item.destroy(item.object);
        ++rtFreed;
    }

    std::vector<std::unique_ptr<RenderGraph>> graphs;
    std::vector<std::shared_ptr<Node>> nodes;
    {
        std::lock_guard lock(mutex_);
        // ENG-012: see the protocol in Reclaimer.h.
        const uint64_t epoch = renderEpoch_.load(std::memory_order_seq_cst);
        for (std::size_t i = 0; i < graphs_.size();) {
            if (all || epoch >= graphs_[i].safeAt) {
                graphs.push_back(std::move(graphs_[i].graph));
                graphs_[i] = std::move(graphs_.back());
                graphs_.pop_back();
            } else {
                ++i;
            }
        }
        nodes.swap(nodes_);
    }
    // Destroy outside the lock: node destructors (plugins) can be slow. Graphs first, so the
    // NodePool's references are usually the last ones (either order is correct).
    const uint64_t freed = graphs.size();
    graphs.clear();
    nodes.clear();

    graphsFreed_.fetch_add(freed, std::memory_order_release);
    rtObjectsFreed_.fetch_add(rtFreed, std::memory_order_release);
    passes_.fetch_add(1, std::memory_order_release);
}

} // namespace daw
