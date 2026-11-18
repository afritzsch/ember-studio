// T-062 test-only VST3 plugins (built by scripts/build-test-vst3.sh into .build/test-plugins/
// EmberTest.vst3), for what the SDK's `again` sample can't show. Exported C functions (dlsym'd by
// the tests' VST3TestPlugin helper) read and set its process-wide knobs, like FakeAudioUnit's.
//
// "Ember Test Effect": stereo main in/out and a stereo aux (sidechain) input. Output = main × gain
// + sidechain × mix. It records the process context and counts notes.
// "Ember Test Synth": no audio input, stereo out; writes velocity at each note-on's frame.
// Both report whatever latency ember_test_set_latency last set; the setter (or, when requested,
// process() on the audio thread) calls IComponentHandler::restartComponent(kLatencyChanged).
// T-063 (PLUG-017, DW-208): the controller has an editor of its own (EmberTestView.mm, a plain
// NSView), and ember_test_edit makes the controller edit a parameter the way an editor's knob
// does (beginEdit / performEdit / endEdit, DW-204).
// T-097: the controller maps MIDI controllers to parameters (IMidiMapping, DW-210): CC 7 → Gain,
// CC 1 and channel aftertouch → Mod, pitch bend → Sidechain Mix, CC 123 → All Notes Off (channels
// 1 and 2). The processors record each parameter's points of the newest block that had any
// (ember_test_param_points), the process mode of setupProcessing and of the last process call
// (DW-211), and count activations; setActive clears the effect's delay ring (DW-242).

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>
#include <vector>

#include "base/source/fstreamer.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstmidicontrollers.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "public.sdk/source/main/pluginfactory.h"
#include "public.sdk/source/vst/vstaudioeffect.h"
#include "public.sdk/source/vst/vsteditcontroller.h"

using namespace Steinberg;
using namespace Steinberg::Vst;

// EmberTestView.mm (T-063).
IPlugView* emberCreateEditorView(EditController* controller);
void emberRedrawEditor();

namespace {

const FUID kEffectUID(0xE4B3E71A, 0x00000000, 0x00000000, 0x00000001);
const FUID kSynthUID(0xE4B3E71A, 0x00000000, 0x00000000, 0x00000002);
const FUID kControllerUID(0xE4B3E71A, 0x00000000, 0x00000000, 0x00000003);

enum ParamIDs : ParamID { kGain = 0, kSidechainMix = 1, kMeter = 2, kMod = 3, kAllOff = 4 };
constexpr int32 kParamCount = 5;

// T-097: the points each parameter got in the newest block that had a queue for it.
constexpr int32 kMaxLoggedPoints = 256;
struct PointLog {
    std::atomic<int32> count{0};
    std::atomic<int64> block{-1};
    std::atomic<int32> offsets[kMaxLoggedPoints];
    std::atomic<double> values[kMaxLoggedPoints];
};
PointLog gPoints[kParamCount];
std::atomic<int64> gBlocks{0};
std::atomic<int32> gSetupMode{-1}, gDataMode{-1};
std::atomic<int32> gActivations{0};

std::atomic<int> gLiveProcessors{0};
std::atomic<uint32> gLatency{0};
// T-064 (PLUG-022): while set, the effect writes a NaN into the first frame of each block.
std::atomic<bool> gEmitNaN{false};
std::atomic<bool> gRestartFromProcess{false};
std::atomic<int64> gNoteOns{0}, gNoteOffs{0};
std::atomic<double> gTempo{0}, gPPQ{0}, gBar{0};
std::atomic<int64> gProjectSamples{-1};
std::atomic<int32> gPlaying{-1}, gTimeSigNum{0}, gTimeSigDen{0};
std::atomic<uint32> gContextState{0};

class EmberController;
std::mutex gControllersLock;
std::vector<EmberController*> gControllers;
std::atomic<EmberController*> gLastController{nullptr};
std::atomic<int> gSetComponentStateCalls{0};
std::atomic<double> gLastComponentGain{-1};
std::atomic<float> gControllerValue{0};

void restartAll();

class EmberController final : public EditController, public IMidiMapping {
public:
    OBJ_METHODS(EmberController, EditController)
    DEFINE_INTERFACES
        DEF_INTERFACE(IMidiMapping)
    END_DEFINE_INTERFACES(EditController)
    REFCOUNT_METHODS(EditController)

