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
// reset() (DW-242, T-097): only the DW-063 reset before an offline render reaches a plugin node
// (live locates reset timeline nodes only, TIME-008). An export resets its plugins on its own,
// non-RT thread before the first block (VST3PluginHost::resetAll), so reset() finds the reset done
// and only re-pushes every set param slot in the next block. Without that (a bare Engine reset) it
// asks the reset worker and returns at once; the node renders as if absent until the worker is done
// (PluginReset.h). It never waits on the render thread.
//
// Offline (DW-211, T-097): PrepareInfo::offline prepares the plugin in kOffline process mode.
//
// Loop wraps (AUTO-003, DW-233, T-097): in a block where automation registered a value after a
// wrap (ParamSlotTable::afterWrap), the param's queue gets the block's value at offset 0, the same
// value at the frame before the wrap and the after-wrap value at the wrap frame, so the plugin
// doesn't ramp across the loop's discontinuity.
//
// Bypass (DW-225, T-097): BypassNode stops processing the node while it is bypassed, so in the
// block where its bypass slot (NodeDesc::bypassParam, setBypassParam) turns on, its last processed
// block, the plugin gets note-offs for every note it holds and a mapped CC 123 on each channel
// that had notes (VST3Instance::releaseHeldNotes) at the block's last frame. No note hangs.

#include <cstdint>
#include <memory>
#include <vector>

#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/Realtime.h"
#include "daw/GraphDescription.h"
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
    void reset() DAW_RT override;  // DW-242 (T-097)
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;
    // DW-225 (T-097): the node's host-bypass slot (NodeDesc::bypassParam; kNoBypassParam: none).
    void setBypassParam(ParamID param) { bypassParam_ = param; }
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
    ParamID bypassParam_ = kNoBypassParam;  // DW-225

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
