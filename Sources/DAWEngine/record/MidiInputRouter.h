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
//     it into their midiOut, the path the instrument already reads (T-045). Play-through ignores
//     the monitoring mode (docs/autobuild/DECISIONS.md "T-053 routing"). Real events are always a
//     little in the past at drain time, so they play at frame 0 of the next block; only the
//     injected test input can be in the future.
//   - REC-011 per-track input (T-093, DW-216, DECISIONS "T-093 model shape"): each armed track
//     has a filter (a source, by CoreMIDI unique ID, or all; a channel 1…16, or omni), by default
//     all/omni, which is every input on every channel as before. The armed tracks live in a
//     preallocated table of lanes; each lane has its own live stream, held-key counts, pedal and
//     bend state, so the audio thread filters without allocating or locking. A filter is set from
//     the control side at any time (armed or not) and applies from the next block. A source that
//     isn't connected delivers nothing. The channel filter applies to channel-voice messages; the
//     router never sees system messages (receive and inject refuse them), so they don't reach any
//     track, omni or not.
//   - REC-012: while the transport plays and records, notes also go to a preallocated record
//     buffer (overflow is counted, never blocks). A note lands at the transport sample it was
//     struck at minus the device output latency, the position the player heard (MIX-023: the
//     transport position is already what the graph outputs, so PDC isn't subtracted). On stop,
//     finalize() pairs the notes (an on with no off ends at stop; a note held across a loop wrap
//     ends at the loop end) and hands back one take per armed track. Nothing played: no take.
//
// Hanging notes. The router tracks which notes each input holds (a note-on repeated on the same
// input is ignored). A note goes to a track's player when the first input its filter passes
// presses it and comes off when the last of them releases it. When a track's filter changes, the
// router recounts what the new filter passes and, in the next block, sends note-offs for the keys
// (pedal up, bend centred) that track no longer hears and note-ons for held keys it now hears, so
// a filter change never hangs a note (T-093). An input that disappears, or whose queue overflowed, gets a
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

// T-093: a track's input filter. `allSources` or the CoreMIDI source with `source` as its unique
// ID; `channel` 0 is omni, 1…16 one channel.
struct MidiInputFilter {
    bool allSources = true;
    int32_t source = 0;
    uint8_t channel = 0;

    bool operator==(const MidiInputFilter&) const = default;
};

// REC-012: one recorded note, in timeline samples (latency-compensated).
struct RecordedMidiNote {
    int64_t start = 0;
    int64_t end = 0;
    uint8_t pitch = 0, velocity = 0, channel = 0;
    int32_t pass = 0;  // REC-034 (T-080): the loop pass its note-on was heard in (0 without a wrap)
};

// REC-012: what finalize() reports for one armed track.
struct FinalizedMidiTake {
    NodeID track = 0;
    int64_t startSample = 0;  // the compensated record start (may be < 0)
    int64_t endSample = 0;    // the compensated stop
    double sampleRate = 0;
    uint64_t droppedEvents = 0;  // the record buffer was full
    std::vector<RecordedMidiNote> notes;
    // REC-034 (T-080): the loop passes the take spans (1 without a wrap). Pass 0 starts at
    // startSample, every later one at loopStart (timeline samples, as heard), and the last one
    // ends at endSample. loopStart/loopEnd are 0 without a wrap.
    uint32_t passes = 1;
    int64_t loopStart = 0;
    int64_t loopEnd = 0;
};

class MidiInputRouter final : public LiveMidiInput {
public:
    static constexpr uint32_t kMaxInputs = 32;     // CoreMIDI sources at once
    static constexpr uint32_t kInjectedSlot = kMaxInputs;  // the test seam's own input (no source ID)
    // T-093: the test seam's inputs posing as a source ID, bound on first use.
    static constexpr uint32_t kMaxInjectedSources = 4;
    static constexpr uint32_t kNumSlots = kMaxInputs + 1 + kMaxInjectedSources;
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
    // it. `source` is the CoreMIDI unique ID a track's filter names it by (T-093); an input opened
    // without one passes only "all sources" filters.
    int openInput(int32_t source);
    int openInput();
    void closeInput(int slot);

