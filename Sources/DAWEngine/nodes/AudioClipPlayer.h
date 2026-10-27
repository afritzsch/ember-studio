#pragma once
// DSP-001: NodeKind::audioClipPlayer, the source node of an audio track. Plays the track's clips
// from decoded assets (D-10) with clip gain and linear fades; mono assets are duplicated to L/R.
//
// Clip delivery (DW-051): a player's clips are fixed when the node is created. GraphBuilder calls
// the factory only for a new instance (new node, or kind / configVersion / param range changed),
// so the model bumps a clip player's configVersion whenever that track's clips change, and when
// an asset one of them uses finishes loading (an empty asset plays silence). Chosen over per-graph
// clip data because it needs no change to GraphBuilder or RenderGraph, and a player has almost no
// state worth keeping across an edit: only a loop-wrap crossfade can be cut short.
//
// Timing (D-06): clips are kept in ticks and placed through the block's TempoMap
// (TransportBlock::tempo, the current graph's map) every block, so a tempo edit moves them
// without re-creating the node. A clip sounds on samples [tickToSample(start),
// tickToSample(start + length)); it moves with tempo but isn't stretched, so its source frame
// is sourceOffsetSamples + (sample − tickToSample(start)). A source frame outside the asset is
// silent. Fades are in ticks and converted the same way: fade-in frame k of K plays at k/K
// (0 on the first frame), and fade-out is its mirror image (0 on the clip's last frame).
// Fades are clamped to the clip's length; where they overlap, both apply.
//
// TIME-006: each TransportSegment is rendered from its own startSample, so wraps and locates
// need no cursor. Clips are sorted by start tick with a running maximum of end ticks, so the
// clips overlapping a range are found by binary search. Overlapping clips are summed for now;
// "later clip wins" with a crossfade is DSP-002 (T-035).
//
// Loop wraps (TIME-005, TIME-006 step 4): when a segment doesn't continue the previous one
// (SegmentContinuity), the old pass keeps sounding from where it stopped for kDeclickFrames and
// fades out linearly while the new pass fades in, so the weights sum to 1 and a signal that is
// the same on both sides of the wrap passes unchanged. The first segment after reset() (TIME-008:
// locate while playing) or after a stopped block starts without a fade or tail.
//
// Assets (DW-042, ENG-014): the node holds an AudioAssetRef per clip for its whole life and never
// drops one on the audio thread; refs go when the node is destroyed on daw.reclaim.

#include <array>
#include <cstdint>
#include <memory>
#include <span>
#include <vector>

#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/Realtime.h"
#include "core/Result.h"
#include "daw/GraphDescription.h"
#include "io/AudioAsset.h"
#include "nodes/AssetLookup.h"
#include "time/TempoMap.h"
#include "time/TransportSegments.h"

namespace daw {

class AudioClipPlayer final : public Node {
public:
    static constexpr uint32_t kDeclickFrames = 64;

    struct Clip {
        Tick start = 0;
        Tick end = 0;           // start + length
        Tick fadeInEnd = 0;     // start + fadeIn
        Tick fadeOutStart = 0;  // end − fadeOut
        int64_t sourceOffset = 0;
        float gain = 1.0f;
        AudioAssetRef asset;    // empty: silent
        bool playable = false;  // set by prepare(): an asset at the session rate
    };

    // Non-RT. Resolves every clip's asset through `lookup` and drops clips with length <= 0.
    static std::unique_ptr<AudioClipPlayer> create(std::span<const ClipDesc> clips,
                                                   const AssetLookup& lookup);
    // Non-RT. Takes the clips in any order.
    explicit AudioClipPlayer(std::vector<Clip> clips);

    void prepare(const PrepareInfo& info) override;
    void reset() DAW_RT override;
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;

    // Non-RT diagnostics and tests.
    std::span<const Clip> clips() const { return clips_; }

private:
    // Adds the clips sounding on samples [from, from + numFrames) into left/right.
    void renderRange(const TempoMap& tempo, SamplePos from, uint32_t numFrames, float* left,
                     float* right) const DAW_RT;
    void renderClip(const TempoMap& tempo, const Clip& clip, SamplePos from, uint32_t numFrames,
                    float* left, float* right) const DAW_RT;
    // Index of the first clip whose running maximum end tick is >= `tick`.
    size_t firstEndingAtOrAfter(Tick tick) const DAW_RT;
    void forgetPass() DAW_RT;

    std::vector<Clip> clips_;    // sorted by start
    std::vector<Tick> maxEnd_;   // maxEnd_[i] = max(clips_[0..i].end), non-decreasing

    // Wrap crossfade state (audio thread only).
    SegmentContinuity continuity_;
    bool havePrev_ = false;
    SamplePos prevEnd_ = 0;        // where the previous segment stopped
    SamplePos tailPos_ = 0;        // the old pass's next sample
    uint32_t tailLeft_ = 0;        // frames of old-pass tail still to play
    uint32_t fadeInDone_ = kDeclickFrames;  // frames of the new pass's fade-in already played
    std::array<float, 2 * kDeclickFrames> tail_{};
};

} // namespace daw
