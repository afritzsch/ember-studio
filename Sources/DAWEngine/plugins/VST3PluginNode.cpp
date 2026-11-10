#include "plugins/VST3PluginNode.h"

#include <algorithm>
#include <cstring>
#include <limits>

#include "core/ProcessContext.h"
#include "graph/PassThrough.h"
#include "plugins/VST3PluginHost.h"

namespace daw {

VST3PluginNode::VST3PluginNode(NodeID id, std::shared_ptr<VST3Instance> instance, ParamID firstParam,
                               uint32_t numParams, LatencyReporter reporter, std::weak_ptr<VST3PluginHost> host)
    : id_(id), instance_(std::move(instance)), firstParam_(firstParam), numParams_(numParams),
      reporter_(std::move(reporter)), host_(std::move(host)) {}

void VST3PluginNode::prepare(const PrepareInfo& info) {
    active_ = false;
    if (!instance_) return;
    // A session-rate change builds every node again at the new rate (IO-021 (5)); the slot's
    // instance moves to a new plugin with the old one's state, since the old graph may still hold it.
    if (instance_->isPrepared() &&
        (instance_->preparedRate() != info.sampleRate || instance_->preparedMaxBlock() != info.maxBlock)) {
        auto host = host_.lock();
        auto fresh = host ? host->reinstantiate(id_, instance_)
                          : Result<std::shared_ptr<VST3Instance>>(makeError(ErrorCode::internal, "no plugin host"));
        if (!fresh) {
            if (host) host->reportFailure(id_, fresh.error());
            instance_.reset();
            return;
        }
        instance_ = std::move(fresh).value();
    }
    if (auto prepared = instance_->prepare(info.sampleRate, info.maxBlock); !prepared) {
        if (auto host = host_.lock()) host->reportFailure(id_, prepared.error());
        instance_.reset();
        return;
    }
    instance_->setLatencyReporter(reporter_);

    const auto& params = instance_->params();
    tracked_ = std::min({numParams_, static_cast<uint32_t>(params.size()), kMaxParams});
    lastGeneration_.assign(tracked_, 0);
    lastPushed_.assign(tracked_, std::numeric_limits<float>::quiet_NaN());
    writable_.resize(tracked_);
    for (uint32_t i = 0; i < tracked_; ++i) writable_[i] = params[i].writable;
    primed_ = false;
    active_ = true;
}

uint32_t VST3PluginNode::latencySamples() const { return active_ ? instance_->latencySamples() : 0; }

void VST3PluginNode::pushParams(const ProcessContext& ctx) DAW_RT {
    for (uint32_t i = 0; i < tracked_; ++i) {
        const ParamID id = firstParam_ + i;
        const uint32_t generation = ctx.params.generation(id);
        if (primed_ && generation == lastGeneration_[i]) continue;
        lastGeneration_[i] = generation;
        float value = ctx.params.get(id);
        if (!__builtin_isfinite(value) || !writable_[i]) continue;  // not set, or read-only
        value = std::clamp(value, 0.0f, 1.0f);
        if (value == lastPushed_[i]) continue;
        instance_->pushParam(i, value);
        lastPushed_[i] = value;
        ++paramEvents_;
    }
    primed_ = true;
}

void VST3PluginNode::process(ProcessContext& ctx, NodeIO& io) DAW_RT {
    const uint32_t n = ctx.numFrames;
    if (n == 0) return;
    const std::size_t bytes = std::size_t{io.audioOut.numFrames} * sizeof(float);
    if (!active_) {
        passThrough(io);
        return;
    }
    pushParams(ctx);
    for (const MidiEvent& event : io.midiIn) instance_->addMidi(event, n);
    instance_->setTransport(ctx.transport);
    if (!instance_->render(io, n))
        for (uint32_t c = 0; c < io.audioOut.numChannels; ++c) std::memset(io.audioOut.channels[c], 0, bytes);
}

} // namespace daw