    // REC-010, the input's producer thread (CoreMIDI's). `hostTime` 0 means now. False: the queue
    // was full (counted, and the input's notes are ended so none hangs).
    bool receive(int slot, uint64_t hostTime, const uint8_t* bytes, uint8_t size);

    // T-053 test seam, non-RT, one caller at a time: a message as if struck at transport sample
    // `atSample` (or `atSample` frames from now, with `relativeToNow`, or at once while the
    // transport is stopped). False: invalid message or queue full.
    bool inject(int64_t atSample, bool relativeToNow, const uint8_t* bytes, uint8_t size);
    // T-093: the same, as if from the source with unique ID `source` (one of kMaxInjectedSources
    // test inputs, bound to the ID on first use; false once they are all bound to other IDs).
    bool inject(int32_t source, int64_t atSample, bool relativeToNow, const uint8_t* bytes, uint8_t size);

    // REC-010, any thread: the render-clock sample of host time `hostTime`, against the last
    // anchor (0 before the first block).
    int64_t sampleTimeOfHost(uint64_t hostTime) const;

    // MARK: Control (non-RT, one caller at a time)

    // REC-011: `track` records, and its clip player (`player`, 0 for none) plays through.
    void setArmed(NodeID track, NodeID player, bool armed);
    std::size_t armedCount() const { return armed_.size(); }
    // T-093: what `track` hears, armed or not (kept while disarmed; the default forgets it).
    void setInputFilter(NodeID track, const MidiInputFilter& filter);
    MidiInputFilter inputFilter(NodeID track) const;
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
    // This block's live events for `player`'s track (its filter applied), in frame order.
    MidiEventSpan events(NodeID player) const DAW_RT;
    // Keys and controllers `player`'s track currently hears held: for a re-created player to
    // sound them again.
    bool heldNote(NodeID player, uint8_t channel, uint8_t pitch, uint8_t& velocity) const DAW_RT;
    uint16_t pedalMask(NodeID player) const DAW_RT;  // channels with the sustain pedal down
    uint16_t bendMask(NodeID player) const DAW_RT;   // channels bent off centre

private:
    enum SlotState : uint8_t { kFree = 0, kOpen = 1, kClosing = 2 };

    struct Input {
        std::atomic<uint8_t> state{kFree};
        std::atomic<bool> overflowed{false};
        // T-093: the source a filter names it by (set before the slot opens).
        std::atomic<bool> hasSource{false};
        std::atomic<int32_t> source{0};
        SpscQueue<MidiInEvent, kQueueSize> queue;
        // Render thread only.
        MidiInEvent pending;
        bool hasPending = false;
        uint64_t held[16][2] = {};
        uint16_t pedal = 0;
        uint16_t bend = 0;  // channels this input bent off centre (T-093)
    };

    // T-093: one armed track. The control side writes the atomics (track 0: free) and bumps
    // `generation` whenever the track or player changes; `filter` changes alone mean a retarget.
    struct ArmedSlot {
        std::atomic<NodeID> track{0};
        std::atomic<NodeID> player{0};
        std::atomic<uint64_t> filter{0};  // packFilter
        std::atomic<uint32_t> generation{0};
    };

    // T-093: the audio thread's copy of an armed slot and what that track hears.
    struct Lane {
        bool active = false;
        uint32_t generation = 0;
        NodeID player = 0;
        uint64_t filter = 0;
        uint8_t holders[16][128] = {};  // inputs the filter passes holding each key
        uint16_t pedal = 0;             // channels with the pedal down, as the track hears them
        uint16_t bend = 0;              // channels bent off centre in what it was sent
        MidiEvent live[kMaxLiveEvents]{};
        uint32_t numLive = 0;
        uint32_t lastFrame = 0;
    };

    struct RecEvent {
        int64_t sample;
        int32_t pass;
        bool on;
        uint8_t pitch, velocity, channel;
        uint64_t lanes;  // T-093: the armed slots whose filter passed it
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

