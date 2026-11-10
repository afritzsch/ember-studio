#pragma once
// DSP-003: NodeKind::midiClipPlayer, the source node of a MIDI track. Writes note-on/off events
// for the track's notes into NodeIO::midiOut, each at the frame its tick sounds at; it has no
// audio output (NodeKindInfo::audioOutput false), so its instrument hangs off a MIDI edge.
//
// Note delivery (DW-051): like AudioClipPlayer, a player's notes are fixed when the node is
// created, so the model bumps its configVersion whenever that track's notes change. Notes with
// length <= 0, pitch > 127 or channel > 15 are dropped; velocity is clamped to 1..127 (a
// note-on with velocity 0 would be a note-off).
//
// Timing (D-06, TIME-006/007): notes stay in ticks and are placed through the block's TempoMap.
// A note's on sounds at tickToSample(start) and its off at tickToSample(start + length). Within
// a block events are in frame order; at the same tick offs come before ons, so a note that ends
// where the next one on its key starts retriggers cleanly.
//
// Chase (DW-103): playback that starts inside a note (play, locate, loop start, or a tempo edit
// that moved the playhead's tick) sounds it from that frame for its remaining length. On every
// segment that doesn't continue the previous one, after the releases below, each note with
// start < startTick whose off still sounds at or after the segment's first sample gets its on at
// the segment's first frame, then plays and ends like any other note.
//
// Hanging notes (DSP-003). The player remembers which notes it has started, and every one gets
// exactly one note-off:
//   - at its end, when playback reaches it;
//   - at the first frame of a segment that doesn't continue the previous one in ticks: a loop
//     wrap, a locate (reset(), TIME-008), or a tempo edit that moved the playhead's tick;
//   - at frame 0 of a stopped block (stop, or the transport was already stopped).
// Those offs come before the new segment's ons at the same frame. A re-created instance (DW-051
// edits while playing) can't know which notes the old one left on, so its first non-empty block
// starts with All Notes Off (CC 123) on all 16 channels.
//
// Capacity: midiOut is fixed storage (NodeIO.h) that may drop events. A note-on is written only
// if the writer keeps room for its own off and the off of every note still on, so offs are never
// dropped as long as the writer's capacity doesn't shrink between blocks. Dropped ons are notes
// that don't sound, never notes that hang. In a RenderGraph (T-045) the writer has
// GraphBuilder::kMidiCapacity in every graph while the player has an outgoing MIDI edge, so a
// snapshot swap never shrinks it.

#include <atomic>
#include <cstdint>
#include <memory>
#include <span>
#include <vector>

#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/Realtime.h"
#include "core/SpscQueue.h"
#include "daw/GraphDescription.h"
#include "graph/NodeRegistry.h"
#include "time/TempoMap.h"
#include "time/TransportBlock.h"

namespace daw {

class MidiInputRouter;  // REC-011 (T-053), record/MidiInputRouter.h

// UI-021 (T-043): notes the UI auditions on a MIDI track (EngineFacade::previewNote). The facade
// posts them here; the track's MidiClipPlayer merges them into its MIDI output at frame 0 of its
// next block, so they reach the track's instrument (sampler or plugin) on the same path as the
// track's own notes, whether the transport plays or not.
//
// Threads: post/releaseAll are non-RT and need one caller at a time (the facade's lock); find/
// pop/held are RT and called by players on the render thread. Each player has a mailbox, an SPSC
// queue keyed by the player's NodeID, so players never compete for events. The first post for a
// player claims a mailbox; a mailbox is handed to another player only once it is empty and holds
// no note, and a player drops events that don't carry its NodeID (the one block in which it may
// still read a mailbox that was just handed on). No allocation after construction.
//
// Hanging notes. The inbox tracks which pitches each player has on (the facade's view): a
// note-on for a held pitch is sent as off + on (a retrigger), an off for a pitch that isn't held
// is dropped, and releaseAll (stop, locate, export) posts an off for every held note. A
// re-created player (any note edit, DW-051) begins with All Notes Off, which silences held
// previews downstream; it turns the held ones back on right after from `held`, so a preview
// lasts until its own off.
// One preview note-on or note-off, as queued (outside the class so SpscQueue sees a complete type).
struct MidiPreviewEvent {
    NodeID player = 0;
    uint8_t pitch = 0;
    uint8_t velocity = 0;
    bool on = false;
};

class MidiPreviewInbox {
public:
    static constexpr uint32_t kMailboxes = 32;
    static constexpr std::size_t kQueueSize = 256;
    static constexpr uint8_t kChannel = 0;  // previews play on MIDI channel 1

