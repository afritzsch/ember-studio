#pragma once
// DSP-022: a linear ADSR amplitude envelope, advanced one sample at a time so a note-on or
// note-off lands on its exact frame (sample-accurate). Times are in seconds and turned into
// per-sample steps once per block (AdsrRates::make), so parameter changes apply from the next
// block on to every running envelope.
//
//   attack   0 → 1 linearly over `attack` (0: the first sample is already at 1)
//   decay    1 → sustain linearly over `decay`, measured from 1
//   sustain  holds; if the sustain level changes while held it slews there at full scale per
//            kSlewSeconds, so a slider move doesn't click
//   release  from wherever the envelope is to 0 over `release` (0: silent on the next sample).
//            The step is fixed when the release starts, so a later release change doesn't
//            stretch a release already under way.
// releaseOver() is the same release with its own length: the Sampler's 5 ms steal fade.
//
// Trivially copyable, allocation-free; everything is RT-safe.

#include <cstdint>

#include "core/Realtime.h"

namespace daw {

struct AdsrParams {
    float attack = 0.0f;   // seconds
    float decay = 0.0f;    // seconds
    float sustain = 1.0f;  // level, 0 … 1
    float release = 0.0f;  // seconds
};

struct AdsrRates {
    static constexpr float kSlewSeconds = 0.005f;

    float attackStep = 1.0f;
    float decayStep = 1.0f;
    float sustain = 1.0f;
    float releaseFrames = 0.0f;
    float slewStep = 1.0f;

    static AdsrRates make(const AdsrParams& p, double sampleRate) DAW_RT {
        // A step of 1 (or more) reaches the stage's target on the next sample.
        auto stepFor = [&](float span, float seconds) DAW_RT {
            const float frames = seconds * static_cast<float>(sampleRate);
            return frames > 1.0f ? span / frames : 1.0f;
        };
        AdsrRates r;
        r.sustain = p.sustain >= 0.0f ? (p.sustain <= 1.0f ? p.sustain : 1.0f) : 0.0f;
        r.attackStep = stepFor(1.0f, p.attack);
        r.decayStep = stepFor(1.0f - r.sustain, p.decay);
        r.releaseFrames = p.release > 0.0f ? p.release * static_cast<float>(sampleRate) : 0.0f;
        r.slewStep = stepFor(1.0f, kSlewSeconds);
        return r;
    }
};

class AdsrEnvelope {
public:
    enum class Stage : uint8_t { idle, attack, decay, sustain, release };

    // Starts from 0, whatever the envelope was doing.
    void start() DAW_RT {
        stage_ = Stage::attack;
        level_ = 0.0f;
    }

    // Note-off: releases over the rates' release time. No-op when idle or already releasing.
    void release(const AdsrRates& rates) DAW_RT {
        if (stage_ == Stage::idle || stage_ == Stage::release) return;
        releaseOver(rates.releaseFrames);
    }

    // Releases to 0 over `frames` samples from the current level, even if already releasing.
    void releaseOver(float frames) DAW_RT {
        if (stage_ == Stage::idle) return;
        stage_ = Stage::release;
        releaseStep_ = frames > 1.0f ? level_ / frames : level_;
        if (releaseStep_ <= 0.0f) releaseStep_ = 1.0f;  // already at 0: idle on the next sample
    }

    // The level for the next sample.
    float next(const AdsrRates& r) DAW_RT {
        switch (stage_) {
        case Stage::idle:
            return 0.0f;
        case Stage::attack:
            level_ += r.attackStep;
            if (level_ >= 1.0f) {
                level_ = 1.0f;
                stage_ = Stage::decay;
            }
            break;
        case Stage::decay:
            // Never steps up: a sustain raised above the current level is reached by the slew.
            if (level_ > r.sustain) level_ = level_ - r.decayStep > r.sustain ? level_ - r.decayStep : r.sustain;
            if (level_ <= r.sustain) stage_ = Stage::sustain;
            break;
        case Stage::sustain:
            if (level_ < r.sustain) level_ = level_ + r.slewStep < r.sustain ? level_ + r.slewStep : r.sustain;
            else if (level_ > r.sustain) level_ = level_ - r.slewStep > r.sustain ? level_ - r.slewStep : r.sustain;
            break;
        case Stage::release:
            level_ -= releaseStep_;
            if (level_ <= 0.0f) {
                level_ = 0.0f;
                stage_ = Stage::idle;
            }
            break;
        }
        return level_;
    }

    Stage stage() const DAW_RT { return stage_; }
    float level() const DAW_RT { return level_; }
    bool active() const DAW_RT { return stage_ != Stage::idle; }

private:
    Stage stage_ = Stage::idle;
    float level_ = 0.0f;
    float releaseStep_ = 1.0f;
};

} // namespace daw
