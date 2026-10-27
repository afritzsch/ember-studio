#pragma once
// T-013 test helpers (private to DAWEngineTestSupport), shared by ClipPlayerChecks.cpp and
// ChannelStripChecks.cpp: in-RAM assets, and an Engine + GraphBuilder rig that renders through
// the transport with the registered built-in nodes (nodes/BuiltinNodes.h), counting RT
// violations in its own scope (DW-019).

#include <chrono>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <thread>
#include <utility>
#include <vector>

#include "core/Engine.h"
#include "core/RtTrap.h"
#include "daw/GraphDescription.h"
#include "graph/GraphBuilder.h"
#include "graph/NodeRegistry.h"
#include "io/AudioAsset.h"
#include "nodes/BuiltinNodes.h"

namespace daw::testing::nodes {

inline constexpr double kRate = 48000.0;
// At 120 bpm and 48 kHz one tick is exactly 25 samples (48000 · 60 / 120 / 960).
inline constexpr int64_t kSamplesPerTick = 25;

// An asset of `channels` × `frames` where sample (c, i) = value(c, i). Freed wherever its last
// reference goes (RetireHook::immediate), which tests keep off the audio thread.
inline AudioAssetRef makeAsset(uint64_t assetID, uint32_t channels, int64_t frames,
                               const std::function<float(uint32_t, int64_t)>& value,
                               double sampleRate = kRate) {
    auto builder = AudioAssetBuilder::make(channels, frames);
    if (!builder) return {};
    for (uint32_t c = 0; c < channels; ++c)
        for (int64_t i = 0; i < frames; ++i) builder.value().channel(c)[i] = value(c, i);
    auto asset = builder.value().finish(assetID, sampleRate, frames, RetireHook::immediate());
    if (!asset) return {};
    return std::move(asset).value();
}

// A description with a master (id 1, limiter off) at 120 bpm 4/4.
inline GraphDescription baseDescription() {
    GraphDescription d{1, {}, {}, {}, {}, {{{0, 120.0}}, {{0, 4, 4}}}, 1};
    d.nodes.push_back(NodeDesc{1, NodeKind::master, 1, 0, 0, {}});
    return d;
}

inline ClipDesc clip(NodeID player, uint64_t clipID, Tick start, Tick length, uint64_t assetID,
                     int64_t offset = 0, float gain = 1.0f, Tick fadeIn = 0, Tick fadeOut = 0) {
    return ClipDesc{player, clipID, start, length, assetID, offset, gain, fadeIn, fadeOut};
}

class Rig {
public:
    Rig() : builder_(makeRegistry(), kRate, kMaxBlock) {}

    void addAsset(AudioAssetRef asset) {
        // Read the ID first: the right side of = (which empties `asset`) is sequenced first.
        const uint64_t id = asset->assetID;
        assets_[id] = std::move(asset);
    }
    const AudioAssetRef& asset(uint64_t id) { return assets_[id]; }
    void dropAssets() { assets_.clear(); }

    Engine& engine() { return engine_; }
    const GraphBuilder& builder() const { return builder_; }
    Transport& transport() { return engine_.transport(); }

    // Builds and publishes; false if the builder rejects it.
    bool publish(const GraphDescription& desc) {
        auto graph = builder_.build(desc, engine_.nodes(), engine_.params());
        if (!graph) return false;
        engine_.publish(std::move(graph).value());
        return true;
    }
    Result<std::unique_ptr<RenderGraph>> build(const GraphDescription& desc) {
        return builder_.build(desc, engine_.nodes(), engine_.params());
    }

    // Renders `numFrames` frames and appends them to left()/right(). Each render runs in its own
    // RtScope, whose count is added to violations().
    void render(uint32_t numFrames) {
        std::vector<float> l(numFrames, -99.0f), r(numFrames, -99.0f);
        float* ptrs[2] = {l.data(), r.data()};
        RenderTarget target;
        target.output = AudioBufferView{ptrs, 2, numFrames};
        {
            RtScope scope;
            engine_.render(target, numFrames);
            violations_ += scope.violations();
        }
        left_.insert(left_.end(), l.begin(), l.end());
        right_.insert(right_.end(), r.begin(), r.end());
    }
    // Renders `total` frames in blocks drawn from `nextBlock()` (which may return 0).
    void renderFrames(int64_t total, const std::function<uint32_t()>& nextBlock) {
        const int64_t end = static_cast<int64_t>(left_.size()) + total;
        for (int guard = 0; static_cast<int64_t>(left_.size()) < end && guard < 1'000'000; ++guard) {
            const auto remaining = static_cast<uint32_t>(end - static_cast<int64_t>(left_.size()));
            render(std::min(nextBlock(), remaining));
        }
    }

    const std::vector<float>& left() const { return left_; }
    const std::vector<float>& right() const { return right_; }
    void clearOutput() {
        left_.clear();
        right_.clear();
    }
    uint64_t violations() const { return violations_; }

    // Waits until daw.reclaim has run `n` more passes.
    bool reclaimPasses(uint64_t n) {
        const uint64_t start = engine_.reclaimer().passes();
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        while (engine_.reclaimer().passes() < start + n) {
            if (std::chrono::steady_clock::now() > deadline) return false;
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        return true;
    }

private:
    NodeRegistry makeRegistry() {
        NodeRegistry registry = NodeRegistry::withBuiltins();
        (void)registerBuiltinNodes(
            registry,
            [this](uint64_t id) -> AudioAssetRef {
                auto it = assets_.find(id);
                return it == assets_.end() ? AudioAssetRef{} : it->second;
            },
            &engine_.telemetry());
        return registry;
    }

    // Declared before the engine, so the engine (and the nodes it holds) goes first.
    std::map<uint64_t, AudioAssetRef> assets_;
    Engine engine_;
    GraphBuilder builder_;
    std::vector<float> left_, right_;
    uint64_t violations_ = 0;
};

} // namespace daw::testing::nodes