    // DW-210 (T-097).
    tresult PLUGIN_API getMidiControllerAssignment(int32 busIndex, int16 channel, CtrlNumber cc, ParamID& id) SMTG_OVERRIDE {
        if (busIndex != 0 || channel > 1) return kResultFalse;
        switch (cc) {
        case 7: id = kGain; return kResultTrue;
        case 1:
        case kAfterTouch: id = kMod; return kResultTrue;
        case kPitchBend: id = kSidechainMix; return kResultTrue;
        case kCtrlAllNotesOff: id = kAllOff; return kResultTrue;
        default: return kResultFalse;
        }
    }

    static FUnknown* create(void*) { return static_cast<IEditController*>(new EmberController); }

    tresult PLUGIN_API initialize(FUnknown* context) SMTG_OVERRIDE {
        const tresult r = EditController::initialize(context);
        if (r != kResultOk) return r;
        parameters.addParameter(STR16("Gain"), nullptr, 0, 1.0, ParameterInfo::kCanAutomate, kGain);
        parameters.addParameter(STR16("Sidechain Mix"), nullptr, 0, 0.0, ParameterInfo::kCanAutomate, kSidechainMix);
        parameters.addParameter(STR16("Meter"), nullptr, 0, 0.0, ParameterInfo::kIsReadOnly, kMeter);
        parameters.addParameter(STR16("Mod"), nullptr, 0, 0.0, ParameterInfo::kCanAutomate, kMod);  // T-097
        parameters.addParameter(STR16("All Notes Off"), nullptr, 0, 0.0, 0, kAllOff);              // T-097
        std::lock_guard lock(gControllersLock);
        gControllers.push_back(this);
        gLastController.store(this, std::memory_order_release);
        return kResultOk;
    }

    tresult PLUGIN_API terminate() SMTG_OVERRIDE {
        {
            std::lock_guard lock(gControllersLock);
            gControllers.erase(std::remove(gControllers.begin(), gControllers.end(), this), gControllers.end());
            if (gLastController.load() == this)
                gLastController.store(gControllers.empty() ? nullptr : gControllers.back());
        }
        return EditController::terminate();
    }

    // PLUG-016: the host hands the component's state to the controller on restore.
    tresult PLUGIN_API setComponentState(IBStream* state) SMTG_OVERRIDE {
        IBStreamer s(state, kLittleEndian);
        float gain = 0, mix = 0;
        if (!s.readFloat(gain) || !s.readFloat(mix)) return kResultFalse;
        setParamNormalized(kGain, gain);
        setParamNormalized(kSidechainMix, mix);
        gSetComponentStateCalls.fetch_add(1);
        gLastComponentGain.store(gain);
        return kResultOk;
    }

    tresult PLUGIN_API getState(IBStream* state) SMTG_OVERRIDE {
        IBStreamer s(state, kLittleEndian);
        return s.writeFloat(gControllerValue.load()) ? kResultOk : kResultFalse;
    }

    tresult PLUGIN_API setState(IBStream* state) SMTG_OVERRIDE {
        IBStreamer s(state, kLittleEndian);
        float value = 0;
        if (!s.readFloat(value)) return kResultFalse;
        gControllerValue.store(value);
        return kResultOk;
    }

    void restart() {
        if (componentHandler) componentHandler->restartComponent(kLatencyChanged);
    }

    // T-063 (PLUG-017): the editor.
    IPlugView* PLUGIN_API createView(FIDString name) SMTG_OVERRIDE {
        return FIDStringsEqual(name, ViewType::kEditor) ? emberCreateEditorView(this) : nullptr;
    }
    // A host writing a value (VST3 hosts keep the controller in step) shows in the editor.
    tresult PLUGIN_API setParamNormalized(ParamID tag, ParamValue value) SMTG_OVERRIDE {
        const tresult r = EditController::setParamNormalized(tag, value);
        emberRedrawEditor();
        return r;
    }
};

void restartAll() {
    std::lock_guard lock(gControllersLock);
    for (EmberController* c : gControllers) c->restart();
}

class Processor : public AudioEffect {
public:
    Processor() {
        setControllerClass(kControllerUID);
        gLiveProcessors.fetch_add(1);
    }
    ~Processor() override { gLiveProcessors.fetch_sub(1); }

