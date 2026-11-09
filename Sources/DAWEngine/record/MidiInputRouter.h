#pragma once
// 09-recording REC-010..012 (T-053): live MIDI input.
//
//   - REC-010: each input (CoreMIDI source, io/CoreMidiInput) has an SpscQueue<MidiInEvent>. Its
//     producer converts the event's host time to a sample time on the render clock, against the
//     anchor the audio thread publishes every device cycle (host time at cycle start ↔ render
//     sample at cycle start), and pushes it. The render clock counts frames rendered, whether
//     the transport plays or not. A device stop leaves the anchor stale: a real input's event
//     that looks later than the block about to render is due now.
//   - REC-011: per block the audio thread merges the queues in time order. Armed tracks' MIDI
//     clip players read the result (events(), the block's live MIDI with frame offsets) and write
//     it into their midiOut, the path the instrument already reads (T-045). Every armed MIDI
//     track gets every input on all channels, and play-through ignores the monitoring mode
//     (docs/autobuild/DECISIONS.md "T-053 routing"). Real events are always a little in the past
//     at drain time, so they play at frame 0 of the next block; only the injected test input can
//     be in the future.
//   - REC-012: while the transport plays and records, notes also go to a preallocated record
//     buffer (overflow is counted, never blocks). A note lands at the transport sample it was
//     struck at minus the device output latency, the position the player heard (MIX-023: the
//     transport position is already what the graph outputs, so PDC isn't subtracted). On stop,
//     finalize() pairs the notes (an on with no off ends at stop; a note held across a loop wrap
//     ends at the loop end) and hands back one take per armed track. Nothing played: no take.
//
// Hanging notes. The router tracks which notes each input holds (a note-on repeated on the same
// input is ignored). A note goes to the players when the first input presses it and comes off
// when the last releases it. An input that disappears, or whose queue overflowed, gets a
// note-off for everything it held, and CC 120/123 end only that input's notes, so a controller
// panic doesn't cut the track's clip notes. The player tracks what it actually sent and sends the
// offs itself when its track is disarmed (MidiClipPlayer.h).
//
// Threads: receive() is the input's producer (one per input: the CoreMIDI thread); inject() and
// the control functions are non-RT, one caller at a time (the facade lock), beginBlock and the
// accessors are RT, the render thread. The session handshake is T-052's Dekker pattern
// (Recorder.h).

#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <span>
#include <vector>

#include "core/LiveMidiInput.h"
#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/Realtime.h"
#include "core/SpscQueue.h"

namespace daw {

class Transport;
struct TransportBlock;

// REC-010: one message from an input, timestamped on the render clock.
struct MidiInEvent {
    int64_t sampleTime = 0;  // render clock
    uint64_t hostTime = 0;   // host ticks it happened at (0: injected)
    uint8_t data[3] = {0, 0, 0};
    uint8_t size = 0;
};

// REC-012: one recorded note, in timeline samples (latency-compensated).
struct RecordedMidiNote {
    int64_t start = 0;
    int64_t end = 0;
    uint8_t pitch = 0, velocity = 0, channel = 0;
};

// REC-012: what finalize() reports for one armed track.
struct FinalizedMidiTake {
    NodeID track = 0;
    int64_t startSample = 0;  // the compensated record start (may be < 0)
    int64_t endSample = 0;    // the compensated stop
    double sampleRate = 0;
    uint64_t droppedEvents = 0;  // the record buffer was full
    std::vector<RecordedMidiNote> notes;
};

class MidiInputRouter final : public LiveMidiInput {
public:
    static constexpr uint32_t kMaxInputs = 32;     // CoreMIDI sources at once
    static constexpr uint32_t kInjectedSlot = kMaxInputs;  // the test seam's own input
    static constexpr uint32_t kNumSlots = kMaxInputs + 1;
    static constexpr uint32_t kMaxArmed = 64;
    static constexpr std::size_t kQueueSize = 1024;       // per input
    static constexpr uint32_t kMaxLiveEvents = 4096;      // per block, offs included
    static constexpr uint32_t kMaxMergedPerBlock = 256;   // the rest wait for the next block
    static constexpr uint32_t kMaxRecordEvents = 1u << 16;
    static constexpr double kStaleSeconds = 1.0;  // a note-on this old isn't played any more

    MidiInputRouter();
    MidiInputRouter(const MidiInputRouter&) = delete;
    MidiInputRouter& operator=(const MidiInputRouter&) = delete;