    using Event = MidiPreviewEvent;

    MidiPreviewInbox();
    MidiPreviewInbox(const MidiPreviewInbox&) = delete;
    MidiPreviewInbox& operator=(const MidiPreviewInbox&) = delete;

    // Non-RT. Queues a note-on (velocity clamped to 1..127) or note-off for `player`. False if it
    // couldn't: player 0, pitch > 127, no mailbox free, or the mailbox's queue is full.
    bool post(NodeID player, uint8_t pitch, uint8_t velocity, bool on);
    // Non-RT. A note-off for every held note of every player.
    void releaseAll();
    // Non-RT diagnostics: how many pitches `player` has on.
    uint32_t heldCount(NodeID player) const;

    // RT. The mailbox of `player`, or -1; `hint` (the last index found) is checked first.
    int find(NodeID player, int hint) const DAW_RT;
    // RT. The next event of mailbox `index` (from find).
    bool pop(int index, Event& out) DAW_RT;
    // RT. Whether mailbox `index` holds `pitch` on, and with which velocity.
    bool held(int index, uint8_t pitch, uint8_t& velocity) const DAW_RT;

private:
    struct Mailbox {
        std::atomic<NodeID> owner{0};  // 0: free
        SpscQueue<Event, kQueueSize> queue;
        std::atomic<uint64_t> held[2]{};
        std::atomic<uint8_t> velocity[128]{};
        uint64_t lastUse = 0;  // producer only
    };
    Mailbox* mailboxFor(NodeID player);  // non-RT: finds or claims one
    bool push(Mailbox& box, NodeID player, uint8_t pitch, uint8_t velocity, bool on);

    std::unique_ptr<Mailbox[]> boxes_;
    uint64_t clock_ = 0;
};

class MidiClipPlayer final : public Node {
public:
    static constexpr uint8_t kNoteOn = 0x90;
    static constexpr uint8_t kNoteOff = 0x80;
    static constexpr uint8_t kControlChange = 0xB0;
    static constexpr uint8_t kAllNotesOff = 123;
    static constexpr uint8_t kReleaseVelocity = 64;  // MIDI 1.0 default for note-off velocity
    static constexpr uint8_t kNumChannels = 16;

    struct Note {
        Tick start = 0;
        Tick end = 0;  // start + length
        uint8_t pitch = 0, velocity = 0, channel = 0;
    };

    // Non-RT. The registry entry for NodeKind::midiClipPlayer (registerBuiltinNodes): no audio
    // output, notes from NodeCreateInfo::notes. UI-021: with `preview`, each player also plays
    // the preview notes posted for its NodeID (the facade registers it that way, T-043).
    // REC-011 (T-053): with `live`, a player whose track is armed also plays the router's live
    // MIDI input.
    static NodeKindInfo kindInfo(MidiPreviewInbox* preview = nullptr, MidiInputRouter* live = nullptr);

    // Non-RT. Takes the notes in any order and drops invalid ones (see above).
    static std::unique_ptr<MidiClipPlayer> create(std::span<const NoteDesc> notes,
                                                  MidiPreviewInbox* preview = nullptr, NodeID id = 0,
                                                  MidiInputRouter* live = nullptr);
    explicit MidiClipPlayer(std::vector<Note> notes, MidiPreviewInbox* preview = nullptr, NodeID id = 0,
                            MidiInputRouter* live = nullptr);

    void prepare(const PrepareInfo& info) override;
    void reset() DAW_RT override;
    void process(ProcessContext& ctx, NodeIO& io) DAW_RT override;

