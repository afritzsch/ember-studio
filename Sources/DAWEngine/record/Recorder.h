#pragma once
// 09-recording REC-001..005 (T-052): audio recording.
//
//   - REC-001: armed tracks each have an input channel pair. While the transport plays and
//     records, the audio thread (captureBlock, via DeviceRenderer's InputCapture seam) copies the
//     pair's frames into the track's preallocated RecordFifo.
//   - REC-002: daw.diskwrite drains the FIFOs into 32-bit float CAF files in the recordings
//     directory. A full FIFO drops the block (never blocks the audio thread): droppedFrames()
//     counts it for telemetry (`recordDrops`), the take reports it when it is finalized, and the
//     file gets silence in its place so later audio keeps its timeline position.
//   - REC-003: a frame captured while the transport is at sample q was played at q − D, where
//     D = input + output latency (setLatency): it left the outputs at q (the transport position
//     is what the graph outputs, MIX-023) after the output latency and came back after the input
//     latency. So a take's first frame belongs at startSample = q₀ − D.
//   - REC-005: with a punch range set and the transport's loop off, only frames whose timeline
//     position (q − D) lies inside [punchIn, punchOut) are recorded.
//   - REC-004: finalize() ends the take: no more capture, the FIFOs are drained, the files closed,
//     and one FinalizedTake per track that recorded anything is returned (the facade turns them
//     into recordingFinalized events).
//
// Takes. All armed tracks record into one session (a take per track). prepare() makes it ready
// (allocating its FIFOs, non-RT); it starts when the first frame is captured. A finished session
// is replaced by a new one at the next prepare(). A take is one continuous file: if the transport
// wraps a loop while recording, the file runs on, and the take reports where each loop pass
// starts in it (REC-030, T-080; the model makes the passes takes, clip views into the file).
//
// Loop passes (REC-030, T-080). The audio thread logs the session frame of every wrap (a
// preallocated log, kMaxWraps; later wraps are ignored and their audio stays in the last pass).
// finalize() turns them into FinalizedTake::passStarts: the file frame holding the loop start in
// each pass, i.e. the wrap shifted by the REC-003 latency D (a frame captured at transport q
// belongs at q − D, so the loop start of the pass that began at wrap frame w is file frame w + D,
// and the D frames before it still end the pass before). DW-243: with a loop shorter than the
// device block, Engine::render lays the block out in several passes and Transport::block() keeps
// only the last one (Transport.h). The capture writes the whole block anyway (with the loop on
// there is no punch) and rebuilds the wraps before the last pass: they repeat every loop length
// back from its start, beginning where the previous block left off (or, when that doesn't fit,
// e.g. after a tempo edit, with the block's first frame inside the loop).
//
// Threads: the control functions are non-RT and called by one thread at a time (the facade,
// under its lock); captureBlock is RT, from the engine's render thread; daw.diskwrite is the
// recorder's own thread. The audio thread finds the session through an atomic pointer and a
// busy flag (Dekker, seq_cst): a session is retired only after the pointer is cleared and the
// audio thread is seen not inside captureBlock, so it never reads a freed session.

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "core/Node.h"
#include "core/Result.h"
#include "io/InputCapture.h"
#include "time/TempoMap.h"

namespace daw {

class Transport;

// REC-004: what finalize() reports for one track.
struct FinalizedTake {
    NodeID track = 0;
    uint32_t inputPair = 0;
    std::string file;           // absolute path; empty if the file couldn't be written (`error`)
    int64_t startSample = 0;    // REC-003: timeline sample (session rate) of the file's first frame
    int64_t frames = 0;         // in the file (silence in place of dropped blocks included)
    uint32_t takeIndex = 0;     // 0: one file per track and take (REC-030 passes: passStarts)
    uint32_t channels = 2;
    double sampleRate = 0;
    uint64_t droppedFrames = 0; // REC-002: frames the FIFO had no room for
    std::optional<Error> error; // the file couldn't be created or written
    // REC-030 (T-080): the loop passes in the file. Empty when the transport never wrapped inside
    // the take; else passStarts[0] == 0 (the first pass starts at startSample) and passStarts[i],
    // i ≥ 1, is the file frame that holds the loop start (timeline sample loopStart) in pass i,
    // ascending and < frames. A pass runs to the next pass start (the last one to the end of the
    // file, possibly partial). loopStart/loopEnd: the loop's timeline samples (session rate).
    std::vector<int64_t> passStarts;
    int64_t loopStart = 0;
    int64_t loopEnd = 0;
};

struct PunchRange {
    bool enabled = false;
    Tick in = 0;
    Tick out = 0;
};

class Recorder final : public InputCapture {
public:
    // How many tracks can record at once.
    static constexpr std::size_t kMaxTracks = 64;
    // Input channel pairs (channels 2p, 2p+1); the device view is capped at kMaxDeviceChannels.
    static constexpr uint32_t kMaxInputPairs = 16;
    // REC-030: loop wraps a session logs (a one-sample loop at 48 kHz fills it in 1.4 s).
    static constexpr uint32_t kMaxWraps = 1u << 16;

