// T-062 test-only VST3 plugins (built by scripts/build-test-vst3.sh into .build/test-plugins/
// EmberTest.vst3), for what the SDK's `again` sample can't show. Exported C functions (dlsym'd by
// the tests' VST3TestPlugin helper) read and set its process-wide knobs, like FakeAudioUnit's.
//
// "Ember Test Effect": stereo main in/out and a stereo aux (sidechain) input. Output = main × gain
// + sidechain × mix. It records the process context and counts notes.
// "Ember Test Synth": no audio input, stereo out; writes velocity at each note-on's frame.
// Both report whatever latency ember_test_set_latency last set; the setter (or, when requested,
// process() on the audio thread) calls IComponentHandler::restartComponent(kLatencyChanged).

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <mutex>
#include <vector>

#include "base/source/fstreamer.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "public.sdk/source/main/pluginfactory.h"
#include "public.sdk/source/vst/vstaudioeffect.h"
#include "public.sdk/source/vst/vsteditcontroller.h"

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {

const FUID kEffectUID(0xE4B3E71A, 0x00000000, 0x00000000, 0x00000001);
const FUID kSynthUID(0xE4B3E71A, 0x00000000, 0x00000000, 0x00000002);
const FUID kControllerUID(0xE4B3E71A, 0x00000000, 0x00000000, 0x00000003);

enum ParamIDs : ParamID { kGain = 0, kSidechainMix = 1, kMeter = 2 };

std::atomic<int> gLiveProcessors{0};
std::atomic<uint32> gLatency{0};
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

class EmberController final : public EditController {
public:
    static FUnknown* create(void*) { return static_cast<IEditController*>(new EmberController); }

    tresult PLUGIN_API initialize(FUnknown* context) SMTG_OVERRIDE {
        const tresult r = EditController::initialize(context);
        if (r != kResultOk) return r;
        parameters.addParameter(STR16("Gain"), nullptr, 0, 1.0, ParameterInfo::kCanAutomate, kGain);
        parameters.addParameter(STR16("Sidechain Mix"), nullptr, 0, 0.0, ParameterInfo::kCanAutomate, kSidechainMix);
        parameters.addParameter(STR16("Meter"), nullptr, 0, 0.0, ParameterInfo::kIsReadOnly, kMeter);
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

        if (auto* changes = data.inputParameterChanges) {
            for (int32 i = 0; i < changes->getParameterCount(); ++i) {
                IParamValueQueue* q = changes->getParameterData(i);
                if (!q || q->getPointCount() <= 0) continue;
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
        return kResultOk;
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

} // extern "C"

BEGIN_FACTORY_DEF("Ember Studio Tests", "", "")

DEF_CLASS2(INLINE_UID_FROM_FUID(kEffectUID), PClassInfo::kManyInstances, kVstAudioEffectClass, "Ember Test Effect",
           Vst::kDistributable, "Fx", "1.0.0", kVstVersionString, EmberEffect::create)
DEF_CLASS2(INLINE_UID_FROM_FUID(kSynthUID), PClassInfo::kManyInstances, kVstAudioEffectClass, "Ember Test Synth",
           Vst::kDistributable, "Instrument|Synth", "1.0.0", kVstVersionString, EmberSynth::create)
DEF_CLASS2(INLINE_UID_FROM_FUID(kControllerUID), PClassInfo::kManyInstances, kVstComponentControllerClass,
           "Ember Test Controller", 0, "", "1.0.0", kVstVersionString, EmberController::create)

END_FACTORY
