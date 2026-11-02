#include "nodes/AudioClipPlayer.h"

#include <algorithm>
#include <cstddef>
#include <cstring>
#include <utility>

#include "core/ProcessContext.h"
#include "dsp/EqualPower.h"

namespace daw {

std::unique_ptr<AudioClipPlayer> AudioClipPlayer::create(std::span<const ClipDesc> descs,
                                                         const AssetLookup& lookup) {
    std::vector<Clip> clips;
    clips.reserve(descs.size());
    for (const ClipDesc& d : descs) {
        if (d.length <= 0) continue;
        Clip c;
        c.start = d.start;
        c.end = d.start + d.length;
        c.fadeInEnd = d.start + std::clamp<Tick>(d.fadeIn, 0, d.length);
        c.fadeOutStart = c.end - std::clamp<Tick>(d.fadeOut, 0, d.length);
        c.sourceOffset = d.sourceOffsetSamples;
        c.gain = d.gain;
        c.id = d.clipID;
        if (lookup) c.asset = lookup(d.assetID);
        clips.push_back(std::move(c));
    }
    return std::make_unique<AudioClipPlayer>(std::move(clips));
}

AudioClipPlayer::AudioClipPlayer(std::vector<Clip> clips) : clips_(std::move(clips)) {
    // DSP-002: the model's track order, (start, clip ID), whatever order the clips came in.
    std::stable_sort(clips_.begin(), clips_.end(), [](const Clip& a, const Clip& b) {
        return a.start != b.start ? a.start < b.start : a.id < b.id;
    });
    maxEnd_.reserve(clips_.size());
    for (const Clip& c : clips_) maxEnd_.push_back(maxEnd_.empty() ? c.end : std::max(maxEnd_.back(), c.end));

    // DSP-002: what is underneath each clip. underEnd covers every earlier clip; underStart only
    // those with a strictly earlier start, i.e. the running maximum before this start group.
    Tick beforeGroup = kNoClip;  // max end of the clips starting before the current start tick
    for (size_t i = 0; i < clips_.size(); ++i) {
        if (i > 0 && clips_[i].start != clips_[i - 1].start) beforeGroup = maxEnd_[i - 1];
        clips_[i].underStart = beforeGroup;
        clips_[i].underEnd = i > 0 ? maxEnd_[i - 1] : kNoClip;
    }
}

void AudioClipPlayer::prepare(const PrepareInfo& info) {
    // IO-031: assets are decoded at the session rate. One that isn't (a stale asset after a rate
    // change, D-27) stays silent until the model re-creates the player with the re-converted one.
    for (Clip& c : clips_)
        c.playable = c.asset && c.asset->sampleRate == info.sampleRate && c.asset->channels > 0 &&
                     c.asset->frames > 0;
    forgetPass();
}

void AudioClipPlayer::reset() DAW_RT {
    // TIME-008: a locate while playing drops tails and forgets where the last pass was.
    forgetPass();
}

void AudioClipPlayer::forgetPass() DAW_RT {
    continuity_.forget();
    havePrev_ = false;
    tailLeft_ = 0;
    fadeInDone_ = kDeclickFrames;
}

size_t AudioClipPlayer::firstEndingAtOrAfter(Tick tick) const DAW_RT {
    size_t lo = 0, hi = maxEnd_.size();
    while (lo < hi) {  // O(log clips)
        const size_t mid = lo + (hi - lo) / 2;
        if (maxEnd_[mid] < tick) lo = mid + 1;
        else hi = mid;
    }
    return lo;
}

size_t AudioClipPlayer::firstStartingAtOrAfter(Tick tick) const DAW_RT {
    size_t lo = 0, hi = clips_.size();
    while (lo < hi) {  // O(log clips)
        const size_t mid = lo + (hi - lo) / 2;
        if (clips_[mid].start < tick) lo = mid + 1;
        else hi = mid;
    }
    return lo;
}

void AudioClipPlayer::renderRange(const TempoMap& tempo, SamplePos from, uint32_t numFrames,
                                  float* left, float* right) DAW_RT {
    for (uint32_t done = 0; done < numFrames; done += kChunkFrames) {  // bounded by numFrames
        const uint32_t n = std::min(kChunkFrames, numFrames - done);
        renderChunk(tempo, from + done, n, left + done, right + done);
    }
}

void AudioClipPlayer::renderChunk(const TempoMap& tempo, SamplePos from, uint32_t numFrames,
                                  float* left, float* right) DAW_RT {
    if (numFrames == 0) return;
    // A clip sounds in the range iff tickToSample(start) < from + numFrames and
    // tickToSample(end) > from; in ticks (tickToSample is monotonic):
    //   start < firstTickAtOrAfter(from + numFrames),  end >= firstTickAtOrAfter(from + 1).
    const Tick startBefore = firstTickAtOrAfter(tempo, from + numFrames);
    const Tick endFrom = firstTickAtOrAfter(tempo, from + 1);
    const size_t lo = firstEndingAtOrAfter(endFrom);
    const size_t hi = firstStartingAtOrAfter(startBefore);  // clips_[lo, hi) may sound
    if (lo >= hi) return;

    // DSP-002: composite from the latest clip down. trans[f] is how much of frame f the clips
    // already drawn let through to the ones under them.
    float* trans = trans_.data();
    std::fill(trans, trans + numFrames, 1.0f);
    for (size_t i = hi; i-- > lo;) {  // bounded by the clip count
        const Clip& c = clips_[i];
        if (c.end < endFrom) continue;
        if (renderClip(tempo, c, from, numFrames, left, right, trans)) break;  // the rest is hidden
    }
}

bool AudioClipPlayer::renderClip(const TempoMap& tempo, const Clip& clip, SamplePos from,
                                 uint32_t numFrames, float* left, float* right,
                                 float* trans) const DAW_RT {
    const SamplePos clipStart = tempo.tickToSample(clip.start);
    const SamplePos clipEnd = tempo.tickToSample(clip.end);
    const SamplePos rangeEnd = from + static_cast<SamplePos>(numFrames);
    const SamplePos begin = std::max(from, clipStart);
    const SamplePos end = std::min(rangeEnd, clipEnd);
    if (begin >= end) return false;

    // DSP-002: the crossfades at this clip's boundaries, inside its own span. Fade in over the
    // clips that started strictly earlier and still sound at clipStart, for no longer than they
    // do; fade out over any earlier clip that goes on past clipEnd.
    const SamplePos length = clipEnd - clipStart;
    const SamplePos maxFade = std::min<SamplePos>(kOverlapCrossfadeFrames, length);
    SamplePos nIn = 0, nOut = 0;
    if (clip.underStart > clip.start)
        nIn = std::clamp<SamplePos>(tempo.tickToSample(clip.underStart) - clipStart, 0, maxFade);
    if (clip.underEnd > clip.end && tempo.tickToSample(clip.underEnd) > clipEnd) nOut = maxFade;

    // Source frame of sample `pos` is pos + toSource.
    const SamplePos toSource = clip.sourceOffset - clipStart;
    const AudioAsset* asset = clip.playable ? clip.asset.get() : nullptr;
    const SamplePos srcBegin = asset ? -toSource : 0;                // first sample with a source frame
    const SamplePos srcEnd = asset ? asset->frames - toSource : 0;   // and one past the last
    const float* srcL = asset ? asset->data[0] : nullptr;
    const float* srcR = asset ? (asset->channels > 1 ? asset->data[1] : asset->data[0]) : nullptr;  // mono → L/R

    const SamplePos fadeIn = tempo.tickToSample(clip.fadeInEnd) - clipStart;
    const SamplePos fadeOut = clipEnd - tempo.tickToSample(clip.fadeOutStart);

    for (SamplePos pos = begin; pos < end; ++pos) {  // bounded by numFrames
        const size_t f = static_cast<size_t>(pos - from);
        const SamplePos sinceStart = pos - clipStart;
        const SamplePos untilEnd = clipEnd - 1 - pos;

        // Cover weight: the boundary crossfade that is less far along counts (06, DSP-002).
        EqualPowerGains cover{1.0f, 0.0f};
        if (sinceStart < nIn) cover = equalPowerFrame(sinceStart, nIn);
        if (untilEnd < nOut) {
            const EqualPowerGains out = equalPowerFrame(untilEnd, nOut);
            if (out.in < cover.in) cover = out;
        }

        if (pos >= srcBegin && pos < srcEnd) {
            // DSP-001: clip gain and linear fades shape the clip's own audio.
            float g = clip.gain;
            if (sinceStart < fadeIn) g *= static_cast<float>(sinceStart) / static_cast<float>(fadeIn);
            if (untilEnd < fadeOut) g *= static_cast<float>(untilEnd) / static_cast<float>(fadeOut);
            const float w = g * cover.in * trans[f];
            const SamplePos src = pos + toSource;
            left[f] += w * srcL[src];
            right[f] += w * srcR[src];
        }
        trans[f] *= cover.out;
    }

    // Solid over the whole range: nothing under this clip can be heard here.
    return clipStart + nIn <= from && clipEnd - nOut >= rangeEnd;
}

void AudioClipPlayer::process(ProcessContext& ctx, NodeIO& io) DAW_RT {
    // TIME-006 step 1: frames outside every segment stay silent.
    const AudioBufferView& out = io.audioOut;
    for (uint32_t c = 0; c < out.numChannels; ++c)
        std::memset(out.channels[c], 0, std::size_t{out.numFrames} * sizeof(float));

    const TransportBlock& block = ctx.transport;
    if (block.numSegments == 0) {
        // Stopped (or a 0-frame block): whatever plays next starts clean.
        if (out.numFrames > 0) forgetPass();
        return;
    }
    if (out.numChannels < 2 || block.tempo == nullptr) return;  // stereo throughout (MIX-004)
    const TempoMap& tempo = *block.tempo;
    constexpr float kRamp = 1.0f / static_cast<float>(kDeclickFrames);

    forEachSegment(block, [&](const TransportSegment& seg) DAW_RT {
        float* left = out.channels[0] + seg.frameOffset;
        float* right = out.channels[1] + seg.frameOffset;
        const uint32_t n = seg.numFrames;

        // TIME-006 step 3/4: a wrap (or a tempo edit that moved the playhead's samples) starts a
        // crossfade from the old pass; the first segment after reset() or a stop doesn't.
        if (continuity_.jumped(seg)) {
            if (havePrev_) {
                tailPos_ = prevEnd_;
                tailLeft_ = kDeclickFrames;
                fadeInDone_ = 0;
            } else {
                tailLeft_ = 0;
                fadeInDone_ = kDeclickFrames;
            }
        }

        // TIME-006 step 2: the segment's own position, not a cursor.
        renderRange(tempo, seg.startSample, n, left, right);

        if (fadeInDone_ < kDeclickFrames) {
            const uint32_t m = std::min(kDeclickFrames - fadeInDone_, n);
            for (uint32_t i = 0; i < m; ++i) {
                const float w = static_cast<float>(fadeInDone_ + i + 1) * kRamp;
                left[i] *= w;
                right[i] *= w;
            }
            fadeInDone_ += m;
        }

        if (tailLeft_ > 0) {
            const uint32_t m = std::min(tailLeft_, n);
            float* tailL = tail_.data();
            float* tailR = tail_.data() + kDeclickFrames;
            std::memset(tailL, 0, tail_.size() * sizeof(float));
            renderRange(tempo, tailPos_, m, tailL, tailR);
            const uint32_t done = kDeclickFrames - tailLeft_;
            for (uint32_t i = 0; i < m; ++i) {
                const float w = static_cast<float>(kDeclickFrames - 1 - (done + i)) * kRamp;
                left[i] += w * tailL[i];
                right[i] += w * tailR[i];
            }
            tailPos_ += m;
            tailLeft_ -= m;
        }

        prevEnd_ = seg.startSample + n;
        havePrev_ = true;
    });
}

} // namespace daw
