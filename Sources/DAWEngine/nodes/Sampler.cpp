#include "nodes/Sampler.h"

#include <algorithm>
#include <charconv>
#include <cmath>
#include <cstring>
#include <string>
#include <utility>
#include <xlocale.h>

#include "core/ProcessContext.h"
#include "dsp/Hermite.h"

namespace daw {

namespace {

constexpr uint8_t kNoteOff = 0x80;
constexpr uint8_t kNoteOn = 0x90;
constexpr uint8_t kControlChange = 0xB0;
constexpr uint8_t kPitchBend = 0xE0;
constexpr uint8_t kSustainPedal = 64;
constexpr uint8_t kAllNotesOff = 123;

// Just enough JSON for the zone config (non-RT). Numbers keep their text, so integers such as
// assetID parse exactly instead of through a double.
struct Json {
    enum class Type { null, boolean, number, string, array, object } type = Type::null;
    std::string text;  // number or string
    std::vector<Json> items;
    std::vector<std::pair<std::string, Json>> members;

    const Json* find(std::string_view key) const {
        for (const auto& [k, v] : members)
            if (k == key) return &v;
        return nullptr;
    }
};

class JsonParser {
public:
    explicit JsonParser(std::string_view s) : s_(s) {}

    bool parseDocument(Json& out) {
        if (!value(out, 0)) return false;
        skipSpace();
        return i_ == s_.size();
    }

private:
    static constexpr int kMaxDepth = 32;

    void skipSpace() {
        while (i_ < s_.size() && (s_[i_] == ' ' || s_[i_] == '\t' || s_[i_] == '\n' || s_[i_] == '\r')) ++i_;
    }
    bool literal(std::string_view word) {
        if (s_.substr(i_, word.size()) != word) return false;
        i_ += word.size();
        return true;
    }
    bool string(std::string& out) {
        if (i_ >= s_.size() || s_[i_] != '"') return false;
        for (++i_; i_ < s_.size(); ++i_) {
            const char c = s_[i_];
            if (c == '"') {
                ++i_;
                return true;
            }
            if (c == '\\') {
                // Keys and values here are plain identifiers; keep escapes verbatim enough to
                // skip them correctly.
                if (++i_ >= s_.size()) return false;
                out += s_[i_];
                continue;
            }
            out += c;
        }
        return false;
    }
    bool number(std::string& out) {
        const size_t start = i_;
        while (i_ < s_.size() && (std::strchr("+-.eE", s_[i_]) != nullptr || (s_[i_] >= '0' && s_[i_] <= '9'))) ++i_;
        out = std::string(s_.substr(start, i_ - start));
        return !out.empty();
    }
    bool value(Json& out, int depth) {
        if (depth > kMaxDepth) return false;
        skipSpace();
        if (i_ >= s_.size()) return false;
        const char c = s_[i_];
        if (c == '{') {
            out.type = Json::Type::object;
            ++i_;
            skipSpace();
            if (i_ < s_.size() && s_[i_] == '}') return ++i_, true;
            for (;;) {
                skipSpace();
                std::string key;
                if (!string(key)) return false;
                skipSpace();
                if (i_ >= s_.size() || s_[i_++] != ':') return false;
                Json v;
                if (!value(v, depth + 1)) return false;
                out.members.emplace_back(std::move(key), std::move(v));
                skipSpace();
                if (i_ >= s_.size()) return false;
                if (s_[i_] == ',') { ++i_; continue; }
                if (s_[i_] == '}') return ++i_, true;
                return false;
            }
        }
        if (c == '[') {
            out.type = Json::Type::array;
            ++i_;
            skipSpace();
            if (i_ < s_.size() && s_[i_] == ']') return ++i_, true;
            for (;;) {
                Json v;
                if (!value(v, depth + 1)) return false;
                out.items.push_back(std::move(v));
                skipSpace();
                if (i_ >= s_.size()) return false;
                if (s_[i_] == ',') { ++i_; continue; }
                if (s_[i_] == ']') return ++i_, true;
                return false;
            }
        }
        if (c == '"') {
            out.type = Json::Type::string;
            return string(out.text);
        }
        if (literal("true") || literal("false")) {
            out.type = Json::Type::boolean;
            return true;
        }
        if (literal("null")) return true;
        out.type = Json::Type::number;
        return number(out.text);
    }

