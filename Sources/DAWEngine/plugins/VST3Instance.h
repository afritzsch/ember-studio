#pragma once
// PLUG-011 (T-062): one instantiated VST3 plugin (IComponent + IAudioProcessor + IEditController)
// and everything needed to render it without allocating: a preallocated ProcessData and audio bus
// buffers, fixed-capacity event and parameter lists, a ProcessContext. A plain C++ API over the
// SDK (VST3Instance.cpp), so nodes, the facade and tests never see SDK types.
//
// Threads. Instantiation, prepare, state, info and destruction are non-RT (daw.compile, the
// facade's callers, daw.reclaim); they serialize on an internal mutex. The RT calls (pushParam,
// addMidi, setTransport, render) are made by one node at a time on the audio thread: the instance
// is shared by the VST3PluginNodes of one device slot across configVersion bumps (VST3PluginHost)
// and only one RenderGraph renders per block, so they never overlap.
//
// RT safety. The render path touches only memory sized at prepare. The SDK's EventList and
// ParameterChanges helpers grow std::vectors, so the lists here are our own fixed-capacity ones.
// process() is called through the plugin's vtable; whether the plugin itself allocates is checked
// at runtime by the RT trap (CONV §5.3), not assumed.
//
// PLUG-013: getLatencySamples at prepare. restartComponent(kLatencyChanged) may come on any thread
// (a plugin's audio thread included), so the IComponentHandler only sets an atomic flag; a 50 ms
// timer on a utility queue reads the new latency off the RT thread and reports it through the
// LatencyReporter of the node that uses the instance last (MIX-024).
//
// PLUG-014: a kAux input bus, if the plugin has one, is activated and fed from NodeIO::sidechain
// (silence when nothing is routed there).
//
// PLUG-016: state() is one blob: magic "EVS3", u32 version 1, u64 component length, component
// state, u64 controller length, controller state (little-endian). setState restores the component
// and calls setComponentState and setState on the controller. Both run off the RT thread.
//
// T-063 seam: editController() hands out the controller for createPluginView (IPlugView, PLUG-017).
// The plugin → model direction of PLUG-015 (performEdit etc., DW-204) is a safe no-op here.

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "core/NodeIO.h"
#include "core/Realtime.h"
#include "core/Result.h"
#include "graph/LatencyReporter.h"
#include "plugins/VST3PluginConfig.h"
#include "time/TransportBlock.h"

namespace Steinberg::Vst {
class IEditController;
}

namespace daw {

// PLUG-015: one parameter of the plugin, in IEditController::getParameterInfo order. A node's
// param slot i drives the parameter at index i. VST3 values are normalized, so min/max are 0/1
// and slot values are normalized too.
struct VST3ParamInfo {
    uint32_t id = 0;       // ParamID
    std::string name;
    std::string unit;
    float min = 0, max = 1;
    float value = 0;       // when read (VST3Instance::params(true)), else at instantiation
    bool writable = true;  // false: read-only (a meter); the host doesn't push it
};

class VST3Instance {
public:
    // Non-RT. Loads the module and initializes the plugin's component and controller, connected
    // as the SDK expects. notFound for a missing bundle or class.
    static Result<std::shared_ptr<VST3Instance>> instantiate(const VST3PluginID& plugin);
    ~VST3Instance();
    VST3Instance(const VST3Instance&) = delete;
    VST3Instance& operator=(const VST3Instance&) = delete;

    const VST3PluginID& plugin() const { return plugin_; }
    std::string identifier() const { return plugin_.identifier(); }
    const std::string& name() const { return name_; }
    bool hasAudioInput() const;   // a main (kMain) input bus; false for instruments
    bool acceptsMIDI() const;     // an event input bus
    bool hasAuxInput() const;     // a kAux audio input bus (PLUG-014)

    // Non-RT. Bus arrangements (stereo, else mono, else the plugin's own), bus activation,
    // setupProcessing, setActive, setProcessing. A call at the rate and maxBlock it is already
    // prepared for does nothing.
    Result<void> prepare(double sampleRate, uint32_t maxBlock);
    bool isPrepared() const { return prepared_.load(std::memory_order_acquire); }
    double preparedRate() const { return rate_; }
    uint32_t preparedMaxBlock() const { return maxBlock_; }
    uint32_t inputChannels() const { return inChannels_; }
    uint32_t outputChannels() const { return outChannels_; }
    bool sidechainEnabled() const { return sidechainChannels_ > 0; }

    // PLUG-015. Fixed when instantiated; `current` re-reads every value (non-RT).
    const std::vector<VST3ParamInfo>& params() const { return params_; }
    std::vector<VST3ParamInfo> params(bool current) const;

    // PLUG-016, non-RT: the state container (above) and back. setState fails with invalidArgument
    // for bytes that aren't a container, or that the plugin refuses.
    Result<std::vector<uint8_t>> state() const;
    Result<void> setState(const std::vector<uint8_t>& state);

    // PLUG-013. Samples; readable from any thread.
    uint32_t latencySamples() const;
    double tailSeconds() const;
    void setLatencyReporter(LatencyReporter reporter);

    // RT. Parameter `index` (params()) to `normalized` for the next render: one point at sample
    // offset 0 (D-13). Call at most once per parameter per block.
    void pushParam(uint32_t index, float normalized) DAW_RT;
    // RT. A MIDI note on/off becomes a VST3 event at its frame offset (clamped to the block);
    // other messages are ignored.
    void addMidi(const MidiEvent& event, uint32_t numFrames) DAW_RT;
    // RT. Fills the ProcessContext the plugin sees during the next render.
    void setTransport(const TransportBlock& transport) DAW_RT;
    // RT. Renders `numFrames` (1 … preparedMaxBlock) into io.audioOut from io.audioIn and
    // io.sidechain; clears the block's events and param changes. False (output untouched) if the
    // plugin reported an error.
    bool render(const NodeIO& io, uint32_t numFrames) DAW_RT;
    uint64_t renderErrors() const { return renderErrors_.load(std::memory_order_relaxed); }

    // T-063 seam (non-RT): the controller, for IEditController::createView. Null if the plugin has
    // none.
    Steinberg::Vst::IEditController* editController() const;

    struct Impl;  // SDK side (VST3Instance.cpp)

private:
    VST3Instance(VST3PluginID plugin, std::shared_ptr<Impl> impl);
    void startLatencyTimer();

    VST3PluginID plugin_;
    std::string name_;
    std::shared_ptr<Impl> impl_;
    std::vector<VST3ParamInfo> params_;
    std::atomic<bool> prepared_{false};
    double rate_ = 0;
    uint32_t maxBlock_ = 0;
    uint32_t inChannels_ = 0, outChannels_ = 0, sidechainChannels_ = 0;
    std::atomic<uint64_t> renderErrors_{0};
};

} // namespace daw