    uint32 PLUGIN_API getLatencySamples() SMTG_OVERRIDE { return gLatency.load(); }
    uint32 PLUGIN_API getTailSamples() SMTG_OVERRIDE { return 0; }

    // DW-211 (T-097).
    tresult PLUGIN_API setupProcessing(ProcessSetup& setup) SMTG_OVERRIDE {
        gSetupMode.store(setup.processMode);
        return AudioEffect::setupProcessing(setup);
    }
    tresult PLUGIN_API setActive(TBool state) SMTG_OVERRIDE {
        if (state) gActivations.fetch_add(1);
        onActive(state);
        return AudioEffect::setActive(state);
    }

    tresult PLUGIN_API setState(IBStream* state) SMTG_OVERRIDE {
        IBStreamer s(state, kLittleEndian);
        float gain = 0, mix = 0;
        if (!s.readFloat(gain) || !s.readFloat(mix)) return kResultFalse;
        gain_ = gain;
        mix_ = mix;
        return kResultOk;
    }

    tresult PLUGIN_API getState(IBStream* state) SMTG_OVERRIDE {
        IBStreamer s(state, kLittleEndian);
        return s.writeFloat(gain_) && s.writeFloat(mix_) ? kResultOk : kResultFalse;
    }

protected:
    void common(ProcessData& data) {
        if (gRestartFromProcess.exchange(false))
            if (EmberController* c = gLastController.load(std::memory_order_acquire)) c->restart();

        const int64 block = gBlocks.fetch_add(1);
        gDataMode.store(data.processMode);
        if (auto* changes = data.inputParameterChanges) {
            for (int32 i = 0; i < changes->getParameterCount(); ++i) {
                IParamValueQueue* q = changes->getParameterData(i);
                if (!q || q->getPointCount() <= 0) continue;
                if (q->getParameterId() < static_cast<ParamID>(kParamCount)) {  // T-097: the point log
                    PointLog& log = gPoints[q->getParameterId()];
                    const int32 n = std::min(q->getPointCount(), kMaxLoggedPoints);
                    for (int32 k = 0; k < n; ++k) {
                        int32 offset = 0;
                        ParamValue value = 0;
                        q->getPoint(k, offset, value);
                        log.offsets[k].store(offset);
                        log.values[k].store(value);
                    }
                    log.count.store(n);
                    log.block.store(block);
                }
                int32 offset = 0;
                ParamValue value = 0;
                if (q->getPoint(q->getPointCount() - 1, offset, value) != kResultOk) continue;
                if (q->getParameterId() == kGain) gain_ = static_cast<float>(value);
                else if (q->getParameterId() == kSidechainMix) mix_ = static_cast<float>(value);
            }
        }
        if (const ProcessContext* ctx = data.processContext) {
            gTempo.store(ctx->tempo);
            gPPQ.store(ctx->projectTimeMusic);
            gBar.store(ctx->barPositionMusic);
            gProjectSamples.store(ctx->projectTimeSamples);
            gPlaying.store((ctx->state & ProcessContext::kPlaying) ? 1 : 0);
            gTimeSigNum.store(ctx->timeSigNumerator);
            gTimeSigDen.store(ctx->timeSigDenominator);
            gContextState.store(ctx->state);
        }
        if (auto* events = data.inputEvents) {
            for (int32 i = 0; i < events->getEventCount(); ++i) {
                Event e{};
                if (events->getEvent(i, e) != kResultOk) continue;
                if (e.type == Event::kNoteOnEvent) {
                    gNoteOns.fetch_add(1);
                    onNote(data, e);
                } else if (e.type == Event::kNoteOffEvent) {
                    gNoteOffs.fetch_add(1);
                }
            }
        }
    }
    virtual void onNote(ProcessData&, const Event&) {}
    virtual void onActive(TBool) {}

    float gain_ = 1.0f, mix_ = 0.0f;
};

class EmberEffect final : public Processor {
public:
    static FUnknown* create(void*) { return static_cast<IAudioProcessor*>(new EmberEffect); }

