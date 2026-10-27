#include "core/NodePool.h"

#include <utility>
#include <vector>

#include "core/Reclaimer.h"

namespace daw {

namespace {

// ENG-013: release() runs right before destruction, wherever the last reference drops (by
// construction, daw.reclaim; see NodePool.h).
struct ReleaseAndDelete {
    void operator()(Node* node) const {
        node->release();
        delete node;
    }
};

} // namespace

NodePool::NodePool(Reclaimer& reclaimer) : reclaimer_(reclaimer) {}

NodePool::~NodePool() { clear(); }

Result<std::shared_ptr<Node>> NodePool::put(NodeID id, std::unique_ptr<Node> node,
                                            const PrepareInfo& info) {
    if (!node) return makeError(ErrorCode::invalidArgument, "null node");
    if (!(info.sampleRate > 0)) return makeError(ErrorCode::invalidArgument, "sampleRate must be > 0");
    if (info.maxBlock == 0 || info.maxBlock > kMaxBlock)
        return makeError(ErrorCode::invalidArgument, "maxBlock must be in 1...kMaxBlock");

    // Outside the lock: prepare() may be slow (plugins).
    node->prepare(info);
    std::shared_ptr<Node> shared(node.release(), ReleaseAndDelete{});

    std::shared_ptr<Node> replaced;
    {
        std::lock_guard lock(mutex_);
        std::shared_ptr<Node>& slot = nodes_[id];
        replaced = std::exchange(slot, shared);
    }
    reclaimer_.retireNode(std::move(replaced));
    return shared;
}

std::shared_ptr<Node> NodePool::get(NodeID id) const {
    std::lock_guard lock(mutex_);
    auto it = nodes_.find(id);
    return it == nodes_.end() ? nullptr : it->second;
}

bool NodePool::remove(NodeID id) {
    std::shared_ptr<Node> removed;
    {
        std::lock_guard lock(mutex_);
        auto it = nodes_.find(id);
        if (it == nodes_.end()) return false;
        removed = std::move(it->second);
        nodes_.erase(it);
    }
    reclaimer_.retireNode(std::move(removed));
    return true;
}

void NodePool::clear() {
    std::unordered_map<NodeID, std::shared_ptr<Node>> all;
    {
        std::lock_guard lock(mutex_);
        all.swap(nodes_);
    }
    for (auto& [id, node] : all) reclaimer_.retireNode(std::move(node));
}

std::size_t NodePool::size() const {
    std::lock_guard lock(mutex_);
    return nodes_.size();
}

} // namespace daw
