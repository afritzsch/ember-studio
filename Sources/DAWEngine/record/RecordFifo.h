#pragma once
// REC-001: one armed track's recording FIFO, from the audio thread (producer) to daw.diskwrite
// (consumer). Two SpscQueues (ENG-060): the frames, and one chunk header per block telling where
// in the take those frames belong. A block either goes in whole or is dropped whole (REC-002:
// never block, never write half a block); the header's fileFrame lets the writer fill a dropped
// block with silence, so everything after a drop stays where it belongs on the timeline.
//
// Preallocated: construct it off the audio thread (it is ~2 MB, so on the heap).

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <span>

#include "core/Realtime.h"
#include "core/SpscQueue.h"

namespace daw {

// A recorded stereo frame (an input channel pair, REC-001).
struct RecordFrame {
    float left = 0;
    float right = 0;
};

// The frames of one block, in order: they start at frame `fileFrame` of the take.
struct RecordChunk {
    int64_t fileFrame = 0;
    uint32_t frames = 0;
};

class RecordFifo {
public:
    // REC-001: ≥ 2 s at every session rate: 2^18 frames are 5.9 s at 44.1 kHz, 2.7 s at 96 kHz.
    static constexpr std::size_t kFrames = std::size_t{1} << 18;
    // One header per block; at the smallest device buffer (32 frames) and 96 kHz that is 2.7 s.
    static constexpr std::size_t kChunks = std::size_t{1} << 13;

    RecordFifo() = default;
    RecordFifo(const RecordFifo&) = delete;
    RecordFifo& operator=(const RecordFifo&) = delete;

    // Producer (RT). Queues `numFrames` frames of `left`/`right` (null: silence) as one chunk at
    // `fileFrame`. False, and nothing queued, if they don't all fit (REC-002: a drop).
    bool write(const float* left, const float* right, uint32_t numFrames, int64_t fileFrame) DAW_RT {
        if (numFrames == 0) return true;
        // Seen from the producer, sizeApprox can only over-count (the reader's index may be
        // stale), so a block that passes this check fits.
        if (chunks_.sizeApprox() >= kChunks || kFrames - frames_.sizeApprox() < numFrames) return false;
        RecordFrame scratch[kBatch];  // CONV-RT-01: on the stack
        // CONV-RT-04: bounded by numFrames / kBatch.
        for (uint32_t done = 0; done < numFrames;) {
            const uint32_t n = std::min<uint32_t>(numFrames - done, kBatch);
            for (uint32_t i = 0; i < n; ++i)
                scratch[i] = RecordFrame{left ? left[done + i] : 0.0f, right ? right[done + i] : 0.0f};
            (void)frames_.push(std::span<const RecordFrame>(scratch, n));
            done += n;
        }
        // After the frames, so a consumer that sees the header finds them queued.
        (void)chunks_.push(RecordChunk{fileFrame, numFrames});
        return true;
    }

    // Consumer: the next chunk's header; then popFrames its frames.
    bool popChunk(RecordChunk& chunk) DAW_RT { return chunks_.pop(chunk); }
    std::size_t popFrames(std::span<RecordFrame> out) DAW_RT { return frames_.pop(out); }

    std::size_t framesQueued() const DAW_RT { return frames_.sizeApprox(); }

private:
    static constexpr uint32_t kBatch = 256;

    SpscQueue<RecordFrame, kFrames> frames_;
    SpscQueue<RecordChunk, kChunks> chunks_;
};

} // namespace daw