    // MARK: Producers

    // Non-RT: claims a free input slot (-1 if none) / gives it back. A closed input's held notes
    // get their note-offs on the next block; the slot is reusable once the audio thread has seen
    // it.
    int openInput();
    void closeInput(int slot);

    // REC-010, the input's producer thread (CoreMIDI's). `hostTime` 0 means now. False: the queue
    // was full (counted, and the input's notes are ended so none hangs).
    bool receive(int slot, uint64_t hostTime, const uint8_t* bytes, uint8_t size);

    // T-053 test seam, non-RT, one caller at a time: a message as if struck at transport sample
    // `atSample` (or `atSample` frames from now, with `relativeToNow`, or at once while the
    // transport is stopped). False: invalid message or queue full.
    bool inject(int64_t atSample, bool relativeToNow, const uint8_t* bytes, uint8_t size);

    // REC-010, any thread: the render-clock sample of host time `hostTime`, against the last
    // anchor (0 before the first block).
    int64_t sampleTimeOfHost(uint64_t hostTime) const;

    // MARK: Control (non-RT, one caller at a time)

    // REC-011: `track` records, and its clip player (`player`, 0 for none) plays through.
    void setArmed(NodeID track, NodeID player, bool armed);
    std::size_t armedCount() const { return armed_.size(); }
    // False while an export renders: nothing is played through and nothing is drained.
    void setLiveEnabled(bool enabled) { liveEnabled_.store(enabled, std::memory_order_release); }

    // REC-012. Like Recorder::prepare/capturing/finalize: prepare makes a session for the armed
    // tracks ready (returns what a replaced one recorded, normally nothing), capturing says the
    // audio thread has begun recording into it, finalize ends it and returns one take per armed
    // track, or nothing if no note was played.
    std::vector<FinalizedMidiTake> prepare(double sampleRate);
    bool capturing() const;
    std::vector<FinalizedMidiTake> finalize();

    // Telemetry: events dropped (a full queue or a full record buffer), all time.
    uint64_t droppedEvents() const { return dropped_.load(std::memory_order_relaxed); }

    // MARK: RT, render thread (LiveMidiInput)

    void beginBlock(const Transport& transport, uint32_t numFrames, double sampleRate,
                    uint64_t cycleHostTicks) DAW_RT override;
    void endBlock() DAW_RT override { blockActive_ = false; }
    void idleBlock(uint32_t numFrames, uint64_t cycleHostTicks) DAW_RT override;

    // MARK: RT, the players (during a block)

    // Between beginBlock and endBlock of a real block (false during pre-roll and exports).
    bool blockActive() const DAW_RT { return blockActive_; }
    // Whether `player` plays through.
    bool isArmed(NodeID player) const DAW_RT;
    // This block's live events, in frame order.
    MidiEventSpan events() const DAW_RT { return MidiEventSpan(live_, numLive_); }
    // Keys and controllers currently held, across all inputs: for a re-created player to sound
    // them again.
    bool heldNote(uint8_t channel, uint8_t pitch, uint8_t& velocity) const DAW_RT;
    uint16_t pedalMask() const DAW_RT;  // channels with the sustain pedal down
    uint16_t bendMask() const DAW_RT { return bendMask_; }  // channels bent off centre

private:
    enum SlotState : uint8_t { kFree = 0, kOpen = 1, kClosing = 2 };

    struct Input {
        std::atomic<uint8_t> state{kFree};
        std::atomic<bool> overflowed{false};
        SpscQueue<MidiInEvent, kQueueSize> queue;
        // Render thread only.
        MidiInEvent pending;
        bool hasPending = false;
        uint64_t held[16][2] = {};
        uint16_t pedal = 0;
    };

    struct RecEvent {
        int64_t sample;
        int32_t pass;
        bool on;
        uint8_t pitch, velocity, channel;
    };

    // Everything an event needs from its block (on the stack in beginBlock).
    struct BlockInfo {
        const TransportBlock* block = nullptr;
        int64_t blockStart = 0;
        uint32_t numFrames = 0;
        uint64_t hostNow = 0;
        // REC-012.
        bool recording = false;
        int64_t latency = 0;
        bool loopOn = false;
        int64_t loopStart = 0, loopLength = 0;
        int32_t passBefore = 0;
        int32_t passOfSegment[2] = {0, 0};
    };

