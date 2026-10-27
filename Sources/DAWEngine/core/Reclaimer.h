#pragma once
// ENG-012/014: the daw.reclaim thread (00-conventions §3). It frees everything the engine retires:
// replaced RenderGraphs (once the audio thread can no longer be using them), nodes dropped from
// the NodePool, and objects the audio thread hands over through the RetireQueue.
//
// Epoch protocol (ENG-012). The render thread bumps `renderEpoch` at the start of every block
// (making it odd) and again at the end (even). Engine::publish swaps the graph pointer and then
// reads the epoch; both sides use seq_cst, so the read sees every bump that precedes a block's
// graph load:
//   - even: no block was running at the swap, and any later block loads the new graph, so the old
//     one is free to go now;
//   - odd (e): a block is running and may hold the old graph; it is free once the epoch reaches
//     e + 1, i.e. that block has ended.
// The even case matters for the headless engine: graphs published while nothing renders are
// freed instead of piling up until the next block.
// It assumes one render() at a time (D-15: a single audio thread).
//
// Reclaim polls (kPollInterval): the audio thread can't signal a condition variable
// (CONV-RT-02). Non-RT retirements wake it at once.

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include "core/RetireQueue.h"

namespace daw {

class Node;
class RenderGraph;

class Reclaimer {
public:
    static constexpr std::chrono::milliseconds kPollInterval{5};

    // Starts daw.reclaim. `renderEpoch` is written by the render thread (see above) and must
    // outlive the Reclaimer.
    explicit Reclaimer(const std::atomic<uint64_t>& renderEpoch);
    // Stops the thread after it frees everything still pending, whatever the epoch: the caller
    // guarantees nothing renders any more. So all reclaimed objects die on daw.reclaim.
    ~Reclaimer();
    Reclaimer(const Reclaimer&) = delete;
    Reclaimer& operator=(const Reclaimer&) = delete;

    // Non-RT, any thread. `epochAtSwap` is renderEpoch read right after the graph was unpublished.
    void retireGraph(std::unique_ptr<RenderGraph> graph, uint64_t epochAtSwap);
    // Non-RT, any thread. Drops this reference on daw.reclaim (NodePool, ENG-013).
    void retireNode(std::shared_ptr<Node> node);

    // RT producer side for the audio thread (ENG-014).
    RetireQueue& rtQueue() { return rtQueue_; }

    // Non-RT. Diagnostics, and the hooks tests use to wait for the thread.
    uint64_t passes() const { return passes_.load(std::memory_order_acquire); }
    uint64_t graphsFreed() const { return graphsFreed_.load(std::memory_order_acquire); }
    uint64_t rtObjectsFreed() const { return rtObjectsFreed_.load(std::memory_order_acquire); }
    std::size_t pendingGraphs() const;
    // Wakes the thread for an immediate pass.
    void wake();

    // The epoch value at which a graph unpublished at `epochAtSwap` may be freed.
    static constexpr uint64_t safeEpoch(uint64_t epochAtSwap) {
        return (epochAtSwap & 1u) ? epochAtSwap + 1 : epochAtSwap;
    }

private:
    struct RetiredGraph {
        std::unique_ptr<RenderGraph> graph;
        uint64_t safeAt;
    };

    void run();
    // One pass: frees what is safe (or everything when `all`).
    void collect(bool all);

    const std::atomic<uint64_t>& renderEpoch_;
    RetireQueue rtQueue_;

    mutable std::mutex mutex_;
    std::condition_variable wake_;
    bool stop_ = false;
    bool wakeRequested_ = false;
    std::vector<RetiredGraph> graphs_;
    std::vector<std::shared_ptr<Node>> nodes_;

    std::atomic<uint64_t> passes_{0};
    std::atomic<uint64_t> graphsFreed_{0};
    std::atomic<uint64_t> rtObjectsFreed_{0};

    std::thread thread_;  // last: started once everything above exists
};

} // namespace daw