    tresult PLUGIN_API initialize(FUnknown* context) SMTG_OVERRIDE {
        const tresult r = AudioEffect::initialize(context);
        if (r != kResultOk) return r;
        addAudioInput(STR16("Main In"), SpeakerArr::kStereo);
        addAudioInput(STR16("Sidechain"), SpeakerArr::kStereo, kAux, 0);
        addAudioOutput(STR16("Main Out"), SpeakerArr::kStereo);
        addEventInput(STR16("Events"), 16);
        return kResultOk;
    }

    tresult PLUGIN_API process(ProcessData& data) SMTG_OVERRIDE {
        common(data);
        if (data.numSamples == 0 || data.numOutputs == 0 || data.numInputs == 0) return kResultOk;
        const AudioBusBuffers& in = data.inputs[0];
        const AudioBusBuffers* side = data.numInputs > 1 ? &data.inputs[1] : nullptr;
        const AudioBusBuffers& out = data.outputs[0];
        // The output really is delayed by the reported latency, so PDC tests see it as a real plugin.
        const uint32 delay = std::min<uint32>(gLatency.load(), kRingSize - 1);
        for (int32 c = 0; c < out.numChannels && c < 2; ++c) {
            Sample32* o = out.channelBuffers32[c];
            const Sample32* i = in.channelBuffers32[c < in.numChannels ? c : 0];
            const Sample32* s = side && side->numChannels ? side->channelBuffers32[c < side->numChannels ? c : 0] : nullptr;
            for (int32 n = 0; n < data.numSamples; ++n) {
                const uint32 w = (writePos_ + static_cast<uint32>(n)) & (kRingSize - 1);
                ring_[c][w] = i[n] * gain_ + (s ? s[n] * mix_ : 0.0f);
                o[n] = ring_[c][(w - delay) & (kRingSize - 1)];
            }
        }
        writePos_ = (writePos_ + static_cast<uint32>(data.numSamples)) & (kRingSize - 1);
        if (gEmitNaN.load() && out.numChannels > 0) out.channelBuffers32[0][0] = std::numeric_limits<float>::quiet_NaN();
        return kResultOk;
    }

protected:
    // DW-242 (T-097): activation (re)starts the effect from silence, as a real plugin's reset does.
    void onActive(TBool) override {
        std::memset(ring_, 0, sizeof(ring_));
        writePos_ = 0;
    }

private:
    static constexpr uint32 kRingSize = 1 << 15;
    Sample32 ring_[2][kRingSize] = {};
    uint32 writePos_ = 0;
};

class EmberSynth final : public Processor {
public:
    static FUnknown* create(void*) { return static_cast<IAudioProcessor*>(new EmberSynth); }

    tresult PLUGIN_API initialize(FUnknown* context) SMTG_OVERRIDE {
        const tresult r = AudioEffect::initialize(context);
        if (r != kResultOk) return r;
        addAudioOutput(STR16("Out"), SpeakerArr::kStereo);
        addEventInput(STR16("Events"), 16);
        return kResultOk;
    }

    tresult PLUGIN_API process(ProcessData& data) SMTG_OVERRIDE {
        // Output first, so a note's impulse (common → onNote) lands in cleared buffers.
        if (data.numOutputs > 0)
            for (int32 c = 0; c < data.outputs[0].numChannels; ++c)
                std::memset(data.outputs[0].channelBuffers32[c], 0, sizeof(Sample32) * data.numSamples);
        common(data);
        return kResultOk;
    }

protected:
    void onNote(ProcessData& data, const Event& e) override {
        if (data.numOutputs == 0 || e.sampleOffset < 0 || e.sampleOffset >= data.numSamples) return;
        for (int32 c = 0; c < data.outputs[0].numChannels; ++c)
            data.outputs[0].channelBuffers32[c][e.sampleOffset] = e.noteOn.velocity;
    }
};

} // namespace