    // Non-RT diagnostics and tests.
    std::span<const Note> notes() const { return notes_; }

private:
    void playSegment(const TransportBlock& block, const TransportSegment& seg,
                     MidiEventWriter& out) DAW_RT;
    // Note-off for every note still on, at `frame`.
    void releaseAll(MidiEventWriter& out, uint32_t frame) DAW_RT;
    // Records note `index` as on, keeping active_ sorted by end tick, latest first.
    void activate(uint32_t index) DAW_RT;
    // Index of the first note starting at or after `tick`.
    size_t firstStartingAtOrAfter(Tick tick) const DAW_RT;
    // DW-103: note-ons at the segment's first frame for the notes it starts inside of.
    void chase(const TransportBlock& block, const TransportSegment& seg, MidiEventWriter& out) DAW_RT;
    // A note-on is written only if room stays for its own off and every held note's (preview
    // notes included, UI-021).
    bool roomForOn(const MidiEventWriter& out) const DAW_RT {
        return out.capacity() - out.size() >= reserved() + 2;
    }
    // Writer slots held back for what must still be ended: notes on (clip, preview and live),
    // live pedals down and live bends off centre.
    uint32_t reserved() const DAW_RT;
    // UI-021: the inbox's events for this player, at frame 0 (and, for a new instance, its held
    // notes again after the All Notes Off).
    void playPreview(MidiEventWriter& out, bool resync) DAW_RT;
    // REC-011 (T-053). beginLive: this block's live span (empty unless the track is armed), the
    // releases of a track just disarmed, and a new instance's held notes again. flushLive: the
    // live events up to `frame` into the writer, so its output stays in frame order.
    void beginLive(MidiEventWriter& out) DAW_RT;
    void flushLive(MidiEventWriter& out, uint32_t frame) DAW_RT;
    void playLive(MidiEventWriter& out, const MidiEvent& event) DAW_RT;
    void releaseLive(MidiEventWriter& out) DAW_RT;
    bool liveOn(uint8_t channel, uint8_t pitch) const DAW_RT {
        return (liveOn_[channel][pitch >> 6] >> (pitch & 63)) & 1;
    }
    void setLiveOn(uint8_t channel, uint8_t pitch, bool on) DAW_RT;

    std::vector<Note> notes_;  // sorted by start
    std::vector<Tick> maxEnd_; // maxEnd_[i] = max(notes_[0..i].end), non-decreasing (chase)
    // The notes that are on: active_[0, numActive_), by end tick descending, so the next to end
    // is last. Sized notes_.size() up front (a note is on at most once), so it never grows.
    std::vector<uint32_t> active_;
    uint32_t numActive_ = 0;

    // Audio thread only.
    bool havePos_ = false;     // false: the next segment is a jump
    Tick nextTick_ = 0;        // where the previous segment's ticks ended
    bool announced_ = false;   // the first non-empty block's All Notes Off went out

    // UI-021 preview notes (audio thread only, besides the pointer and ID).
    MidiPreviewInbox* preview_ = nullptr;
    NodeID id_ = 0;
    int previewBox_ = -1;          // find() hint
    uint64_t previewOn_[2] = {};   // pitches this instance turned on, channel kChannel
    uint32_t numPreviewOn_ = 0;

    // REC-011 live input (audio thread only, besides the pointer). What this instance turned on,
    // so it can end exactly that when the track is disarmed; a re-created instance sounds the
    // router's held notes again after its All Notes Off, like previews (UI-021).
    MidiInputRouter* live_ = nullptr;
    MidiEventSpan liveSpan_{};
    uint32_t liveCursor_ = 0;
    bool liveNew_ = true;            // the first real block of this instance is still to come
    uint64_t liveOn_[16][2] = {};
    uint32_t numLiveOn_ = 0;
    uint16_t livePedal_ = 0;         // channels this instance has the pedal down on
    uint16_t liveBend_ = 0;          // channels this instance has bent off centre
};

} // namespace daw
