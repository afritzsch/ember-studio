#include "time/Transport.h"

#include "time/TransportSegments.h"

namespace daw {

namespace {

constexpr uint8_t kPlayingFlag = 1;
constexpr uint8_t kRecordingFlag = 2;
constexpr uint8_t kLoopFlag = 4;

TransportSegment makeSegment(const TempoMap& tempo, SamplePos start, uint32_t frameOffset,
                             uint32_t numFrames, bool afterWrap, Tick wrapTick = 0) DAW_RT {
    TransportSegment seg{start, firstTickAtOrAfter(tempo, start),
                         firstTickAtOrAfter(tempo, start + numFrames), frameOffset, numFrames,
                         afterWrap};
    // A tick before the loop start can round to the loop start's sample (only when a tick is
    // shorter than a sample); it belongs before the loop, not to the next pass.
    if (afterWrap && seg.startTick < wrapTick) {
        seg.startTick = wrapTick;
        if (seg.endTick < wrapTick) seg.endTick = wrapTick;
    }
    return seg;
}

} // namespace

// MARK: Producers (non-RT)

bool Transport::push(const TransportCmd& cmd) {
    // TIME-004: SpscQueue takes one producer at a time; this mutex makes every non-RT caller
    // that producer in turn. Only producers lock it, never the audio thread.
    std::lock_guard lock(producerMutex_);
    return commands_.push(cmd);
}

bool Transport::play() { return push({TransportCmdType::play}); }
bool Transport::stop() { return push({TransportCmdType::stop}); }
bool Transport::locate(Tick tick) { return push({TransportCmdType::locate, false, tick}); }

bool Transport::setLoop(bool enabled, Tick start, Tick end) {
    if (enabled && !(start < end)) return false;
    return push({TransportCmdType::setLoop, enabled, start, end});
}

bool Transport::setRecording(bool recording) {
    return push({TransportCmdType::setRecording, recording});
}

TransportPlayhead Transport::playhead() const {
    // TIME-009 seqlock read. The audio thread holds seq_ odd only for a few stores, so this
    // retries at most a handful of times.
    for (;;) {
        const uint64_t before = seq_.load(std::memory_order_acquire);
        if (before & 1) continue;
        TransportPlayhead p;
        p.sample = phSample_.load(std::memory_order_relaxed);
        p.tick = phTick_.load(std::memory_order_relaxed);
        const uint8_t flags = phFlags_.load(std::memory_order_relaxed);
        p.loopStart = phLoopStart_.load(std::memory_order_relaxed);
        p.loopEnd = phLoopEnd_.load(std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_acquire);
        if (seq_.load(std::memory_order_relaxed) != before) continue;
        p.playing = flags & kPlayingFlag;
        p.recording = flags & kRecordingFlag;
        p.loopEnabled = flags & kLoopFlag;
        return p;
    }
}

// MARK: Audio thread

const TransportBlock& Transport::advance(const TempoMap& tempo, uint32_t numFrames) DAW_RT {
    // TIME-004: everything queued so far applies from this block's first frame. Bounded by the
    // queue's capacity (CONV-RT-04); anything pushed meanwhile waits for the next block.
    locatedWhilePlaying_ = false;
    uint64_t applied = 0;
    TransportCmd cmd;
    for (std::size_t i = 0; i < kCommandCapacity && commands_.pop(cmd); ++i) {
        apply(cmd, tempo);
        ++applied;
    }
    if (applied != 0) commandsApplied_.fetch_add(applied, std::memory_order_relaxed);

    // Before layOut(): the playhead shows this block's first frame, judged by the run it
    // belongs to, not by a wrap later in the block.
    publishPlayhead(tempo);
    layOut(tempo, numFrames);
    return block_;
}

void Transport::apply(const TransportCmd& cmd, const TempoMap& tempo) DAW_RT {
    switch (cmd.type) {
    case TransportCmdType::play:
        if (!playing_) {
            playing_ = true;
            runStart_ = pos_;
            runFromWrap_ = false;
        }
        break;
    case TransportCmdType::stop:
        playing_ = false;
        wrapPending_ = false;
        break;
    case TransportCmdType::locate:
        pos_ = tempo.tickToSample(cmd.tick);
        wrapPending_ = false;
        runStart_ = pos_;
        runFromWrap_ = false;
        if (playing_) locatedWhilePlaying_ = true;  // TIME-008
        break;
    case TransportCmdType::setLoop:
        loopEnabled_ = cmd.enabled;
        loopStart_ = cmd.tick;
        loopEnd_ = cmd.endTick;
        break;
    case TransportCmdType::setRecording:
        recording_ = cmd.enabled;
        break;
    }
}

void Transport::layOut(const TempoMap& tempo, uint32_t numFrames) DAW_RT {
    // TIME-005. seg[0] always carries the position, even when it isn't a segment.
    block_.playing = playing_;
    block_.recording = recording_;
    block_.tempo = &tempo;
    block_.numSegments = 0;
    block_.seg[0] = makeSegment(tempo, pos_, 0, 0, false);
    block_.seg[1] = block_.seg[0];
    if (!playing_ || numFrames == 0) return;

    const bool afterWrap = wrapPending_;
    wrapPending_ = false;

    // Loop points are ticks, so they are resolved through this block's map (TIME-003). A loop
    // that is empty in samples is off.
    SamplePos loopStart = 0, loopEnd = 0;
    bool looping = loopEnabled_;
    if (looping) {
        loopStart = tempo.tickToSample(loopStart_);
        loopEnd = tempo.tickToSample(loopEnd_);
        looping = loopEnd > loopStart;
    }

    // The loop wraps only when playback crosses its end from before it; a playhead already past
    // the end plays on. Reaching the end exactly on the last frame wraps too, so the next block
    // starts at the loop start.
    const SamplePos end = pos_ + numFrames;
    if (!looping || pos_ >= loopEnd || end < loopEnd) {
        block_.seg[0] = makeSegment(tempo, pos_, 0, numFrames, afterWrap, wrapTick_);
        block_.numSegments = 1;
        pos_ = end;
    } else {
        const auto first = static_cast<uint32_t>(loopEnd - pos_);
        block_.seg[0] = makeSegment(tempo, pos_, 0, first, afterWrap, wrapTick_);
        block_.numSegments = 1;
        // Ending exactly on the loop end: the wrap shows on the next block's first segment.
        pos_ = loopStart;
        wrapPending_ = true;

        // Two segments at most (03 Interfaces): a loop shorter than the rest of the block plays
        // once, and the frames after it are left out (a gap; the next block wraps again).
        const uint32_t rest = numFrames - first;
        if (rest > 0) {
            const SamplePos loopLength = loopEnd - loopStart;
            const uint32_t second =
                rest < loopLength ? rest : static_cast<uint32_t>(loopLength);
            block_.seg[1] = makeSegment(tempo, loopStart, first, second, true, loopStart_);
            block_.numSegments = 2;
            pos_ = loopStart + second;
            wrapPending_ = pos_ == loopEnd;
            if (wrapPending_) pos_ = loopStart;
        }

        wrapTick_ = loopStart_;
        runStart_ = loopStart;
        runFromWrap_ = true;
        runLoopEnd_ = loopEnd;
    }

}

void Transport::publishPlayhead(const TempoMap& tempo) DAW_RT {
    // TIME-009: displayPos = samplePos − outputLatency while playing. Audio from before the
    // current run is still in flight, so a position before the run maps back into the loop when
    // the run began with a wrap, and clamps to where playback started otherwise. Stopped,
    // nothing is in flight and the playhead is just the position.
    SamplePos display = pos_;
    if (playing_) {
        display = pos_ - static_cast<SamplePos>(outputLatency_.load(std::memory_order_relaxed));
        if (display < runStart_) {
            const SamplePos length = runLoopEnd_ - runStart_;
            if (runFromWrap_ && length > 0)
                display = runLoopEnd_ - 1 - (runStart_ - 1 - display) % length;
            else
                display = runStart_;
        }
    }

    const uint8_t flags = (playing_ ? kPlayingFlag : 0) | (recording_ ? kRecordingFlag : 0) |
                          (loopEnabled_ ? kLoopFlag : 0);
    const uint64_t seq = seq_.load(std::memory_order_relaxed);
    seq_.store(seq + 1, std::memory_order_relaxed);
    std::atomic_thread_fence(std::memory_order_release);
    phSample_.store(display, std::memory_order_relaxed);
    phTick_.store(tempo.sampleToTick(display), std::memory_order_relaxed);
    phFlags_.store(flags, std::memory_order_relaxed);
    phLoopStart_.store(loopStart_, std::memory_order_relaxed);
    phLoopEnd_.store(loopEnd_, std::memory_order_relaxed);
    seq_.store(seq + 2, std::memory_order_release);
}

} // namespace daw
