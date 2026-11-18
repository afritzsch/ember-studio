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
#include "plugins/PluginEditQueue.h"
#include "plugins/PluginReset.h"
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
    // DW-213 (T-094): discrete values as 06's ParamInfo::steps (0 continuous; a Boolean param 1,
    // an Indexed one max − min). `labels` (steps + 1 value names: the AU's valueStrings, else its
    // strings for each step) and `display` (the AU's string for `value`, when it has strings) are
    // filled by params(true) only; labels only for steps ≤ kMaxLabelledSteps.
    uint32_t steps = 0;
    std::vector<std::string> labels;
    std::string display;
    static constexpr uint32_t kMaxLabelledSteps = 128;
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
    // DW-211 (T-097): `offline` sets the unit's renderingOffline (kAudioUnitProperty_OfflineRender
    // for a V2 unit) before render resources are allocated; best effort. A different mode
    // re-prepares like a different rate.
    Result<void> prepare(double sampleRate, uint32_t maxBlock, bool offline);
    bool isPrepared() const { return prepared_.load(std::memory_order_acquire); }
    bool preparedOffline() const;
    // DW-301 (T-103), non-RT, only while nothing renders the instance (an export from a realtime
    // engine, device stopped): sets renderingOffline (kAudioUnitProperty_OfflineRender for a V2
    // unit) to `on` for an export, and back with `false`. The property is set before render
    // resources are allocated, so this deallocates and reallocates them (same formats, rate and
    // block size) under the DW-214 lifecycle lock. An instance prepared offline is left alone.
    // Best effort: a unit that refuses the mode keeps rendering in its old one (logged). Returns
    // whether the unit now reports `on`. preparedOffline() keeps the prepare mode.
    bool setExportOffline(bool on);
    bool renderingOffline() const;  // the unit's current renderingOffline (tests)
    double preparedRate() const { return rate_; }
    uint32_t preparedMaxBlock() const { return maxBlock_; }
    uint32_t inputChannels() const { return inChannels_; }
    uint32_t outputChannels() const { return outChannels_; }
    bool sidechainEnabled() const { return sidechainChannels_ > 0; }

    // PLUG-015. Fixed when instantiated; `current` re-reads every value (non-RT).
    const std::vector<AUParamInfo>& params() const { return params_; }
    std::vector<AUParamInfo> params(bool current) const;
    // DW-213 (T-094), non-RT: the AU's display string of parameter `index` at `value` (its
    // string-from-value, else a step's value name), without the unit. Empty for an unknown index
    // or a parameter without strings.
    std::string displayString(uint32_t index, float value) const;

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
    // RT, AUTO-003 / DW-233 (T-097): the same, as an event at `frameOffset` of the next render (a
    // loop wrap's jump).
    void scheduleParam(uint32_t index, float value, uint32_t rampFrames, uint32_t frameOffset) DAW_RT;
    // RT. A MIDI event at its frame offset into the next render (clamped to the block).
    void scheduleMIDI(const MidiEvent& event, uint32_t numFrames) DAW_RT;
    // RT, DW-225 (T-097): note-offs at `frame` of the next render for every note scheduled and not
    // released, then CC 123 (All Notes Off) on each channel that had notes; the host forgets them.
    void releaseHeldNotes(uint32_t frame) DAW_RT;
    bool holdsNotes() const DAW_RT;

    // DW-242 (T-097): clears the AU's rendering state (-reset, i.e. AudioUnitReset(global, 0));
    // parameters and state stay (PluginReset.h). Same calls as VST3Instance's:
    //   resetNow: non-RT, synchronous, while nothing renders the instance (before an export).
    //   consumeFreshReset: RT, true once after resetNow (the node's reset() has nothing to do).
    //   requestReset: RT, never waits: the reset worker does it, resetBusy() until then.
    void resetNow();
    bool consumeFreshReset() DAW_RT;
    void requestReset() DAW_RT;
    bool resetBusy() const DAW_RT;
    uint64_t resetsDone() const;  // tests
    // RT. What the AU's musicalContextBlock / transportStateBlock report during the next render.
    void setTransport(const TransportBlock& transport) DAW_RT;
    // RT. Renders `numFrames` (1 … preparedMaxBlock) into io.audioOut from io.audioIn and
    // io.sidechain. Returns false (output untouched) if the AU reported an error.
    bool render(const NodeIO& io, uint32_t numFrames) DAW_RT;
    uint64_t renderErrors() const { return renderErrors_.load(std::memory_order_relaxed); }

    // DW-214: bridged units whose deferred release hasn't happened yet (process-wide, any thread).
    static uint32_t pendingV2Releases();

    // DW-204 (T-063), the plugin → model half of PLUG-015. The parameter tree's automation events
    // (an editor's Touch/Value/Release) go to `queue` as edits of `slot` (null: dropped); the host
    // sets it whenever it gives the instance to a slot. Echoes of the host's own pushes are not
    // edits (see EditState in AUInstance.mm).
    void setEditSink(std::shared_ptr<PluginEditQueue> queue, NodeID slot);
    // RT, for the node before scheduleParam: `push` it; `skip` it (the plugin already has the value:
    // the model caught up with an edit made in the plugin); or `defer` it to a later block (a
    // gesture in the plugin's editor is open, or the model hasn't caught up with its last edit yet).
    enum class PushDecision : uint8_t { push, skip, defer };
    PushDecision pushDecision(uint32_t index, float value) DAW_RT;

    // PLUG-017 (T-063): the AUAudioUnit (unretained), for its view controller. Main thread.
    void* audioUnit() const;

    // Shared with the KVO observer and its dispatched reports, which may outlive the instance.
    struct LatencyState;
    struct EditState;  // DW-204
    struct Impl;  // Objective-C side (AUInstance.mm)

private:
    explicit AUInstance(const AUComponentID& component);
    void clearState();  // DW-242: the reset itself (PluginReset's work)

    AUComponentID component_;
    Impl* impl_ = nullptr;
    std::shared_ptr<LatencyState> latency_;
    std::shared_ptr<EditState> edits_;  // DW-204
    std::vector<AUParamInfo> params_;
    std::atomic<bool> prepared_{false};
    double rate_ = 0;
    uint32_t maxBlock_ = 0;
    uint32_t inChannels_ = 0, outChannels_ = 0, sidechainChannels_ = 0;
    std::atomic<uint64_t> renderErrors_{0};
    std::unique_ptr<PluginReset> reset_;  // DW-242
};

} // namespace daw
