#include "automation/AutomationCompiler.h"

#include <cmath>
#include <optional>
#include <string>

#include "plugins/AUPluginNode.h"

namespace daw {

namespace {

Error invalid(const AutomationDesc& lane, const std::string& what) {
    return makeError(ErrorCode::invalidArgument, "automation lane " + std::to_string(lane.laneID) + ": " + what);
}

// The mapping for param `index` of node `i`; nullopt leaves the lane out (AUTO-008).
std::optional<ParamMapping> mappingFor(const NodeDesc& node, const NodeKindInfo* kind, Node* instance,
                                       uint32_t index) {
    switch (node.kind) {
    case NodeKind::auPlugin: {
        // PLUG-015: the slot holds the AU parameter's own value; a node whose AU didn't load
        // (inert) has no parameters and gets the identity.
        auto* au = dynamic_cast<AUPluginNode*>(instance);
        if (au != nullptr && au->instance() && index < au->instance()->params().size()) {
            const AUParamInfo& p = au->instance()->params()[index];
            return ParamMapping{p.min, p.max, ParamMapping::Scale::linear};
        }
        return ParamMapping::identity();
    }
    case NodeKind::vst3Plugin:
        return ParamMapping::identity();  // normalized already (10, T-062 delta)
    default:
        break;
    }
    if (kind != nullptr) {
        for (const ParamInfo& info : kind->paramInfo) {
            if (info.index != index) continue;
            if (!info.automatable) return std::nullopt;
            return ParamMapping::from(info);
        }
    }
    return ParamMapping::identity();
}

} // namespace

Result<void> validateAutomation(const GraphDescription& desc, const ParamSlotTable& params) {
    for (const AutomationDesc& lane : desc.automation) {
        if (lane.target >= params.capacity()) return invalid(lane, "target param is outside the param table");
        for (std::size_t i = 0; i < lane.points.size(); ++i) {
            const AutomationPointDesc& p = lane.points[i];
            if (i > 0 && p.tick <= lane.points[i - 1].tick)
                return invalid(lane, "point ticks are not strictly increasing");
            if (!std::isfinite(p.value) || !std::isfinite(p.shape))
                return invalid(lane, "a point value or shape is not finite");
            if (p.curve > static_cast<uint8_t>(AutomationCurve::exponential))
                return invalid(lane, "unknown curve " + std::to_string(p.curve));
        }
    }
    return {};
}

std::unique_ptr<AutomationSet> compileAutomation(const GraphDescription& desc,
                                                 std::span<const NodeKindInfo* const> kinds,
                                                 std::span<const std::shared_ptr<Node>> nodes) {
    std::vector<AutomationPlayer> players;
    for (const AutomationDesc& lane : desc.automation) {
        if (!lane.enabled || lane.points.empty()) continue;  // AUTO-005: `off` is ignored
        std::optional<ParamMapping> mapping;
        for (std::size_t i = 0; i < desc.nodes.size(); ++i) {
            const NodeDesc& node = desc.nodes[i];
            if (node.numParams == 0 || lane.target < node.firstParam ||
                uint64_t{lane.target} >= uint64_t{node.firstParam} + node.numParams)
                continue;
            mapping = mappingFor(node, kinds[i], nodes[i].get(), lane.target - node.firstParam);
            break;
        }
        if (!mapping) continue;  // no node owns the slot, or the param isn't automatable
        std::vector<AutomationPoint> points;
        points.reserve(lane.points.size());
        for (const AutomationPointDesc& p : lane.points)
            points.push_back({p.tick, p.value, static_cast<AutomationCurve>(p.curve), p.shape});
        players.emplace_back(lane.laneID, lane.target, std::move(points), *mapping);
    }
    if (players.empty()) return nullptr;
    return std::make_unique<AutomationSet>(std::move(players));
}

} // namespace daw
