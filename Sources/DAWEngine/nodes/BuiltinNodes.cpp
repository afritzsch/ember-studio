#include "nodes/BuiltinNodes.h"

#include <memory>
#include <string>
#include <utility>

#include "nodes/AudioClipPlayer.h"
#include "nodes/ChannelStrip.h"

namespace daw {

Result<void> registerBuiltinNodes(NodeRegistry& registry, AssetLookup lookup) {
    auto clipPlayer = [lookup = std::move(lookup)](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> {
        return std::unique_ptr<Node>(AudioClipPlayer::create(info.clips, lookup));
    };
    if (auto r = registry.set(NodeKind::audioClipPlayer, {std::move(clipPlayer)}); !r) return r;

    auto strip = [](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> {
        if (info.desc.numParams < ChannelStrip::kNumParams)
            return makeError(ErrorCode::invalidArgument,
                             "channelStrip " + std::to_string(info.desc.id) + ": needs " +
                                 std::to_string(ChannelStrip::kNumParams) + " params");
        return std::unique_ptr<Node>(std::make_unique<ChannelStrip>(info.desc.firstParam));
    };
    return registry.set(NodeKind::channelStrip, {std::move(strip)});
}

} // namespace daw
