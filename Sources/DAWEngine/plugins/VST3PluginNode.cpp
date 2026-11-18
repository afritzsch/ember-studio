#include "plugins/VST3PluginNode.h"

#include <algorithm>
#include <cstring>
#include <limits>

#include "automation/WrapJump.h"
#include "core/ProcessContext.h"
#include "graph/PassThrough.h"
#include "plugins/VST3PluginHost.h"

namespace daw {

VST3PluginNode::VST3PluginNode(NodeID id, std::shared_ptr<VST3Instance> instance, ParamID firstParam,
                               uint32_t numParams, LatencyReporter reporter, std::weak_ptr<VST3PluginHost> host,
                               std::shared_ptr<PluginHealth> health, Telemetry* telemetry)
    : id_(id), instance_(std::move(instance)), firstParam_(firstParam), numParams_(numParams),
      reporter_(std::move(reporter)), host_(std::move(host)), health_(std::move(health)), telemetry_(telemetry) {}

void VST3PluginNode::prepare(const PrepareInfo& info) {
    active_ = false;
    if (!instance_) return;
    // A session-rate change builds every node again at the new rate (IO-021 (5)); the slot's
    // instance moves to a new plugin with the old one's state, since the old graph may still hold it.
    // DW-211 (T-097): so does a change of process mode (offline), which needs setupProcessing.
    if (instance_->isPrepared() &&
        (instance_->preparedRate() != info.sampleRate || instance_->preparedMaxBlock() != info.maxBlock ||
         instance_->preparedOffline() != info.offline)) {
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
    if (auto prepared = instance_->prepare(info.sampleRate, info.maxBlock, info.offline); !prepared) {
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
    // AUTO-003 (DW-233): the wrap frame, if automation registered after-wrap values this block.
    const uint32_t wrap = wrapFrame(ctx, firstParam_, tracked_, ctx.numFrames);
    for (uint32_t i = 0; i < tracked_; ++i) {
        const ParamID id = firstParam_ + i;
        const uint32_t generation = ctx.params.generation(id);
        float after = 0.0f;
        const bool jumps = wrap > 0 && ctx.params.afterWrap(id, after) && __builtin_isfinite(after);
        if (primed_ && generation == lastGeneration_[i] && !jumps) continue;
        lastGeneration_[i] = generation;
        float value = ctx.params.get(id);
        if (!__builtin_isfinite(value) || !writable_[i]) continue;  // not set, or read-only
        value = std::clamp(value, 0.0f, 1.0f);
        if (jumps) {
            after = std::clamp(after, 0.0f, 1.0f);
            if (value != lastPushed_[i]) instance_->pushParam(i, value);
            instance_->pushParamJump(i, value, after, wrap);
            lastPushed_[i] = after;
            ++paramEvents_;
            continue;
        }
        if (value == lastPushed_[i]) continue;
        instance_->pushParam(i, value);
        lastPushed_[i] = value;
        ++paramEvents_;
    }
    primed_ = true;
}

// DW-242 (T-097): see the header. The slots are pushed again afterwards (as on the first block),
// so the plugin's parameters are the model's from the reset on.
void VST3PluginNode::reset() DAW_RT {
    if (!active_) return;
    // The export's own thread normally reset the plugin just before (VST3PluginHost::resetAll);
    // otherwise the worker does it and the node renders as if absent until it is done.
    if (!instance_->consumeFreshReset()) instance_->requestReset();
    std::fill(lastPushed_.begin(), lastPushed_.end(), std::numeric_limits<float>::quiet_NaN());
    primed_ = false;
}

void VST3PluginNode::process(ProcessContext& ctx, NodeIO& io) DAW_RT {
    const uint32_t n = ctx.numFrames;
    if (n == 0) return;
    const std::size_t bytes = std::size_t{io.audioOut.numFrames} * sizeof(float);
    // DW-242: a reset still running on the worker: render as if absent meanwhile.
    if (!active_ || instance_->resetBusy()) {
        passThrough(io);
        return;
    }
    (void)instance_->consumeFreshReset();  // DW-242: a fresh mark lasts until the plugin renders
    pushParams(ctx);
    for (const MidiEvent& event : io.midiIn) instance_->addMidi(event, n);
    // DW-225 (T-097): bypass turned on: this is the last block the plugin gets until it is enabled
    // again (BypassNode), so it releases what it holds now.
    if (bypassParam_ != kNoBypassParam && ctx.params.get(bypassParam_) >= 0.5f) instance_->releaseHeldNotes(n - 1);
    instance_->setTransport(ctx.transport);
    if (!instance_->render(io, n)) {
        for (uint32_t c = 0; c < io.audioOut.numChannels; ++c) std::memset(io.audioOut.channels[c], 0, bytes);
        return;
    }
    // PLUG-022
    if (guardPluginOutput(io.audioOut, n, telemetry_, health_.get())) nanBlocks_.fetch_add(1, std::memory_order_relaxed);
}

} // namespace daw
