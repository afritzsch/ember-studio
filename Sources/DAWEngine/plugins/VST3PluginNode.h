#pragma once
// PLUG-011 (T-062): NodeKind::vst3Plugin, a hosted VST3 plugin as a graph node, the VST3 twin of
// AUPluginNode. Made by VST3PluginHost's factory from the NodeDesc's configJSON
// (VST3PluginConfig.h); renders through a VST3Instance it may share with the slot's earlier nodes.
//
// Audio: the summed main input feeds the plugin's main input bus, its main output bus is the node's
// output (a mono output goes to both channels). An instrument has no input bus.
// Notes in NodeIO::midiIn become VST3 events at their frame offsets.
//
// Sidechain (PLUG-014): the aux input bus, if the plugin has one, is fed from NodeIO::sidechain.
//
// Params (PLUG-015): param slot i (NodeDesc::firstParam + i, i < numParams) drives the parameter
// at index i of IEditController::getParameterInfo (listed by EngineFacade::pluginInfoJSON). At the
// start of each block a slot whose generation moved (or, on the node's first block, any slot) is
// pushed as one point at offset 0 (D-13), clamped to 0…1 (VST3 values are normalized). A NaN slot
// means "not set": the plugin keeps its value. A read-only parameter (a meter) is never pushed.
//
// Latency (PLUG-013): latencySamples() is the plugin's getLatencySamples.
//
// Failure: a node whose plugin couldn't be instantiated or prepared renders as if absent (input
// passed through; an instrument has none, so silence) and the failure is reported once through
// VST3PluginHost as a pluginCrashed event.
//
// NaN guard (PLUG-022, T-064): as AUPluginNode's (plugins/PluginNanGuard.h).
//
// reset() (a locate) does nothing: effects keep their tails (TIME-008).

#include <cstdint>
#include <memory>
#include <vector>

#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/Realtime.h"
#include "graph/LatencyReporter.h"
#include "plugins/PluginNanGuard.h"
#include "plugins/VST3Instance.h"

namespace daw {

class VST3PluginHost;

class VST3PluginNode final : public Node {
public:
    static constexpr uint32_t kMaxParams = 4096;  // DAWModel's DeviceSlot.maxParamIndex + 1

    // `instance` null: the inert node of a failed instantiation.
    VST3PluginNode(NodeID id, std::shared_ptr<VST3Instance> instance, ParamID firstParam, uint32_t numParams,
                   LatencyReporter reporter, std::weak_ptr<VST3PluginHost> host,
                   std::shared_ptr<PluginHealth> health = nullptr, Telemetry* telemetry = nullptr);

    void prepare(const PrepareInfo& info) override;
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;
    uint32_t latencySamples() const override;

    // Non-RT diagnostics and tests.
    bool active() const { return active_; }
    const std::shared_ptr<VST3Instance>& instance() const { return instance_; }
    uint64_t paramEventsPushed() const { return paramEvents_; }
    uint64_t nanBlocks() const { return nanBlocks_.load(std::memory_order_relaxed); }  // PLUG-022

private:
    void pushParams(const ProcessContext& ctx) DAW_RT;

    NodeID id_;
    std::shared_ptr<VST3Instance> instance_;
    ParamID firstParam_;
    uint32_t numParams_;
    LatencyReporter reporter_;
    std::weak_ptr<VST3PluginHost> host_;
    std::shared_ptr<PluginHealth> health_;  // PLUG-022
    Telemetry* telemetry_;
    std::atomic<uint64_t> nanBlocks_{0};

    bool active_ = false;
    // Audio thread only (sized in prepare).
    uint32_t tracked_ = 0;
    std::vector<uint32_t> lastGeneration_;
    std::vector<float> lastPushed_;  // NaN: nothing pushed yet
    std::vector<uint8_t> writable_;
    bool primed_ = false;
    uint64_t paramEvents_ = 0;
};

} // namespace daw
