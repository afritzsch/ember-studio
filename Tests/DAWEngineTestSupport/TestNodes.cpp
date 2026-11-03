#include "TestNodes.h"

#include <bit>
#include <cmath>
#include <cstring>
#include <limits>
#include <numbers>
#include <utility>

#include "RtTrapTestSupport.h"
#include "facade/FacadeOptions.h"

namespace daw::testing {

namespace {

void fillAll(const AudioBufferView& out, float value) DAW_RT {
    for (uint32_t c = 0; c < out.numChannels; ++c)
        for (uint32_t f = 0; f < out.numFrames; ++f) out.channels[c][f] = value;
}

} // namespace

// MARK: SineNode

void SineNode::prepare(const PrepareInfo& info) {
    rate_ = info.sampleRate;
    frame_ = 0;
}

void SineNode::process(ProcessContext&, NodeIO& io) DAW_RT {
    const AudioBufferView& out = io.audioOut;
    // The phase comes from the frame count, not an accumulated sum, so it doesn't drift.
    const double w = 2.0 * std::numbers::pi * hz_ / rate_;
    for (uint32_t f = 0; f < out.numFrames; ++f) {
        const float x = level_ * static_cast<float>(std::sin(w * static_cast<double>(frame_ + f)));
        for (uint32_t c = 0; c < out.numChannels; ++c) out.channels[c][f] = x;
    }
    frame_ += out.numFrames;
}

// MARK: ImpulseNode

void ImpulseNode::process(ProcessContext&, NodeIO& io) DAW_RT {
    const AudioBufferView& out = io.audioOut;
    for (uint32_t f = 0; f < out.numFrames; ++f) {
        const uint64_t n = frame_ + f;
        const bool hit = n == first_ || (period_ > 0 && n > first_ && (n - first_) % period_ == 0);
        for (uint32_t c = 0; c < out.numChannels; ++c) out.channels[c][f] = hit ? level_ : 0.0f;
    }
    frame_ += out.numFrames;
}

// MARK: FakeLatencyNode

void FakeLatencyNode::prepare(const PrepareInfo&) {
    capacity_ = std::bit_ceil(latency_ + 1);
    ring_.assign(2 * std::size_t{capacity_}, 0.0f);
    write_ = 0;
}

void FakeLatencyNode::reset() DAW_RT {
    for (float& x : ring_) x = 0.0f;
    write_ = 0;
}

void FakeLatencyNode::process(ProcessContext&, NodeIO& io) DAW_RT {
    const AudioBufferView& out = io.audioOut;
    const uint32_t mask = capacity_ - 1;
    for (uint32_t c = 0; c < out.numChannels; ++c) {
        if (c >= 2) {
            std::memset(out.channels[c], 0, std::size_t{out.numFrames} * sizeof(float));
            continue;
        }
        float* ring = ring_.data() + std::size_t{c} * capacity_;
        const float* in = c < io.audioIn.numChannels ? io.audioIn.channels[c] : nullptr;
        for (uint32_t f = 0; f < out.numFrames; ++f) {
            const uint32_t at = write_ + f;
            ring[at & mask] = in ? in[f] : 0.0f;
            out.channels[c][f] = ring[(at - latency_) & mask];
        }
    }
    write_ += out.numFrames;
}

// MARK: AllocatingNode, NaNNode

void AllocatingNode::process(ProcessContext&, NodeIO& io) DAW_RT {
    if (io.audioOut.numFrames > 0) {
        // Deliberate (the point of this node): the trap must count it.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
        (void)runProbe(RtProbe::malloc);
#pragma clang diagnostic pop
    }
    fillAll(io.audioOut, 0.0f);
}

void NaNNode::process(ProcessContext&, NodeIO& io) DAW_RT {
    fillAll(io.audioOut, std::numeric_limits<float>::quiet_NaN());
}

// MARK: SidechainMixNode

void SidechainMixNode::process(ProcessContext&, NodeIO& io) DAW_RT {
    const AudioBufferView& out = io.audioOut;
    const AudioBufferView& in = io.audioIn;
    const AudioBufferView& sc = io.sidechain;
    for (uint32_t c = 0; c < out.numChannels; ++c) {
        float* dst = out.channels[c];
        const float* main = c < in.numChannels ? in.channels[c] : nullptr;
        const float* key = c < sc.numChannels ? sc.channels[c] : nullptr;
        for (uint32_t f = 0; f < out.numFrames; ++f)
            dst[f] = (main ? main[f] : 0.0f) + (key ? level_ * key[f] : 0.0f);
    }
    // Single writer (the audio thread): load + store, no read-modify-write needed.
    blocks_.store(blocks_.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
    if (!sc.empty()) routed_.store(routed_.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
}

// MARK: Registration

std::unique_ptr<Node> makeTestNode(const TestNodeSpec& spec) {
    switch (spec.type) {
    case TestNodeType::sine: return std::make_unique<SineNode>(spec.frequency, spec.level);
    case TestNodeType::impulse: return std::make_unique<ImpulseNode>(spec.samples, spec.level, spec.offset);
    case TestNodeType::fakeLatency: return std::make_unique<FakeLatencyNode>(spec.samples);
    case TestNodeType::allocating: return std::make_unique<AllocatingNode>();
    case TestNodeType::nan: return std::make_unique<NaNNode>();
    case TestNodeType::sidechainMix: return std::make_unique<SidechainMixNode>(spec.level);
    }
    return nullptr;
}

Result<void> registerTestNode(NodeRegistry& registry, const TestNodeSpec& spec) {
    NodeKindInfo info;
    if (spec.kind == NodeKind::audioClipPlayer) {
        const NodeKindInfo* real = registry.find(NodeKind::audioClipPlayer);
        if (!real) return makeError(ErrorCode::invalidArgument, "no audioClipPlayer to stand in for");
        info = *real;
        info.create = [spec, create = real->create](const NodeCreateInfo& create_info) -> Result<std::unique_ptr<Node>> {
            if (!create_info.clips.empty()) return create(create_info);
            return makeTestNode(spec);
        };
    } else {
        info.create = [spec](const NodeCreateInfo&) -> Result<std::unique_ptr<Node>> { return makeTestNode(spec); };
    }
    return registry.set(spec.kind, std::move(info));
}

EngineFacade* makeTestFacade(double sampleRate, const TestNodeSpecs& specs) {
    for (std::size_t i = 0; i < specs.size(); ++i)
        for (std::size_t j = i + 1; j < specs.size(); ++j)
            if (specs[i].kind == specs[j].kind) return nullptr;
    FacadeOptions options;
    options.registerNodes = [specs](NodeRegistry& registry) -> Result<void> {
        for (const TestNodeSpec& spec : specs)
            if (auto r = registerTestNode(registry, spec); !r) return r;
        return {};
    };
    DriverConfigPOD config;
    config.sampleRate = sampleRate;
    return EngineFacadeAccess::create(EngineMode::offline, config, std::move(options));
}

} // namespace daw::testing
