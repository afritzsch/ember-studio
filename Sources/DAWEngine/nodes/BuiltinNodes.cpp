#include "nodes/BuiltinNodes.h"

#include <memory>
#include <string>
#include <utility>

#include "nodes/AudioClipPlayer.h"
#include "nodes/ChannelStrip.h"
#include "nodes/Compressor.h"
#include "nodes/Delay.h"
#include "nodes/Eq.h"
#include "nodes/GainNode.h"
#include "nodes/Metronome.h"
#include "nodes/MidiClipPlayer.h"
#include "nodes/Reverb.h"
#include "nodes/Sampler.h"

namespace daw {

Result<void> registerBuiltinNodes(NodeRegistry& registry, AssetLookup lookup, Telemetry* telemetry) {
    auto clipPlayer = [lookup](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> {
        return std::unique_ptr<Node>(AudioClipPlayer::create(info.clips, lookup));
    };
    if (auto r = registry.set(NodeKind::audioClipPlayer, {std::move(clipPlayer)}); !r) return r;
    if (auto r = registry.set(NodeKind::midiClipPlayer, MidiClipPlayer::kindInfo()); !r) return r;  // DSP-003
    if (auto r = registry.set(NodeKind::sampler, Sampler::kindInfo(std::move(lookup), telemetry)); !r) return r;  // DSP-020..023
    if (auto r = registry.set(NodeKind::metronome, Metronome::kindInfo()); !r) return r;  // TIME-010, DSP-011

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
    stripInfo.paramInfo = ChannelStrip::kParamInfo;  // DSP-041
    if (auto r = registry.set(NodeKind::channelStrip, std::move(stripInfo)); !r) return r;

    if (auto r = registry.set(NodeKind::compressor, Compressor::kindInfo(telemetry)); !r) return r;  // DSP-031
    // DSP-040 (DW-142): the NaN-guarded processors count into the engine's telemetry.
    if (auto r = registry.set(NodeKind::reverb, Reverb::kindInfo(telemetry)); !r) return r;  // DSP-033
    if (auto r = registry.set(NodeKind::delay, Delay::kindInfo(telemetry)); !r) return r;  // DSP-032
    if (auto r = registry.set(NodeKind::eq, Eq::kindInfo(telemetry)); !r) return r;  // DSP-030

    auto gain = [](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> {
        if (info.desc.numParams < GainNode::kMinNumParams)
            return makeError(ErrorCode::invalidArgument,
                             "gain " + std::to_string(info.desc.id) + ": needs " +
                                 std::to_string(GainNode::kMinNumParams) + " param");
        return std::unique_ptr<Node>(std::make_unique<GainNode>(info.desc.firstParam, info.desc.numParams));
    };
    NodeKindInfo gainInfo{std::move(gain)};
    gainInfo.paramInfo = GainNode::kParamInfo;  // DSP-041, DW-160
    return registry.set(NodeKind::gain, std::move(gainInfo));
}

} // namespace daw
