#pragma once
// 03-time-transport TIME-004..009: the transport. The audio thread owns its state (playing,
// recording, samplePos, loop); other threads change it only through commands, which are applied
// at the start of the next block (TIME-004), and read it only through the playhead (TIME-009).
//
// Per block, advance() turns the state into a TransportBlock (TIME-005): the frames of the block
// laid out on the timeline as at most two segments, split where the loop wraps. Timeline nodes
// walk them with the helpers in TransportSegments.h (TIME-006).
//
// Threads:
//   - Commands (play, stop, locate, setLoop, setRecording): any number of non-RT threads. They
//     serialize on a producer-side mutex, so the SpscQueue behind them always has exactly one
//     producer at a time. The audio thread never takes that mutex.
//   - setOutputLatency: any thread (the device driver, IO-004).
//   - playhead(): any non-RT thread (UI readout, facade).
//   - advance() and the RT accessors: the audio thread only, one block at a time.
//
// Positions: samplePos is the source of truth, so the playhead stays where it is in samples when
// a new tempo map arrives. Ticks (locate targets, loop points) are converted through the tempo
// map of the block they are applied in, so the loop follows tempo edits (TIME-003).

#include <atomic>
#include <cstdint>
#include <mutex>

#include "core/Realtime.h"
#include "core/SpscQueue.h"
#include "time/TempoMap.h"
#include "time/TransportBlock.h"

namespace daw {

enum class TransportCmdType : uint8_t { play, stop, locate, setLoop, setRecording };

// TIME-004: one queued command. `enabled` is setLoop's and setRecording's flag; `tick` is the
// locate target or the loop start, `endTick` the loop end.
struct TransportCmd {
    TransportCmdType type = TransportCmdType::stop;
    bool enabled = false;
    Tick tick = 0;
    Tick endTick = 0;
};

// TIME-009: what the UI reads. `sample`/`tick` are the position being heard, i.e. compensated
// for output latency (displayPos = samplePos − outputLatency, see Transport::playhead()).
struct TransportPlayhead {
    SamplePos sample = 0;
    Tick tick = 0;
    bool playing = false;
    bool recording = false;
    bool loopEnabled = false;
    Tick loopStart = 0;
    Tick loopEnd = 0;
};

class Transport {
public:
    static constexpr std::size_t kCommandCapacity = 256;

    Transport() = default;
    Transport(const Transport&) = delete;
    Transport& operator=(const Transport&) = delete;

    // TIME-004, non-RT, any thread. Each returns false (and changes nothing) when the command
    // queue is full or the arguments are invalid. Applied at the start of the next block.
    bool play();
    bool stop();  // keeps the position
    bool locate(Tick tick);
    // A loop needs start < end when enabled; when disabled the ticks are kept for readout.
    bool setLoop(bool enabled, Tick start, Tick end);
    bool setRecording(bool recording);

    // TIME-009, any thread: the device's output latency in samples (IO-004). Takes effect on the
    // next block.
    void setOutputLatency(uint32_t samples) {
        outputLatency_.store(samples, std::memory_order_relaxed);
    }
    uint32_t outputLatency() const { return outputLatency_.load(std::memory_order_relaxed); }

    // TIME-009, any non-RT thread: the playhead as of the last block. Lock-free; retries only
    // while the audio thread is publishing a new value.
    TransportPlayhead playhead() const;

    // Diagnostics: commands applied so far.
    uint64_t commandsApplied() const { return commandsApplied_.load(std::memory_order_relaxed); }

    // RT, audio thread. ENG-041 "advance transport": applies queued commands, lays out the next
    // `numFrames` frames (TIME-005), advances samplePos and publishes the playhead. `tempo` is
    // the current graph's map (TIME-003); the returned block points at it and is valid until the
    // next advance().
    const TransportBlock& advance(const TempoMap& tempo, uint32_t numFrames) DAW_RT;

    // RT, audio thread: about the last advance().
    const TransportBlock& block() const DAW_RT { return block_; }
    // TIME-008: a locate was applied while playing, so timeline nodes must reset() before this
    // block is processed.
    bool locatedWhilePlaying() const DAW_RT { return locatedWhilePlaying_; }

    // RT, audio thread: the transport's own state (TIME-004). samplePos is the first frame of
    // the next block.
    bool playing() const DAW_RT { return playing_; }
    bool recording() const DAW_RT { return recording_; }
    SamplePos samplePos() const DAW_RT { return pos_; }
    bool loopEnabled() const DAW_RT { return loopEnabled_; }
    Tick loopStart() const DAW_RT { return loopStart_; }
    Tick loopEnd() const DAW_RT { return loopEnd_; }

private:
    bool push(const TransportCmd& cmd);
    void apply(const TransportCmd& cmd, const TempoMap& tempo) DAW_RT;
    void layOut(const TempoMap& tempo, uint32_t numFrames) DAW_RT;
    void publishPlayhead(const TempoMap& tempo) DAW_RT;

    // Producers.
    std::mutex producerMutex_;
    SpscQueue<TransportCmd, kCommandCapacity> commands_;
    std::atomic<uint32_t> outputLatency_{0};

    // Audio thread only.
    bool playing_ = false;
    bool recording_ = false;
    bool loopEnabled_ = false;
    Tick loopStart_ = 0;
    Tick loopEnd_ = 0;
    SamplePos pos_ = 0;
    // The last block ended exactly on the loop end: pos_ is already the loop start, and the
    // next segment is the first after the wrap.
    bool wrapPending_ = false;
    Tick wrapTick_ = 0;  // loop start tick of the last wrap
    bool locatedWhilePlaying_ = false;
    TransportBlock block_{};

    // TIME-009 latency compensation: the current stretch of uninterrupted playback started at
    // runStart_, either by play/locate or by a loop wrap from runLoopEnd_ back to runStart_.
    SamplePos runStart_ = 0;
    bool runFromWrap_ = false;
    SamplePos runLoopEnd_ = 0;

    // TIME-009: a seqlock. The audio thread makes seq_ odd, stores the fields, makes it even;
    // readers retry until they see the same even value before and after.
    std::atomic<uint64_t> seq_{0};
    std::atomic<SamplePos> phSample_{0};
    std::atomic<Tick> phTick_{0};
    std::atomic<uint8_t> phFlags_{0};
    std::atomic<Tick> phLoopStart_{0};
    std::atomic<Tick> phLoopEnd_{0};

    std::atomic<uint64_t> commandsApplied_{0};
};

} // namespace daw