    static uint64_t packFilter(const MidiInputFilter& filter);
    static MidiInputFilter unpackFilter(uint64_t packed);
    // T-093: whether a lane with `filter` hears `input` on `channel`.
    bool passes(uint64_t filter, const Input& input, uint8_t channel) const DAW_RT;
    // Channels a filter lets through (one bit per channel).
    static uint16_t channelMask(uint64_t filter) DAW_RT;
    // Brings the lanes up to the armed table: new tracks are counted quietly, retargeted ones
    // get the offs and ons of the difference.
    void syncLanes(const BlockInfo& info) DAW_RT;
    void countLane(const Lane& lane, uint8_t (&holders)[16][128], uint16_t& pedal, uint16_t& bend) const DAW_RT;
    int laneOf(NodeID player) const DAW_RT;
    uint32_t bindInjected(int32_t source);

    void clearLive() DAW_RT;
    void drain(const BlockInfo& info) DAW_RT;
    void handleEvent(Input& input, const MidiInEvent& event, const BlockInfo& info) DAW_RT;
    void noteOn(Input& input, uint8_t channel, uint8_t pitch, uint8_t velocity, int64_t frame,
                const BlockInfo& info) DAW_RT;
    void noteOff(Input& input, uint8_t channel, uint8_t pitch, int64_t frame, const BlockInfo& info) DAW_RT;
    // Note-offs for what `input` holds on `channel`; pedal up with `pedalToo`.
    void releaseChannel(Input& input, uint8_t channel, int64_t frame, const BlockInfo& info, bool pedalToo) DAW_RT;
    void setPedal(Input& input, uint8_t channel, bool down, int64_t frame, const BlockInfo& info) DAW_RT;
    // Into every lane that hears `input` on the message's channel.
    void emitLive(const Input& input, const uint8_t* data, uint8_t size, int64_t frame, const BlockInfo& info) DAW_RT;
    void emitLane(Lane& lane, const uint8_t* data, uint8_t size, int64_t frame, const BlockInfo& info) DAW_RT;
    void recordNote(const Input& input, bool on, uint8_t channel, uint8_t pitch, uint8_t velocity, int64_t frame,
                    const BlockInfo& info) DAW_RT;
    // A recorded event for the lanes in `heardBy` (one bit per armed slot).
    void recordEvent(uint64_t heardBy, bool on, uint8_t channel, uint8_t pitch, uint8_t velocity, int64_t frame,
                     const BlockInfo& info) DAW_RT;
    bool heardPosition(int64_t frame, const BlockInfo& info, int64_t& heard, int32_t& pass) const DAW_RT;

    void deactivate();
    std::vector<FinalizedMidiTake> collect();
    // REC-012: the recorded events the lane with `laneBit` heard, paired into notes.
    std::vector<RecordedMidiNote> pairNotes(uint32_t count, uint64_t laneBit) const;

    std::unique_ptr<Input[]> inputs_;
    std::unique_ptr<Lane[]> lanes_;  // kMaxArmed, render thread only
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
    // REC-011: the armed tracks, one writer (setArmed, setInputFilter); a slot is stable while its
    // track stays armed (T-093: per track, so a track without a player records too).
    ArmedSlot armedSlots_[kMaxArmed];

    // Render thread only.
    int64_t renderSample_ = 0;
    uint64_t lastCycleHost_ = 0;
    int64_t lastCycleSample_ = 0;
    bool blockActive_ = false;
    uint32_t maxLive_ = 0;  // the fullest lane's live events this block
    uint8_t velocities_[16][128] = {};  // the last velocity each key was struck with

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
    int64_t recLoopStart_ = 0;  // REC-034 (T-080)
    int64_t recLoopEnd_ = 0;
    int32_t pass_ = 0;
    int64_t prevEnd_ = 0;
    bool havePrev_ = false;

    // Control side.
    std::map<NodeID, NodeID> armed_;     // track → player
    std::map<NodeID, uint32_t> armedIndex_;  // track → armedSlots_ index
    std::map<NodeID, MidiInputFilter> filters_;  // T-093: tracks with a filter other than all/omni
    std::map<int32_t, uint32_t> injectedSources_;  // T-093: source ID → injected input slot
    uint32_t nextGeneration_ = 0;
    std::vector<NodeID> sessionTracks_;
    std::vector<uint32_t> sessionSlots_;  // T-093: each session track's armedSlots_ index
    double sessionRate_ = 0;
};

} // namespace daw