    // The clock anchor (a seqlock: the audio thread is the only writer).
    struct Anchor {
        uint64_t hostTicks = 0;     // host time of the last cycle start
        int64_t hostSample = 0;     // render clock at that moment
        int64_t renderSample = 0;   // render clock at the last block start
        int64_t transportSample = 0;
        double sampleRate = 0;
        bool playing = false;
        bool valid = false;
    };

    void publishAnchor(const Anchor& anchor) DAW_RT;
    bool readAnchor(Anchor& anchor) const;
    int64_t sampleTimeOf(uint64_t hostTime, const Anchor& anchor) const;
    bool pushEvent(uint32_t slot, const MidiInEvent& event);

    void drain(const BlockInfo& info) DAW_RT;
    void handleEvent(Input& input, const MidiInEvent& event, const BlockInfo& info) DAW_RT;
    void noteOn(Input& input, uint8_t channel, uint8_t pitch, uint8_t velocity, int64_t frame,
                const BlockInfo& info) DAW_RT;
    void noteOff(Input& input, uint8_t channel, uint8_t pitch, int64_t frame, const BlockInfo& info) DAW_RT;
    // Note-offs for what `input` holds on `channel`; pedal up with `pedalToo`.
    void releaseChannel(Input& input, uint8_t channel, int64_t frame, const BlockInfo& info, bool pedalToo) DAW_RT;
    void setPedal(Input& input, uint8_t channel, bool down, int64_t frame, const BlockInfo& info) DAW_RT;
    void emitLive(const uint8_t* data, uint8_t size, int64_t frame, const BlockInfo& info) DAW_RT;
    void recordNote(bool on, uint8_t channel, uint8_t pitch, uint8_t velocity, int64_t frame,
                    const BlockInfo& info) DAW_RT;
    bool heardPosition(int64_t frame, const BlockInfo& info, int64_t& heard, int32_t& pass) const DAW_RT;

    void deactivate();
    std::vector<FinalizedMidiTake> collect();

    std::unique_ptr<Input[]> inputs_;
    std::unique_ptr<RecEvent[]> recordBuffer_;
    double hostTicksPerSecond_ = 0;

    // The anchor's fields, each atomic so the seqlock's readers never race the writer.
    std::atomic<uint64_t> anchorSeq_{0};
    std::atomic<uint64_t> anchorHost_{0};
    std::atomic<int64_t> anchorHostSample_{0};
    std::atomic<int64_t> anchorRenderSample_{0};
    std::atomic<int64_t> anchorTransport_{0};
    std::atomic<double> anchorRate_{0};
    std::atomic<bool> anchorPlaying_{false};
    std::atomic<bool> anchorValid_{false};

    std::atomic<bool> liveEnabled_{true};
    std::atomic<uint64_t> dropped_{0};
    // REC-011: player IDs, one writer (setArmed); a slot is stable while its player stays armed.
    std::atomic<NodeID> armedPlayers_[kMaxArmed]{};

    // Render thread only.
    int64_t renderSample_ = 0;
    uint64_t lastCycleHost_ = 0;
    int64_t lastCycleSample_ = 0;
    bool blockActive_ = false;
    MidiEvent live_[kMaxLiveEvents]{};
    uint32_t numLive_ = 0;
    uint32_t lastLiveFrame_ = 0;
    uint8_t holders_[16][128] = {};   // inputs holding each key
    uint8_t velocities_[16][128] = {};
    uint16_t bendMask_ = 0;

    // REC-012 session. The audio thread uses it only while sessionActive_; the control side only
    // after deactivate().
    std::atomic<bool> sessionActive_{false};
    std::atomic<bool> rtBusy_{false};
    std::atomic<bool> recStarted_{false};
    std::atomic<uint32_t> recCount_{0};
    std::atomic<uint64_t> recDropped_{0};
    int64_t recStartHeard_ = 0;
    int64_t recEndHeard_ = 0;
    int32_t recLastPass_ = 0;
    int64_t recLoopEnd_ = 0;
    int32_t pass_ = 0;
    int64_t prevEnd_ = 0;
    bool havePrev_ = false;

    // Control side.
    std::map<NodeID, NodeID> armed_;     // track → player
    std::map<NodeID, uint32_t> armedIndex_;  // player → armedPlayers_ index
    std::vector<NodeID> sessionTracks_;
    double sessionRate_ = 0;
};

} // namespace daw