    std::string_view s_;
    size_t i_ = 0;
};

template <class T>
bool parseInteger(const Json& v, T& out) {
    if (v.type != Json::Type::number) return false;
    const char* end = v.text.data() + v.text.size();
    const auto r = std::from_chars(v.text.data(), end, out);
    return r.ec == std::errc{} && r.ptr == end;
}

bool parseFloat(const Json& v, float& out) {
    if (v.type != Json::Type::number) return false;
    // Floating-point from_chars needs macOS 26; strtod_l with the C locale reads JSON's '.'
    // whatever the process locale is.
    char* end = nullptr;
    const double d = strtod_l(v.text.c_str(), &end, LC_C_LOCALE);
    if (end != v.text.c_str() + v.text.size() || !std::isfinite(d)) return false;
    out = static_cast<float>(d);
    return true;
}

Error zoneError(size_t zone, const std::string& what) {
    return Error{ErrorCode::invalidArgument, "sampler zone " + std::to_string(zone) + ": " + what};
}

} // namespace

// MARK: Config (DSP-020)

Result<std::vector<Sampler::Zone>> Sampler::parseZones(std::string_view configJSON) {
    std::vector<Zone> zones;
    if (configJSON.find_first_not_of(" \t\r\n") == std::string_view::npos) return zones;  // no zones

    Json doc;
    if (!JsonParser(configJSON).parseDocument(doc) || doc.type != Json::Type::object)
        return makeError(ErrorCode::invalidArgument, "sampler config: not a JSON object");
    const Json* list = doc.find("zones");
    if (list == nullptr) return zones;
    if (list->type != Json::Type::array)
        return makeError(ErrorCode::invalidArgument, "sampler config: \"zones\" is not an array");

    for (size_t i = 0; i < list->items.size(); ++i) {
        const Json& z = list->items[i];
        if (z.type != Json::Type::object) return zoneError(i, "not an object");
        Zone zone;
        const Json* asset = z.find("assetID");
        if (asset == nullptr || !parseInteger(*asset, zone.assetID)) return zoneError(i, "needs an integer assetID");

        struct Key { const char* name; uint8_t* field; uint8_t min; };
        const Key keys[] = {{"rootKey", &zone.rootKey, 0}, {"lowKey", &zone.lowKey, 0}, {"highKey", &zone.highKey, 0},
                            {"lowVel", &zone.lowVel, 1}, {"highVel", &zone.highVel, 1}};
        for (const Key& k : keys) {
            const Json* v = z.find(k.name);
            if (v == nullptr) continue;
            int value = -1;
            if (!parseInteger(*v, value) || value < k.min || value > 127)
                return zoneError(i, std::string(k.name) + " must be an integer in " + std::to_string(k.min) + "...127");
            *k.field = static_cast<uint8_t>(value);
        }
        if (zone.lowKey > zone.highKey) return zoneError(i, "lowKey > highKey");
        if (zone.lowVel > zone.highVel) return zoneError(i, "lowVel > highVel");

        if (const Json* v = z.find("tune"); v != nullptr && !parseFloat(*v, zone.tune))
            return zoneError(i, "tune must be a number");
        if (const Json* v = z.find("gain"); v != nullptr && (!parseFloat(*v, zone.gain) || zone.gain < 0))
            return zoneError(i, "gain must be a number >= 0");

        const Json* loopStart = z.find("loopStart");
        const Json* loopEnd = z.find("loopEnd");
        if ((loopStart == nullptr) != (loopEnd == nullptr)) return zoneError(i, "loopStart and loopEnd go together");
        if (loopStart != nullptr) {
            if (!parseInteger(*loopStart, zone.loopStart) || !parseInteger(*loopEnd, zone.loopEnd) ||
                zone.loopStart < 0 || zone.loopEnd <= zone.loopStart)
                return zoneError(i, "needs 0 <= loopStart < loopEnd (integer frames)");
        }
        zones.push_back(std::move(zone));
    }
    return zones;
}

Result<std::unique_ptr<Sampler>> Sampler::create(const NodeDesc& desc, const AssetLookup& lookup) {
    auto zones = parseZones(desc.configJSON);
    if (!zones) {
        Error e = zones.error();
        e.message = "sampler " + std::to_string(desc.id) + ": " + e.message;
        return e;
    }
    std::vector<Zone> resolved = std::move(zones).value();
    if (lookup)
        for (Zone& z : resolved) z.asset = lookup(z.assetID);
    return std::make_unique<Sampler>(std::move(resolved), desc.firstParam, desc.numParams);
}

NodeKindInfo Sampler::kindInfo(AssetLookup lookup) {
    return NodeKindInfo{[lookup = std::move(lookup)](const NodeCreateInfo& info) -> Result<std::unique_ptr<Node>> {
        auto sampler = create(info.desc, lookup);
        if (!sampler) return sampler.error();
        return std::unique_ptr<Node>(std::move(sampler).value());
    }};
}

Sampler::Sampler(std::vector<Zone> zones, ParamID firstParam, uint32_t numParams)
    : zones_(std::move(zones)), firstParam_(firstParam), numParams_(numParams) {}

void Sampler::prepare(const PrepareInfo& info) {
    sampleRate_ = info.sampleRate;
    stealFrames_ = kStealSeconds * static_cast<float>(info.sampleRate);
    // IO-031: assets are decoded at the session rate; a stale one stays silent until the model
    // re-creates the sampler (as AudioClipPlayer).
    for (Zone& z : zones_) {
        z.playable = z.asset && z.asset->sampleRate == info.sampleRate && z.asset->channels > 0 &&
                     z.asset->frames > 0;
        z.looping = false;
        if (!z.playable || z.loopStart < 0) continue;
        z.playLoopStart = z.loopStart;
        z.playLoopEnd = std::min(z.loopEnd, z.asset->frames);
        z.looping = z.playLoopStart < z.playLoopEnd;
    }
    for (Voice& v : voices_) v = Voice{};
    pedal_.fill(false);
    bend_.fill(0.0f);
    noteCounter_ = 0;
}

// MARK: Voices (DSP-022)

uint32_t Sampler::soundingVoices() const DAW_RT {
    uint32_t n = 0;
    for (const Voice& v : voices_) n += v.env.active() && !v.stolen;
    return n;
}

uint32_t Sampler::soundingVoices(uint8_t channel, uint8_t key) const DAW_RT {
    uint32_t n = 0;
    for (const Voice& v : voices_) n += v.env.active() && !v.stolen && v.channel == channel && v.key == key;
    return n;
}

uint32_t Sampler::fadingVoices() const DAW_RT {
    uint32_t n = 0;
    for (const Voice& v : voices_) n += v.env.active() && v.stolen;
    return n;
}

Sampler::Voice* Sampler::allocateVoice() DAW_RT {
    // Steal when every voice sounds: the oldest note already released (not held by key or
    // pedal), else the oldest note. It fades out over 5 ms in its slot; the new note takes a
    // free one.
    if (soundingVoices() >= kMaxVoices) {
        Voice* victim = nullptr;
        bool victimReleased = false;
        for (Voice& v : voices_) {
            if (!v.env.active() || v.stolen) continue;
            const bool released = !v.held && !v.sustained;
            if (victim == nullptr || (released && !victimReleased) ||
                (released == victimReleased && v.note < victim->note)) {
                victim = &v;
                victimReleased = released;
            }
        }
        if (victim != nullptr) {
            victim->stolen = true;
            victim->held = victim->sustained = false;
            victim->env.releaseOver(stealFrames_);
        }
    }
    Voice* quietest = nullptr;
    for (Voice& v : voices_) {
        if (!v.env.active()) return &v;
        if (v.stolen && (quietest == nullptr || v.env.level() < quietest->env.level())) quietest = &v;
    }
    // Every fade slot is busy too (kMaxVoices steals within 5 ms): cut the quietest fade.
    return quietest;
}

void Sampler::noteOn(uint8_t channel, uint8_t key, uint8_t velocity) DAW_RT {
    const float v = static_cast<float>(velocity) / 127.0f;
    const float velocityGain = (1.0f - velocitySensitivity_) + velocitySensitivity_ * v * v;
    const uint64_t note = ++noteCounter_;
    for (uint32_t z = 0; z < zones_.size(); ++z) {  // bounded by the zone count
        const Zone& zone = zones_[z];
        if (!zone.playable || key < zone.lowKey || key > zone.highKey || velocity < zone.lowVel ||
            velocity > zone.highVel)
            continue;
        Voice* voice = allocateVoice();
        if (voice == nullptr) return;
        *voice = Voice{};
        voice->zone = z;
        voice->note = note;
        voice->semitones = static_cast<double>(key) - zone.rootKey + zone.tune;
        voice->gain = zone.gain * velocityGain;
        voice->channel = channel;
        voice->key = key;
        voice->held = true;
        voice->env.start();
    }
}

void Sampler::releaseVoice(Voice& v) DAW_RT {
    v.held = false;
    if (pedal_[v.channel]) {
        v.sustained = true;  // DSP-023: the pedal holds it until it goes up
        return;
    }
    v.sustained = false;
    v.env.release(rates_);
}

void Sampler::noteOff(uint8_t channel, uint8_t key) DAW_RT {
    // The oldest held note on the key: overlapping notes on one key each get their own off.
    uint64_t oldest = 0;
    for (const Voice& v : voices_)
        if (v.env.active() && v.held && v.channel == channel && v.key == key && (oldest == 0 || v.note < oldest))
            oldest = v.note;
    if (oldest == 0) return;
    for (Voice& v : voices_)  // all of its layers
        if (v.env.active() && v.held && v.note == oldest) releaseVoice(v);
}

void Sampler::handle(const MidiEvent& e) DAW_RT {
    if (e.size < 3) return;  // every message handled here has two data bytes
    const uint8_t type = e.data[0] & 0xF0, channel = e.data[0] & 0x0F;
    const uint8_t d1 = e.data[1] & 0x7F, d2 = e.data[2] & 0x7F;
    switch (type) {
    case kNoteOn:
        if (d2 > 0) noteOn(channel, d1, d2);
        else noteOff(channel, d1);
        break;
    case kNoteOff:
        noteOff(channel, d1);
        break;
    case kControlChange:
        if (d1 == kSustainPedal) {
            const bool down = d2 >= 64;
            if (pedal_[channel] && !down) {
                pedal_[channel] = false;
                for (Voice& v : voices_)
                    if (v.env.active() && v.sustained && v.channel == channel) releaseVoice(v);
            }
            pedal_[channel] = down;
        } else if (d1 == kAllNotesOff) {
            // DW-100: a note-off for every held note on the channel (the pedal still applies).
            for (Voice& v : voices_)
                if (v.env.active() && v.held && v.channel == channel) releaseVoice(v);
        }
        break;
    case kPitchBend: {
        // DSP-023: 14 bits, 8192 centre; both ends reach exactly ±kBendRange.
        const int value = int(d1) | (int(d2) << 7);
        bend_[channel] = value >= 8192 ? kBendRange * float(value - 8192) / 8191.0f
                                       : kBendRange * float(value - 8192) / 8192.0f;
        break;
    }
    default:
        break;
    }
}

// MARK: Rendering (DSP-021)

float Sampler::sampleAt(const Zone& z, const float* data, int64_t i, bool wrapped) const DAW_RT {
    if (z.looping) {
        const int64_t len = z.playLoopEnd - z.playLoopStart;
        // After the first wrap the frame before the loop start is the loop's last one.
        if (wrapped && i < z.playLoopStart) i += len;
        if (i >= z.playLoopEnd) i = z.playLoopStart + (i - z.playLoopStart) % len;
    }
    return i >= 0 && i < z.asset->frames ? data[i] : 0.0f;
}

void Sampler::renderVoice(Voice& v, float* left, float* right, uint32_t n) DAW_RT {
    const Zone& z = zones_[v.zone];
    const AudioAsset& asset = *z.asset;
    const float* srcL = asset.data[0];
    const float* srcR = asset.channels > 1 ? asset.data[1] : asset.data[0];  // mono → L/R
    // Bend changes only at events, which split the block, so the rate is fixed over [0, n).
    const double rate = std::exp2((v.semitones + static_cast<double>(bend_[v.channel])) / 12.0);
    const double frames = static_cast<double>(asset.frames);

    for (uint32_t i = 0; i < n; ++i) {  // bounded by the block
        const float env = v.env.next(rates_);
        if (!v.env.active()) return;
        const int64_t i0 = static_cast<int64_t>(v.pos);
        const float t = static_cast<float>(v.pos - static_cast<double>(i0));
        const float g = env * v.gain;
        left[i] += g * hermite4(sampleAt(z, srcL, i0 - 1, v.wrapped), sampleAt(z, srcL, i0, v.wrapped),
                                sampleAt(z, srcL, i0 + 1, v.wrapped), sampleAt(z, srcL, i0 + 2, v.wrapped), t);
        if (right != nullptr)
            right[i] += g * hermite4(sampleAt(z, srcR, i0 - 1, v.wrapped), sampleAt(z, srcR, i0, v.wrapped),
                                     sampleAt(z, srcR, i0 + 1, v.wrapped), sampleAt(z, srcR, i0 + 2, v.wrapped), t);
        v.pos += rate;
        if (z.looping) {
            if (v.pos >= static_cast<double>(z.playLoopEnd)) {
                const double start = static_cast<double>(z.playLoopStart);
                v.pos = start + std::fmod(v.pos - start, static_cast<double>(z.playLoopEnd - z.playLoopStart));
                v.wrapped = true;
            }
        } else if (v.pos >= frames) {
            v = Voice{};  // one-shot: the asset has ended
            return;
        }
    }
}

void Sampler::render(uint32_t from, uint32_t to) DAW_RT {
    if (to <= from) return;
    for (Voice& v : voices_)
        if (v.env.active())
            renderVoice(v, left_ + from, right_ != nullptr ? right_ + from : nullptr, to - from);
}

float Sampler::param(const ProcessContext& ctx, uint32_t index) const DAW_RT {
    const ParamInfo& info = kParamInfo[index];
    if (index >= numParams_) return info.def;
    const float v = ctx.params.get(firstParam_ + index);
    if (std::isnan(v)) return info.def;
    return std::clamp(v, info.min, info.max);
}

void Sampler::process(ProcessContext& ctx, NodeIO& io) DAW_RT {
    const AudioBufferView& out = io.audioOut;
    for (uint32_t c = 0; c < out.numChannels; ++c)
        std::memset(out.channels[c], 0, std::size_t{out.numFrames} * sizeof(float));
    const uint32_t numFrames = out.numChannels > 0 ? std::min(ctx.numFrames, out.numFrames) : 0;

    // ENG-021: params once per block.
    const AdsrParams adsr{param(ctx, kAttack), param(ctx, kDecay), param(ctx, kSustain), param(ctx, kRelease)};
    rates_ = AdsrRates::make(adsr, sampleRate_);
    velocitySensitivity_ = param(ctx, kVelocity);

    // With no frames to render into, events still apply (at "the block's end").
    left_ = numFrames > 0 ? out.channels[0] : nullptr;
    right_ = numFrames > 0 && out.numChannels > 1 ? out.channels[1] : nullptr;

    // Sample-accurate (DSP-022): render up to each event's frame, then apply it.
    uint32_t pos = 0;
    for (const MidiEvent& e : io.midiIn) {  // bounded by the MIDI storage's capacity
        const uint32_t frame = std::clamp(e.frameOffset, pos, numFrames);
        render(pos, frame);
        pos = frame;
        handle(e);
    }
    render(pos, numFrames);
}

} // namespace daw
