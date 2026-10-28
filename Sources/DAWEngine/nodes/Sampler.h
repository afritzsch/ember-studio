#pragma once
// DSP-020..023 (D-19): NodeKind::sampler, the built-in instrument. Plays key-mapped zones of
// decoded assets (D-10) from the MIDI in NodeIO::midiIn, stereo out (mono assets go to L/R).
//
// Zones (DSP-020) come from the NodeDesc's configJSON and are fixed per instance, like a clip
// player's clips (DW-051): the model bumps configVersion when the zones change or an asset they
// use finishes loading. Format (06 "Sampler semantics"):
//   {"zones": [{"assetID": 7, "rootKey": 69, "lowKey": 0, "highKey": 127, "lowVel": 1,
//               "highVel": 127, "tune": 0, "gain": 1, "loopStart": 0, "loopEnd": 48000}]}
// Only assetID is required; the defaults are the values shown, except rootKey (60) and the loop
// (none). An empty string or {} is a sampler without zones (silent). Unknown keys are ignored;
// malformed JSON or an out-of-range value is invalidArgument. tune is in semitones, gain linear,
// loop points in source frames ([loopStart, loopEnd), both or neither). A loop that doesn't fit
// the asset is clamped to it; one that ends up empty is dropped and the zone plays once.
// Assets come from the AssetLookup given to registerBuiltinNodes; a zone whose asset isn't loaded
// or isn't at the session rate (IO-031) is silent.
//
// Notes. A note-on starts one voice for every playable zone whose key and velocity ranges
// (inclusive) contain it, so zones layer. A voice reads its asset from frame 0 at
// rate 2^((note − rootKey + tune + bend) / 12) with 4-point Hermite interpolation (DSP-021,
// dsp/Hermite.h); a one-shot voice ends at the asset's end, a looping one wraps
// [loopStart, loopEnd) until its release ends. Velocity v scales the zone gain by
// (1 − s) + s · (v / 127)², s the velocity param (DSP-022).
//
// Voices (DSP-022): at most kMaxVoices sound at once. A note-on that needs a voice when all are
// taken steals the oldest note's voice, preferring voices already released (note-off, not held
// by the pedal) over held ones; the stolen voice fades out over 5 ms (kStealSeconds) in one of
// kMaxVoices extra fade slots while the new note starts at once. Every voice has the ADSR of
// dsp/Adsr.h, advanced per sample, and MIDI events act on their exact frame.
//
// MIDI (DSP-023, DW-100), per channel: note-on (velocity 0 is a note-off), note-off (releases
// the oldest held note on that key), CC 64 sustain pedal (≥ 64 down; note-offs while it is down
// are deferred until it goes up), CC 123 All Notes Off (a note-off for every held note on the
// channel, so the pedal still holds them, as in MIDI 1.0; a re-created MidiClipPlayer sends it),
// and pitch bend (±2 semitones, 8192 centre, applied from its frame on). Everything else is
// ignored. Events are applied in midiIn order; one earlier than the previous event's frame is
// applied at that frame, and one past the block at its end.
//
// Params, relative to NodeDesc::firstParam, read once per block (ENG-021). A sampler whose
// numParams doesn't cover a param uses its default (the model publishes none for it yet), and
// out-of-range or NaN values are clamped or read as the default. See kParamInfo.

#include <array>
#include <cstdint>
#include <memory>
#include <span>
#include <string_view>
#include <vector>

#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/Realtime.h"
#include "core/Result.h"
#include "daw/GraphDescription.h"
#include "dsp/Adsr.h"
#include "dsp/ParamInfo.h"
#include "graph/NodeRegistry.h"
#include "io/AudioAsset.h"
#include "nodes/AssetLookup.h"

namespace daw {

class Sampler final : public Node {
public:
    static constexpr uint32_t kMaxVoices = 32;
    static constexpr float kStealSeconds = 0.005f;
    static constexpr float kBendRange = 2.0f;  // semitones each way
    static constexpr uint8_t kNumChannels = 16;

    static constexpr uint32_t kAttack = 0;
    static constexpr uint32_t kDecay = 1;
    static constexpr uint32_t kSustain = 2;
    static constexpr uint32_t kRelease = 3;
    static constexpr uint32_t kVelocity = 4;
    static constexpr uint32_t kNumParams = 5;

