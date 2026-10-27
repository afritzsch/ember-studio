#include "graph/NodeRegistry.h"

#include <utility>

#include "graph/BusNode.h"
#include "graph/MasterNode.h"

namespace daw {

NodeRegistry NodeRegistry::withBuiltins() {
    NodeRegistry registry;
    (void)registry.set(NodeKind::master, {[](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> {
        return std::make_unique<MasterNode>(info.desc.firstParam, info.desc.numParams);
    }});
    (void)registry.set(NodeKind::bus, {[](const NodeCreateInfo&) -> Result<std::unique_ptr<Node>> {
        return std::make_unique<BusNode>();
    }});
    return registry;
}

Result<void> NodeRegistry::set(NodeKind kind, NodeKindInfo info) {
    const auto index = static_cast<std::size_t>(kind);
    if (index >= kNumKinds) return makeError(ErrorCode::invalidArgument, "unknown NodeKind");
    if (!info.create) return makeError(ErrorCode::invalidArgument, "empty factory");
    kinds_[index] = std::move(info);
    return {};
}

const NodeKindInfo* NodeRegistry::find(NodeKind kind) const {
    const auto index = static_cast<std::size_t>(kind);
    if (index >= kNumKinds || !kinds_[index].create) return nullptr;
    return &kinds_[index];
}

} // namespace daw
