#include "plugins/AUPluginNode.h"

#include <algorithm>
#include <cstring>
#include <limits>

#include "automation/WrapJump.h"
#include "core/ProcessContext.h"
#include "graph/PassThrough.h"
#include "plugins/AUPluginHost.h"

namespace daw {

AUPluginNode::AUPluginNode(NodeID id, std::shared_ptr<AUInstance> instance, bool instrument, ParamID firstParam,
                           uint32_t numParams, LatencyReporter reporter, std::weak_ptr<AUPluginHost> host,
                           std::shared_ptr<PluginHealth> health, Telemetry* telemetry)
    : id_(id), instance_(std::move(instance)), instrument_(instrument), firstParam_(firstParam),
      numParams_(numParams), reporter_(std::move(reporter)), host_(std::move(host)), health_(std::move(health)),
      telemetry_(telemetry) {}

void AUPluginNode::prepare(const PrepareInfo& info) {
    active_ = false;
    if (!instance_) return;
    // A session-rate change builds every node again at the new rate (IO-021 (5)); the slot's
    // instance moves to a new AU with the old one's state, since the old graph may still hold it.
    // DW-211 (T-097): so does a change of render mode (offline), set before render resources.
    if (instance_->isPrepared() &&
        (instance_->preparedRate() != info.sampleRate || instance_->preparedMaxBlock() != info.maxBlock ||
         instance_->preparedOffline() != info.offline)) {
        auto host = host_.lock();
        auto fresh = host ? host->reinstantiate(id_, instance_)
                          : Result<std::shared_ptr<AUInstance>>(makeError(ErrorCode::internal, "no plugin host"));
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
    retry_.assign(tracked_, 0);  // DW-204
    minValue_.resize(tracked_);
    maxValue_.resize(tracked_);
    canRamp_.resize(tracked_);
    for (uint32_t i = 0; i < tracked_; ++i) {
        minValue_[i] = std::min(params[i].min, params[i].max);
        maxValue_[i] = std::max(params[i].min, params[i].max);
        canRamp_[i] = params[i].canRamp;
    }
    primed_ = false;
    active_ = true;
}

uint32_t AUPluginNode::latencySamples() const { return active_ ? instance_->latencySamples() : 0; }

void AUPluginNode::pushParams(const ProcessContext& ctx) DAW_RT {
    // AUTO-003 (DW-233): the wrap frame, if automation registered after-wrap values this block.
    const uint32_t wrap = wrapFrame(ctx, firstParam_, tracked_, ctx.numFrames);
    for (uint32_t i = 0; i < tracked_; ++i) {
        const ParamID id = firstParam_ + i;
        const uint32_t generation = ctx.params.generation(id);
        float after = 0.0f;
        const bool jumps = wrap > 0 && ctx.params.afterWrap(id, after) && __builtin_isfinite(after);
        if (primed_ && generation == lastGeneration_[i] && !retry_[i] && !jumps) continue;
        lastGeneration_[i] = generation;
        retry_[i] = 0;
        float value = ctx.params.get(id);
        if (!__builtin_isfinite(value)) continue;  // not set: the plugin keeps its value
        value = std::clamp(value, minValue_[i], maxValue_[i]);
        if (value == lastPushed_[i] && !jumps) continue;
        // DW-204 (T-063): the plugin's editor is ahead of the model; don't push it back.
        bool push = value != lastPushed_[i];
        switch (instance_->pushDecision(i, value)) {
        case AUInstance::PushDecision::defer:
            retry_[i] = 1;
            continue;
        case AUInstance::PushDecision::skip:
            lastPushed_[i] = value;
            push = false;
            break;
        case AUInstance::PushDecision::push:
            break;
        }
        // D-13: a block-long ramp where the parameter can ramp; the first push is a step. With a
        // wrap (DW-233) the ramp ends at the wrap frame and the after-wrap value is an event there.
        const bool ramp = canRamp_[i] && lastPushed_[i] == lastPushed_[i];
        if (push) {
            instance_->scheduleParam(i, value, ramp ? (jumps ? wrap : ctx.numFrames) : 0);
            lastPushed_[i] = value;
            ++paramEvents_;
        }
        if (jumps) {
            after = std::clamp(after, minValue_[i], maxValue_[i]);
            instance_->scheduleParam(i, after, 0, wrap);
            lastPushed_[i] = after;
            ++paramEvents_;
        }
    }
    primed_ = true;
}

// DW-242 (T-097): see the header. A reset keeps the plugin's parameters, so nothing is pushed
// again: re-pushing every set slot would put them all into the export's first block, and a V2 AU
// behind Apple's bridge allocates when one render carries that many parameter events (AUSampler's
// 11; see the T-097 report).
void AUPluginNode::reset() DAW_RT {
    if (!active_) return;
    if (!instance_->consumeFreshReset()) instance_->requestReset();
}

void AUPluginNode::process(ProcessContext& ctx, NodeIO& io) DAW_RT {
    const uint32_t n = ctx.numFrames;
    if (n == 0) return;
    const std::size_t bytes = std::size_t{io.audioOut.numFrames} * sizeof(float);
    // DW-242: a reset still running on the worker: render as if absent meanwhile.
    if (!active_ || instance_->resetBusy()) {
        if (instrument_) {
            for (uint32_t c = 0; c < io.audioOut.numChannels; ++c) std::memset(io.audioOut.channels[c], 0, bytes);
        } else {
            passThrough(io);
        }
        return;
    }
    (void)instance_->consumeFreshReset();  // DW-242: a fresh mark lasts until the AU renders
    pushParams(ctx);
    for (const MidiEvent& event : io.midiIn) instance_->scheduleMIDI(event, n);
    // DW-225 (T-097): bypass turned on: the AU's last block until it is enabled again (BypassNode).
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