    Recorder();   // starts daw.diskwrite
    ~Recorder();  // finalizes (the results are dropped) and joins it; nothing may capture any more
    Recorder(const Recorder&) = delete;
    Recorder& operator=(const Recorder&) = delete;

    // MARK: Control (non-RT, one caller at a time)

    // Where files go. Created when the first take needs it. Empty: $TMPDIR/EmberStudio-Recordings-<pid>.
    void setDirectory(const std::filesystem::path& directory);
    std::filesystem::path directory() const;

    // REC-001. A pair beyond kMaxInputPairs is clamped. Takes effect at the next prepare().
    void setArmed(NodeID track, uint32_t inputPair, bool armed);
    bool anyArmed() const;
    std::size_t armedCount() const;

    // REC-003: D = input + output latency of the running device, in samples.
    void setLatency(uint32_t samples) { latency_.store(samples, std::memory_order_relaxed); }
    uint32_t latency() const { return latency_.load(std::memory_order_relaxed); }

    // REC-005. Ignored while the transport loops (punch applies with the loop off).
    void setPunch(const PunchRange& punch);
    PunchRange punch() const;

    // Makes the session the audio thread records into match the armed tracks and `sampleRate`:
    // kept if it does, replaced if it hasn't started, left alone once it has (finalize first).
    // With nothing armed, the idle session is dropped. Allocates (non-RT). Returns what the
    // replaced session recorded if the audio thread started it in the meantime (else empty).
    std::vector<FinalizedTake> prepare(double sampleRate);
    // A take has started (the audio thread captured a frame since the last finalize).
    bool capturing() const;
    // REC-004: ends the take and returns it, one entry per track that captured anything, after
    // every frame is on disk and the files are closed. Nothing captured: empty.
    std::vector<FinalizedTake> finalize();

    // REC-002: frames dropped because a FIFO was full, all takes.
    uint64_t droppedFrames() const { return dropped_.load(std::memory_order_relaxed); }

    // Tests (REC-002 stress): while paused, daw.diskwrite doesn't drain (finalize still does).
    void pauseWriter(bool paused);
    // Tests: frames waiting in the current session's FIFOs.
    std::size_t queuedFrames() const;

    // MARK: RT

    void captureBlock(const Transport& transport, const AudioBufferView& input, uint32_t numFrames) DAW_RT override;

private:
    struct Take;
    struct Session;

    void diskLoop();
    // daw.diskwrite: everything queued so far into the files.
    void drain(Session& session);
    void drainTake(Session& session, Take& take);
    void openFile(Session& session, Take& take);
    // Stops the audio thread from using the current session; returns it.
    std::shared_ptr<Session> deactivate();
    // Has daw.diskwrite drain and close a deactivated session; its takes (empty if it never started).
    std::vector<FinalizedTake> finish(std::shared_ptr<Session> session);
    // REC-030, RT: a wrap at session frame `at` of the loop [loopStart, loopEnd).
    static void logWrap(Session& session, int64_t at, SamplePos loopStart, SamplePos loopEnd) DAW_RT;
    // REC-001, RT: frames [from, from + n) of `input` into every take, the first of them at
    // timeline sample `first` (latency-compensated).
    static void capture(Session& session, const AudioBufferView& input, uint32_t from, uint32_t n,
                        SamplePos first, int64_t latency, std::atomic<uint64_t>& dropped) DAW_RT;

    // Audio thread's view.
    std::atomic<Session*> active_{nullptr};
    std::atomic<bool> rtBusy_{false};
    std::atomic<uint32_t> latency_{0};
    std::atomic<uint64_t> dropped_{0};
    // REC-005, a seqlock: the writer (setPunch) makes punchSeq_ odd, stores, makes it even.
    std::atomic<uint64_t> punchSeq_{0};
    std::atomic<bool> punchEnabled_{false};
    std::atomic<Tick> punchIn_{0};
    std::atomic<Tick> punchOut_{0};
    // Audio thread only: the last punch read whole, and the transport position at the last call
    // (a block whose transport didn't advance isn't captured twice).
    PunchRange rtPunch_{};
    SamplePos lastPos_ = 0;
    bool hasLastPos_ = false;
    // DW-243, audio thread only: the transport position just after the last frame of the last
    // block that played (unwrapped: the loop end if it ended there), so a block laid out in
    // several passes knows where it began.
    SamplePos prevEnd_ = 0;
    bool hasPrevEnd_ = false;
    bool prevEndedOnLoopEnd_ = false;  // ...exactly on the loop end (see captureBlock)

    // Control side.
    std::map<NodeID, uint32_t> armed_;  // track → input pair
    PunchRange punch_{};

    mutable std::mutex mutex_;  // guards what follows (daw.diskwrite and the control side)
    std::condition_variable wake_;     // daw.diskwrite: a finalize, stopping
    std::condition_variable finished_; // finalize: daw.diskwrite is done with the request
    std::filesystem::path directory_;
    std::shared_ptr<Session> session_;          // the one active_ points at (or null)
    std::shared_ptr<Session> finalizeRequest_;  // daw.diskwrite: drain and close this one
    std::vector<FinalizedTake> finalized_;
    bool finalizeDone_ = false;
    bool paused_ = false;
    bool stopping_ = false;
    std::thread thread_;  // last
};

} // namespace daw
