#pragma once
// PLUG-010 (T-061): one instantiated Audio Unit (`AUAudioUnit`) and everything needed to render
// it without allocating: the render/MIDI/parameter blocks, a preallocated AudioBufferList and
// scratch buffers. Plain C++ API over an ObjC++ implementation (AUInstance.mm), so nodes, the
// facade and tests never see Objective-C types.
//
// Threads. Instantiation, prepare, state, info and destruction are non-RT (daw.compile, the
// facade's callers, daw.reclaim); they serialize on an internal mutex. The RT calls (scheduleParam,
// scheduleMIDI, setTransport, render) are made by one node at a time on the audio thread: the
// instance is shared by the AUPluginNodes of one device slot across configVersion bumps (PLUG-010,
// AUPluginHost), and only one RenderGraph renders per block, so they never overlap.
//
// RT safety. The render path calls only the blocks the AU vended at prepare (renderBlock,
// scheduleMIDIEventBlock, scheduleParameterBlock), which the SDK declares nonblocking, and the
// pull-input / transport blocks below, which only copy. No Objective-C message is sent. Whether
// the AU itself allocates inside its render is checked at runtime by the RT trap (CONV §5.3):
// Apple's AUDelay, AUSampler and AUMIDISynth don't (AUPluginTests), so there is no RtScope
// exemption.
//
// PLUG-013: the AU's `latency` is read at prepare and observed (KVO) afterwards; a change updates
// latencySamples() and is reported through the LatencyReporter of the node that uses the instance
// last (setLatencyReporter), from a dispatch queue, never from the thread that changed it.
//
// PLUG-014: if the AU has an aux input bus (bus 1), it is enabled with the main bus's channel
// count and fed from NodeIO::sidechain (silence when nothing is routed there).
//
// DW-214, V2 Audio Units (AUDelay, AUSampler, most third-party AUs) run behind Apple's
// AUAudioUnitV2Bridge, whose parameter tree follows the AU asynchronously from a private listener
// queue. Two consequences:
//   - params(true) reads that tree, so a value changed by a render-thread event shows up a little
//     later (~1 ms, a few ms under load), not when render() returns;
//   - Apple's listener crashes the process if the bridge is deallocated while it still has
//     messages. Destroying an AUInstance therefore stops rendering at once but releases a bridged
//     unit only after a grace period, on a utility queue (see AUInstance.mm). pendingV2Releases()
//     counts those not released yet;
//   - CoreAudio aborts if one V2 AU initializes while another uninitializes on another thread, so
//     prepare and destruction take one process-wide lifecycle lock (non-RT; render never takes it).

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "core/NodeIO.h"
#include "core/Realtime.h"
#include "core/Result.h"
#include "graph/LatencyReporter.h"
#include "plugins/AUIdentifier.h"
#include "time/TransportBlock.h"

namespace daw {

// PLUG-015: one AU parameter, in the order of the AU's parameter tree (`allParameters`). A node's
// param slot i drives the parameter at index i.
struct AUParamInfo {
    uint64_t address = 0;
    std::string identifier;
    std::string name;
    std::string unit;
    float min = 0, max = 1;
    float value = 0;          // when read (AUInstance::params(true)), else at instantiation
    bool canRamp = false;     // kAudioUnitParameterFlag_CanRamp
    bool writable = true;
};

class AUInstance {
public:
    // Non-RT. Instantiates the component in-process. An AUv3 that can't load in-process is loaded
    // out of process (kAudioComponentInstantiation_LoadOutOfProcess), waiting up to
    // `timeoutSeconds`. notFound if no such component is installed.
    static Result<std::shared_ptr<AUInstance>> instantiate(const AUComponentID& component,
                                                           double timeoutSeconds = 10.0);
    ~AUInstance();
    AUInstance(const AUInstance&) = delete;
    AUInstance& operator=(const AUInstance&) = delete;

    const AUComponentID& component() const { return component_; }
    std::string identifier() const { return formatAUIdentifier(component_); }
    std::string name() const;
    bool hasAudioInput() const;   // a main input bus (effects); false for instruments
    bool acceptsMIDI() const;     // vends a scheduleMIDIEventBlock
    bool hasAuxInput() const;     // an aux input bus exists (PLUG-014)

    // Non-RT. Sets the bus formats (stereo, else the bus's own channel count, 1 or 2),
    // maximumFramesToRender and the host transport blocks, then allocates render resources. A
    // call at the rate and maxBlock it is already prepared for does nothing.
    Result<void> prepare(double sampleRate, uint32_t maxBlock);
    bool isPrepared() const { return prepared_.load(std::memory_order_acquire); }
    double preparedRate() const { return rate_; }
    uint32_t preparedMaxBlock() const { return maxBlock_; }
    uint32_t inputChannels() const { return inChannels_; }
    uint32_t outputChannels() const { return outChannels_; }
    bool sidechainEnabled() const { return sidechainChannels_ > 0; }

    // PLUG-015. Fixed when instantiated; `current` re-reads every value (non-RT).
    const std::vector<AUParamInfo>& params() const { return params_; }
    std::vector<AUParamInfo> params(bool current) const;

    // PLUG-016, non-RT: `fullState` as a binary plist, and back. setFullState fails with
    // invalidArgument for bytes that aren't a plist dictionary.
    Result<std::vector<uint8_t>> fullState() const;
    Result<void> setFullState(const std::vector<uint8_t>& state);

    // PLUG-013. Samples at the prepared rate; readable from any thread.
    uint32_t latencySamples() const;
    double tailSeconds() const;
    void setLatencyReporter(LatencyReporter reporter);

    // RT. Parameter `index` (params()) to `value`, ramping over `rampFrames` from the start of the
    // next render; value must be in range (the node clamps).
    void scheduleParam(uint32_t index, float value, uint32_t rampFrames) DAW_RT;
    // RT. A MIDI event at its frame offset into the next render (clamped to the block).
    void scheduleMIDI(const MidiEvent& event, uint32_t numFrames) DAW_RT;
    // RT. What the AU's musicalContextBlock / transportStateBlock report during the next render.
    void setTransport(const TransportBlock& transport) DAW_RT;
    // RT. Renders `numFrames` (1 … preparedMaxBlock) into io.audioOut from io.audioIn and
    // io.sidechain. Returns false (output untouched) if the AU reported an error.
    bool render(const NodeIO& io, uint32_t numFrames) DAW_RT;
    uint64_t renderErrors() const { return renderErrors_.load(std::memory_order_relaxed); }

    // DW-214: bridged units whose deferred release hasn't happened yet (process-wide, any thread).
    static uint32_t pendingV2Releases();

    // Shared with the KVO observer and its dispatched reports, which may outlive the instance.
    struct LatencyState;
    struct Impl;  // Objective-C side (AUInstance.mm)

private:
    explicit AUInstance(const AUComponentID& component);

    AUComponentID component_;
    Impl* impl_ = nullptr;
    std::shared_ptr<LatencyState> latency_;
    std::vector<AUParamInfo> params_;
    std::atomic<bool> prepared_{false};
    double rate_ = 0;
    uint32_t maxBlock_ = 0;
    uint32_t inChannels_ = 0, outChannels_ = 0, sidechainChannels_ = 0;
    std::atomic<uint64_t> renderErrors_{0};
};

} // namespace daw