    static constexpr std::array<ParamInfo, kNumParams> kParamInfo{{
        {kAttack, "attack", "Attack", 0.0f, 10.0f, 0.002f, ParamInfo::Curve::linear, "s", true},
        {kDecay, "decay", "Decay", 0.0f, 10.0f, 0.3f, ParamInfo::Curve::linear, "s", true},
        {kSustain, "sustain", "Sustain", 0.0f, 1.0f, 1.0f, ParamInfo::Curve::linear, "", true},
        {kRelease, "release", "Release", 0.0f, 20.0f, 0.2f, ParamInfo::Curve::linear, "s", true},
        {kVelocity, "velocity", "Velocity Sensitivity", 0.0f, 1.0f, 1.0f, ParamInfo::Curve::linear, "", true},
    }};
    static std::span<const ParamInfo> paramInfo() { return kParamInfo; }

    // DSP-020: one key-mapped zone.
    struct Zone {
        uint64_t assetID = 0;
        uint8_t rootKey = 60;
        uint8_t lowKey = 0, highKey = 127;
        uint8_t lowVel = 1, highVel = 127;
        float tune = 0.0f;  // semitones
        float gain = 1.0f;  // linear
        int64_t loopStart = -1, loopEnd = -1;  // source frames; -1: no loop
        AudioAssetRef asset;  // empty: silent

        // Set by prepare(): the asset is at the session rate, and the loop that fits it.
        bool playable = false;
        bool looping = false;
        int64_t playLoopStart = 0, playLoopEnd = 0;
    };

    // Non-RT. The registry entry for NodeKind::sampler (registerBuiltinNodes).
    static NodeKindInfo kindInfo(AssetLookup lookup);

    // Non-RT. Parses the configJSON format above; assets aren't resolved.
    static Result<std::vector<Zone>> parseZones(std::string_view configJSON);
    // Non-RT. parseZones, then resolves each zone's asset through `lookup`.
    static Result<std::unique_ptr<Sampler>> create(const NodeDesc& desc, const AssetLookup& lookup);

    // `firstParam` / `numParams` as in the NodeDesc.
    Sampler(std::vector<Zone> zones, ParamID firstParam, uint32_t numParams);

    void prepare(const PrepareInfo& info) override;
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;

    // Non-RT diagnostics and tests (or the audio thread between blocks).
    std::span<const Zone> zones() const { return zones_; }
    uint32_t soundingVoices() const DAW_RT;  // not stolen, not idle
    uint32_t fadingVoices() const DAW_RT;    // stolen, fading out

private:
    static constexpr uint32_t kVoiceSlots = 2 * kMaxVoices;

    struct Voice {
        AdsrEnvelope env;
        uint32_t zone = 0;
        uint64_t note = 0;        // note-on counter: smaller is older
        double pos = 0.0;         // source frame
        double semitones = 0.0;   // note − root + tune, without bend
        float gain = 0.0f;        // zone gain × velocity curve
        uint8_t channel = 0, key = 0;
        bool held = false;        // key down: a note-off will release it
        bool sustained = false;   // note-off came while the pedal was down
        bool stolen = false;      // fading out in a fade slot
        bool wrapped = false;     // has looped at least once
    };

    float param(const ProcessContext& ctx, uint32_t index) const DAW_RT;
    void handle(const MidiEvent& event) DAW_RT;
    void noteOn(uint8_t channel, uint8_t key, uint8_t velocity) DAW_RT;
    void noteOff(uint8_t channel, uint8_t key) DAW_RT;
    void releaseVoice(Voice& v) DAW_RT;
    Voice* allocateVoice() DAW_RT;
    void render(uint32_t from, uint32_t to) DAW_RT;
    void renderVoice(Voice& v, float* left, float* right, uint32_t n) DAW_RT;
    float sampleAt(const Zone& z, const float* data, int64_t i, bool wrapped) const DAW_RT;

    std::vector<Zone> zones_;
    ParamID firstParam_;
    uint32_t numParams_;
    double sampleRate_ = 48000.0;
    float stealFrames_ = 240.0f;

    // Audio thread only.
    std::array<Voice, kVoiceSlots> voices_{};
    uint64_t noteCounter_ = 0;
    std::array<bool, kNumChannels> pedal_{};
    std::array<float, kNumChannels> bend_{};  // semitones
    AdsrRates rates_;
    float velocitySensitivity_ = 1.0f;
    float* left_ = nullptr;   // this block's output
    float* right_ = nullptr;
};

} // namespace daw
