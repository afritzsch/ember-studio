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
// that don't sound, never notes that hang.

#include <cstdint>
#include <memory>
#include <span>
#include <vector>

#include "core/Node.h"
#include "core/NodeIO.h"
#include "core/Realtime.h"
#include "daw/GraphDescription.h"
#include "graph/NodeRegistry.h"
#include "time/TempoMap.h"
#include "time/TransportBlock.h"

namespace daw {

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
    // output, notes from NodeCreateInfo::notes.
    static NodeKindInfo kindInfo();

    // Non-RT. Takes the notes in any order and drops invalid ones (see above).
    static std::unique_ptr<MidiClipPlayer> create(std::span<const NoteDesc> notes);
    explicit MidiClipPlayer(std::vector<Note> notes);

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
    // A note-on is written only if room stays for its own off and every held note's.
    bool roomForOn(const MidiEventWriter& out) const DAW_RT { return out.capacity() - out.size() >= numActive_ + 2; }

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
};

} // namespace daw
