#pragma once
// Node instances keyed by NodeID, shared by every snapshot that uses them (02 Concepts), so a
// rebuild never re-instantiates a plugin or resets DSP state.
//
// Ownership: the pool and each RenderGraph hold shared_ptrs; the audio thread only sees raw
// pointers. When the pool drops a node (remove, replace, destruction) it hands its reference to
// daw.reclaim instead of releasing it here, and graphs are destroyed on daw.reclaim too, so a
// node's last reference, and with it release() + delete, always goes away there (ENG-013).
//
// Non-RT; meant for daw.compile (GraphBuilder, MIX-001). Internally locked so tests and other
// non-RT threads can use it as well.

#include <cstddef>
#include <memory>
#include <mutex>
#include <unordered_map>

#include "core/Node.h"
#include "core/Result.h"

namespace daw {

class Reclaimer;

class NodePool {
public:
    explicit NodePool(Reclaimer& reclaimer);
    ~NodePool();  // hands every node to the reclaimer
    NodePool(const NodePool&) = delete;
    NodePool& operator=(const NodePool&) = delete;

    // ENG-013: prepares `node` on the calling thread, then makes it the instance for `id`. A
    // config change is a new instance put under the same ID: a node a live graph may be
    // rendering can't be re-prepared in place, since prepare() isn't RT-safe against process().
    // The replaced instance stays alive until no graph references it.
    Result<std::shared_ptr<Node>> put(NodeID id, std::unique_ptr<Node> node, const PrepareInfo& info);

    // The current instance for `id`, or null.
    std::shared_ptr<Node> get(NodeID id) const;

    // Forgets `id`. The node is released and destroyed on daw.reclaim once no graph uses it.
    // Returns false if there was no such node. It doesn't make the node's ParamIDs free-able:
    // graphs that still reference them may be rendering (DW-029, see Engine::params()).
    bool remove(NodeID id);
    void clear();

    std::size_t size() const;

private:
    Reclaimer& reclaimer_;
    mutable std::mutex mutex_;
    std::unordered_map<NodeID, std::shared_ptr<Node>> nodes_;
};

} // namespace daw
