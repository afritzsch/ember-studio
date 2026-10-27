#include "nodes/AudioClipPlayer.h"

#include <algorithm>
#include <cstddef>
#include <cstring>
#include <utility>

#include "core/ProcessContext.h"

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
        if (lookup) c.asset = lookup(d.assetID);
        clips.push_back(std::move(c));
    }
    return std::make_unique<AudioClipPlayer>(std::move(clips));
}

AudioClipPlayer::AudioClipPlayer(std::vector<Clip> clips) : clips_(std::move(clips)) {
    std::stable_sort(clips_.begin(), clips_.end(),
                     [](const Clip& a, const Clip& b) { return a.start < b.start; });
    maxEnd_.reserve(clips_.size());
    for (const Clip& c : clips_) maxEnd_.push_back(maxEnd_.empty() ? c.end : std::max(maxEnd_.back(), c.end));
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

void AudioClipPlayer::renderRange(const TempoMap& tempo, SamplePos from, uint32_t numFrames,
                                  float* left, float* right) const DAW_RT {
    if (numFrames == 0) return;
    // A clip sounds in the range iff tickToSample(start) < from + numFrames and
    // tickToSample(end) > from; in ticks (tickToSample is monotonic):
    //   start < firstTickAtOrAfter(from + numFrames),  end >= firstTickAtOrAfter(from + 1).
    const Tick startBefore = firstTickAtOrAfter(tempo, from + numFrames);
    const Tick endFrom = firstTickAtOrAfter(tempo, from + 1);
    for (size_t i = firstEndingAtOrAfter(endFrom); i < clips_.size(); ++i) {
        const Clip& c = clips_[i];
        if (c.start >= startBefore) break;  // sorted by start: nothing later starts in time
        if (c.end < endFrom || !c.playable) continue;
        renderClip(tempo, c, from, numFrames, left, right);
    }
}

void AudioClipPlayer::renderClip(const TempoMap& tempo, const Clip& clip, SamplePos from,
                                 uint32_t numFrames, float* left, float* right) const DAW_RT {
    const SamplePos clipStart = tempo.tickToSample(clip.start);
    const SamplePos clipEnd = tempo.tickToSample(clip.end);
    const AudioAsset& asset = *clip.asset;
    // Source frame of sample `pos` is pos + toSource.
    const SamplePos toSource = clip.sourceOffset - clipStart;
    const SamplePos begin = std::max({from, clipStart, -toSource});
    const SamplePos end = std::min({from + static_cast<SamplePos>(numFrames), clipEnd, asset.frames - toSource});
    if (begin >= end) return;

    const SamplePos fadeIn = tempo.tickToSample(clip.fadeInEnd) - clipStart;
    const SamplePos fadeOut = clipEnd - tempo.tickToSample(clip.fadeOutStart);
    const float* srcL = asset.data[0];
    const float* srcR = asset.channels > 1 ? asset.data[1] : asset.data[0];  // mono → L/R

    for (SamplePos pos = begin; pos < end; ++pos) {  // bounded by numFrames
        float g = clip.gain;
        const SamplePos sinceStart = pos - clipStart;
        if (sinceStart < fadeIn) g *= static_cast<float>(sinceStart) / static_cast<float>(fadeIn);
        const SamplePos untilEnd = clipEnd - 1 - pos;
        if (untilEnd < fadeOut) g *= static_cast<float>(untilEnd) / static_cast<float>(fadeOut);
        const SamplePos src = pos + toSource;
        const size_t f = static_cast<size_t>(pos - from);
        left[f] += g * srcL[src];
        right[f] += g * srcR[src];
    }
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
