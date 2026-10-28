#include "nodes/BuiltinNodes.h"

#include <memory>
#include <string>
#include <utility>

#include "nodes/AudioClipPlayer.h"
#include "nodes/ChannelStrip.h"
#include "nodes/GainNode.h"

namespace daw {

Result<void> registerBuiltinNodes(NodeRegistry& registry, AssetLookup lookup, Telemetry* telemetry) {
    auto clipPlayer = [lookup = std::move(lookup)](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> {
        return std::unique_ptr<Node>(AudioClipPlayer::create(info.clips, lookup));
    };
    if (auto r = registry.set(NodeKind::audioClipPlayer, {std::move(clipPlayer)}); !r) return r;

    auto strip = [telemetry](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> {
        if (info.desc.numParams < ChannelStrip::kNumParams)
            return makeError(ErrorCode::invalidArgument,
                             "channelStrip " + std::to_string(info.desc.id) + ": needs " +
                                 std::to_string(ChannelStrip::kNumParams) + " params");
        const MeterTarget meter = telemetry && info.meter != kNoMeter ? MeterTarget{telemetry, info.meter}
                                                                       : MeterTarget{};
        return std::unique_ptr<Node>(std::make_unique<ChannelStrip>(info.desc.firstParam, meter));
    };
    NodeKindInfo stripInfo{std::move(strip)};
    stripInfo.meters = true;  // MIX-005, DW-048
    if (auto r = registry.set(NodeKind::channelStrip, std::move(stripInfo)); !r) return r;

    auto gain = [](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> {
        if (info.desc.numParams < GainNode::kMinNumParams)
            return makeError(ErrorCode::invalidArgument,
                             "gain " + std::to_string(info.desc.id) + ": needs " +
                                 std::to_string(GainNode::kMinNumParams) + " param");
        return std::unique_ptr<Node>(std::make_unique<GainNode>(info.desc.firstParam, info.desc.numParams));
    };
    return registry.set(NodeKind::gain, {std::move(gain)});
}

} // namespace daw