extern "C" {

__attribute__((visibility("default"))) void ember_test_set_latency(uint32_t samples) {
    gLatency.store(samples);
    restartAll();
}

__attribute__((visibility("default"))) void ember_test_request_restart_from_process(uint32_t samples) {
    gLatency.store(samples);
    gRestartFromProcess.store(true);
}

__attribute__((visibility("default"))) void ember_test_last_context(double* tempo, double* ppq, double* bar,
                                                                    int64_t* projectSamples, int32_t* playing,
                                                                    int32_t* num, int32_t* den, uint32_t* state) {
    *tempo = gTempo.load();
    *ppq = gPPQ.load();
    *bar = gBar.load();
    *projectSamples = gProjectSamples.load();
    *playing = gPlaying.load();
    *num = gTimeSigNum.load();
    *den = gTimeSigDen.load();
    *state = gContextState.load();
}

__attribute__((visibility("default"))) void ember_test_note_counts(int64_t* ons, int64_t* offs) {
    *ons = gNoteOns.load();
    *offs = gNoteOffs.load();
}

__attribute__((visibility("default"))) void ember_test_controller_stats(int32_t* setComponentStateCalls,
                                                                        double* lastGain, float* controllerValue) {
    *setComponentStateCalls = gSetComponentStateCalls.load();
    *lastGain = gLastComponentGain.load();
    *controllerValue = gControllerValue.load();
}

__attribute__((visibility("default"))) void ember_test_set_controller_value(float value) { gControllerValue.store(value); }

__attribute__((visibility("default"))) int32_t ember_test_live_processors() { return gLiveProcessors.load(); }

__attribute__((visibility("default"))) void ember_test_set_emit_nan(int32_t on) { gEmitNaN.store(on != 0); }  // T-064

// T-063 (DW-204): the newest controller edits parameter `id` as an editor's knob would: phase 0
// beginEdit, 1 setParamNormalized + performEdit, 2 endEdit. Returns the handler's answer.
__attribute__((visibility("default"))) int32_t ember_test_edit(uint32_t id, double value, int32_t phase) {
    EmberController* c = gLastController.load(std::memory_order_acquire);
    if (c == nullptr) return kResultFalse;
    switch (phase) {
    case 0: return c->beginEdit(id);
    case 1:
        c->setParamNormalized(id, value);
        return c->performEdit(id, value);
    default: return c->endEdit(id);
    }
}

// T-063: the newest controller's normalized value of parameter `id` (what its editor shows).
__attribute__((visibility("default"))) double ember_test_controller_param(uint32_t id) {
    EmberController* c = gLastController.load(std::memory_order_acquire);
    return c != nullptr ? c->getParamNormalized(id) : -1;
}

// T-097: the points parameter `id` got in the newest block that had any (up to `max`); `block` is
// that block's number (gBlocks, -1: none yet). Returns the count.
__attribute__((visibility("default"))) int32_t ember_test_param_points(uint32_t id, int32_t* offsets, double* values,
                                                                     int32_t max, int64_t* block) {
    if (id >= static_cast<uint32_t>(kParamCount)) return 0;
    const PointLog& log = gPoints[id];
    const int32_t n = std::min(log.count.load(), max);
    for (int32_t k = 0; k < n; ++k) {
        offsets[k] = log.offsets[k].load();
        values[k] = log.values[k].load();
    }
    *block = log.block.load();
    return n;
}

// T-097: blocks processed (all instances), process modes (DW-211: 0 kRealtime, 2 kOffline; -1
// none yet) and setActive(true) calls (DW-242).
__attribute__((visibility("default"))) void ember_test_process_stats(int64_t* blocks, int32_t* setupMode,
                                                                      int32_t* dataMode, int32_t* activations) {
    *blocks = gBlocks.load();
    *setupMode = gSetupMode.load();
    *dataMode = gDataMode.load();
    *activations = gActivations.load();
}

} // extern "C"

BEGIN_FACTORY_DEF("Ember Studio Tests", "", "")

DEF_CLASS2(INLINE_UID_FROM_FUID(kEffectUID), PClassInfo::kManyInstances, kVstAudioEffectClass, "Ember Test Effect",
           Vst::kDistributable, "Fx", "1.0.0", kVstVersionString, EmberEffect::create)
DEF_CLASS2(INLINE_UID_FROM_FUID(kSynthUID), PClassInfo::kManyInstances, kVstAudioEffectClass, "Ember Test Synth",
           Vst::kDistributable, "Instrument|Synth", "1.0.0", kVstVersionString, EmberSynth::create)
DEF_CLASS2(INLINE_UID_FROM_FUID(kControllerUID), PClassInfo::kManyInstances, kVstComponentControllerClass,
           "Ember Test Controller", 0, "", "1.0.0", kVstVersionString, EmberController::create)

END_FACTORY
