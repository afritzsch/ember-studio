#pragma once
// PLUG-010 (T-061): NodeKind::auPlugin, a hosted Audio Unit as a graph node. Made by AUPluginHost's
// factory from the NodeDesc's configJSON (AUPluginConfig.h); renders through an AUInstance it may
// share with the slot's earlier nodes (see AUPluginHost.h).
//
// Audio (PLUG-010): the summed main input feeds the AU's input bus 0, its output bus 0 is the
// node's output (a mono AU's output goes to both channels). An instrument ('aumu') has no input.
// MIDI in NodeIO::midiIn goes to scheduleMIDIEventBlock at each event's frame offset, before the
// block renders; an AU without a MIDI block ignores it.
//
// Sidechain (PLUG-014, DW-159): the AU's aux input bus (bus 1), if it has one, is fed from
// NodeIO::sidechain, i.e. the node's sidechain port (MIX-008 graph toPort 0); silence when nothing
// is routed there.
//
// Params (PLUG-015): param slot i (NodeDesc::firstParam + i, i < numParams) drives the AU's
// parameter at index i of its parameter tree (AUInstance::params, `allParameters` order; listed by
// EngineFacade::pluginInfoJSON). At the start of each block a slot whose generation moved (or, on
// the node's first block, any slot) is pushed as a render-thread parameter event
// (scheduleParameterBlock; never AUParameter.setValue on the audio thread), clamped to the
// parameter's range and ramped over the block when the parameter can ramp (D-13). A NaN slot
// means "not set": the plugin keeps its own value (the model writes NaN for params it has no
// value for). A value equal to the last one pushed isn't pushed again.
//
// Latency (PLUG-013): latencySamples() is the AU's `latency` at the session rate. A change
// (observed through KVO) reaches GraphCompiler through this node's LatencyReporter (MIX-024).
//
// Failure: a node whose AU couldn't be instantiated or prepared renders as if absent — an effect
// passes its input through, an instrument is silent — and the failure is reported once through
// AUPluginHost (a pluginCrashed event carrying the error). It never renders the AU.
//
// reset() (a locate) does nothing: effects keep their tails (TIME-008), and the MIDI source sends
// the note-offs (DSP-003).

#include <cstdint>
#include <memory>
#include <vector>

#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/ParamSlotTable.h"
#include "core/Realtime.h"
#include "graph/LatencyReporter.h"
#include "plugins/AUInstance.h"

namespace daw {

class AUPluginHost;

class AUPluginNode final : public Node {
public:
    // The most param slots a node drives (DAWModel's DeviceSlot.maxParamIndex + 1).
    static constexpr uint32_t kMaxParams = 4096;

    // `instance` null: the inert node of a failed instantiation. `instrument`: what an inert node
    // outputs (silence) and whether there is an input to pass through.
    AUPluginNode(NodeID id, std::shared_ptr<AUInstance> instance, bool instrument, ParamID firstParam,
                 uint32_t numParams, LatencyReporter reporter, std::weak_ptr<AUPluginHost> host);

    void prepare(const PrepareInfo& info) override;
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;
    uint32_t latencySamples() const override;

    // Non-RT diagnostics and tests.
    bool active() const { return active_; }
    const std::shared_ptr<AUInstance>& instance() const { return instance_; }
    uint64_t paramEventsPushed() const { return paramEvents_; }

private:
    void pushParams(const ProcessContext& ctx) DAW_RT;

    NodeID id_;
    std::shared_ptr<AUInstance> instance_;
    bool instrument_;
    ParamID firstParam_;
    uint32_t numParams_;
    LatencyReporter reporter_;
    std::weak_ptr<AUPluginHost> host_;

    bool active_ = false;
    // Audio thread only (sized in prepare).
    uint32_t tracked_ = 0;
    std::vector<uint32_t> lastGeneration_;
    std::vector<float> lastPushed_;  // NaN: nothing pushed yet
    std::vector<float> minValue_, maxValue_;
    std::vector<uint8_t> canRamp_;
    bool primed_ = false;
    uint64_t paramEvents_ = 0;
};

} // namespace daw
