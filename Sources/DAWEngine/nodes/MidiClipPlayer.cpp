#include "nodes/MidiClipPlayer.h"

#include <algorithm>
#include <bit>
#include <limits>
#include <utility>

#include "core/ProcessContext.h"
#include "record/MidiInputRouter.h"
#include "time/TransportSegments.h"

namespace daw {

// MARK: MidiPreviewInbox (UI-021, T-043)

namespace {

bool testBit(const uint64_t (&bits)[2], uint8_t pitch) DAW_RT { return (bits[pitch >> 6] >> (pitch & 63)) & 1; }

} // namespace

MidiPreviewInbox::MidiPreviewInbox() : boxes_(new Mailbox[kMailboxes]) {}

MidiPreviewInbox::Mailbox* MidiPreviewInbox::mailboxFor(NodeID player) {
    Mailbox* reusable = nullptr;
    for (uint32_t i = 0; i < kMailboxes; ++i) {
        Mailbox& box = boxes_[i];
        const NodeID owner = box.owner.load(std::memory_order_relaxed);  // only post() writes it
        if (owner == player) return &box;
        // Free, or empty with nothing held: the least recently used of those is handed on.
        const bool idle = owner == 0 || (box.queue.emptyApprox() &&
                                         box.held[0].load(std::memory_order_relaxed) == 0 &&
                                         box.held[1].load(std::memory_order_relaxed) == 0);
        if (idle && (!reusable || box.lastUse < reusable->lastUse)) reusable = &box;
    }
    if (reusable) reusable->owner.store(player, std::memory_order_release);
    return reusable;
}

bool MidiPreviewInbox::push(Mailbox& box, NodeID player, uint8_t pitch, uint8_t velocity, bool on) {
    if (!box.queue.push(Event{player, pitch, velocity, on})) return false;
    std::atomic<uint64_t>& word = box.held[pitch >> 6];
    const uint64_t bit = uint64_t(1) << (pitch & 63);
    if (on) {
        box.velocity[pitch].store(velocity, std::memory_order_relaxed);
        word.fetch_or(bit, std::memory_order_release);
    } else {
        word.fetch_and(~bit, std::memory_order_release);
    }
    return true;
}

bool MidiPreviewInbox::post(NodeID player, uint8_t pitch, uint8_t velocity, bool on) {
    if (player == 0 || pitch > 127) return false;
    Mailbox* box = mailboxFor(player);
    if (!box) return false;
    box->lastUse = ++clock_;
    const bool isHeld = (box->held[pitch >> 6].load(std::memory_order_relaxed) >> (pitch & 63)) & 1;
    if (!on) return !isHeld || push(*box, player, pitch, 0, false);
    // A second on for a held pitch retriggers it: off, then on.
    if (isHeld && !push(*box, player, pitch, 0, false)) return false;
    return push(*box, player, pitch, std::clamp<uint8_t>(velocity, 1, 127), true);
}

void MidiPreviewInbox::releaseAll() {
    for (uint32_t i = 0; i < kMailboxes; ++i) {
        Mailbox& box = boxes_[i];
        const NodeID owner = box.owner.load(std::memory_order_relaxed);
        for (unsigned pitch = 0; owner != 0 && pitch < 128; ++pitch)
            if ((box.held[pitch >> 6].load(std::memory_order_relaxed) >> (pitch & 63)) & 1)
                (void)push(box, owner, static_cast<uint8_t>(pitch), 0, false);
    }
}

uint32_t MidiPreviewInbox::heldCount(NodeID player) const {
    for (uint32_t i = 0; i < kMailboxes; ++i) {
        const Mailbox& box = boxes_[i];
        if (player == 0 || box.owner.load(std::memory_order_relaxed) != player) continue;
        return static_cast<uint32_t>(std::popcount(box.held[0].load(std::memory_order_relaxed)) +
                                     std::popcount(box.held[1].load(std::memory_order_relaxed)));
    }
    return 0;
}

int MidiPreviewInbox::find(NodeID player, int hint) const DAW_RT {
    if (hint >= 0 && hint < int(kMailboxes) && boxes_[hint].owner.load(std::memory_order_acquire) == player)
        return hint;
    for (uint32_t i = 0; i < kMailboxes; ++i)  // bounded (CONV-RT-04)
        if (boxes_[i].owner.load(std::memory_order_acquire) == player) return int(i);
    return -1;
}

bool MidiPreviewInbox::pop(int index, Event& out) DAW_RT { return boxes_[index].queue.pop(out); }

bool MidiPreviewInbox::held(int index, uint8_t pitch, uint8_t& velocity) const DAW_RT {
    const Mailbox& box = boxes_[index];
    if (!((box.held[pitch >> 6].load(std::memory_order_acquire) >> (pitch & 63)) & 1)) return false;
    velocity = box.velocity[pitch].load(std::memory_order_relaxed);
    return true;
}

// MARK: MidiClipPlayer

NodeKindInfo MidiClipPlayer::kindInfo(MidiPreviewInbox* preview, MidiInputRouter* live) {
    NodeKindInfo info{[preview, live](const NodeCreateInfo& create) -> Result<std::unique_ptr<Node>> {
        return std::unique_ptr<Node>(MidiClipPlayer::create(create.notes, preview, create.desc.id, live));
    }};
    info.audioOutput = false;  // MIDI only: its instrument hangs off a MIDI edge
    return info;
}

std::unique_ptr<MidiClipPlayer> MidiClipPlayer::create(std::span<const NoteDesc> descs, MidiPreviewInbox* preview,
                                                       NodeID id, MidiInputRouter* live) {
    std::vector<Note> notes;
    notes.reserve(descs.size());
    for (const NoteDesc& d : descs) {
        if (d.length <= 0 || d.pitch > 127 || d.channel >= kNumChannels) continue;
        notes.push_back(Note{d.start, d.start + d.length, d.pitch,
                             std::clamp<uint8_t>(d.velocity, 1, 127), d.channel});
    }
    return std::make_unique<MidiClipPlayer>(std::move(notes), preview, id, live);
}

MidiClipPlayer::MidiClipPlayer(std::vector<Note> notes, MidiPreviewInbox* preview, NodeID id, MidiInputRouter* live)
    : notes_(std::move(notes)), preview_(preview), id_(id), live_(live) {
    std::stable_sort(notes_.begin(), notes_.end(),
                     [](const Note& a, const Note& b) { return a.start < b.start; });
    active_.resize(notes_.size());
    maxEnd_.reserve(notes_.size());
    for (const Note& n : notes_) maxEnd_.push_back(maxEnd_.empty() ? n.end : std::max(maxEnd_.back(), n.end));
}

void MidiClipPlayer::prepare(const PrepareInfo&) {
    numActive_ = 0;
    havePos_ = false;
    previewOn_[0] = previewOn_[1] = 0;
    numPreviewOn_ = 0;
    for (auto& channel : liveOn_) channel[0] = channel[1] = 0;
    numLiveOn_ = 0;
    livePedal_ = liveBend_ = 0;
}

uint32_t MidiClipPlayer::reserved() const DAW_RT {
    return numActive_ + numPreviewOn_ + numLiveOn_ + static_cast<uint32_t>(std::popcount(livePedal_)) +
           static_cast<uint32_t>(std::popcount(liveBend_));
}

// MARK: REC-011 live input (T-053)

void MidiClipPlayer::setLiveOn(uint8_t channel, uint8_t pitch, bool on) DAW_RT {
    uint64_t& word = liveOn_[channel][pitch >> 6];
    const uint64_t bit = uint64_t(1) << (pitch & 63);
    if (on) {
        word |= bit;
        ++numLiveOn_;
    } else {
        word &= ~bit;
        --numLiveOn_;
    }
}

void MidiClipPlayer::releaseLive(MidiEventWriter& out) DAW_RT {
    for (uint8_t channel = 0; channel < kNumChannels; ++channel) {
        const uint8_t status = uint8_t(kNoteOff | channel);
        for (uint8_t w = 0; w < 2; ++w) {
            uint64_t bits = liveOn_[channel][w];
            while (bits != 0) {  // bounded: 64 bits per word
                const auto pitch = static_cast<uint8_t>(w * 64 + std::countr_zero(bits));
                bits &= bits - 1;
                out.push(MidiEvent{0, 3, {status, pitch, kReleaseVelocity}});
            }
            liveOn_[channel][w] = 0;
        }
        const auto bit = static_cast<uint16_t>(1u << channel);
        if (livePedal_ & bit) out.push(MidiEvent{0, 3, {uint8_t(kControlChange | channel), 64, 0}});
        if (liveBend_ & bit) out.push(MidiEvent{0, 3, {uint8_t(0xE0 | channel), 0, 64}});
    }
    numLiveOn_ = 0;
    livePedal_ = liveBend_ = 0;
}

void MidiClipPlayer::beginLive(MidiEventWriter& out) DAW_RT {
    liveSpan_ = {};
    liveCursor_ = 0;
    if (live_ == nullptr || !live_->blockActive()) return;  // pre-roll, or no input at all

    const bool isNew = liveNew_;
    liveNew_ = false;
    if (!live_->isArmed(id_)) {
        // Nothing may hang when the track is disarmed (T-053 notes).
        if (reserved() != numActive_ + numPreviewOn_) releaseLive(out);
        return;
    }
    if (isNew) {
        // After this instance's All Notes Off: the notes still held sound again. The bounded scan
        // runs once per instance (CONV-RT-04); pedal and bend survive in the instrument.
        for (uint8_t channel = 0; channel < kNumChannels; ++channel) {
            for (uint8_t pitch = 0; pitch < 128; ++pitch) {
                uint8_t velocity = 0;
                if (!live_->heldNote(channel, pitch, velocity) || !roomForOn(out)) continue;
                if (out.push(MidiEvent{0, 3, {uint8_t(kNoteOn | channel), pitch, velocity}}))
                    setLiveOn(channel, pitch, true);
            }
        }
        livePedal_ = live_->pedalMask();
        liveBend_ = live_->bendMask();
    }
    liveSpan_ = live_->events();
}

void MidiClipPlayer::playLive(MidiEventWriter& out, const MidiEvent& e) DAW_RT {
    const uint8_t kind = e.data[0] & 0xF0, channel = e.data[0] & 0x0F;
    if (kind == kNoteOn && e.data[2] > 0) {
        if (liveOn(channel, e.data[1]) || !roomForOn(out)) return;  // dropped, never hanging
        if (out.push(e)) setLiveOn(channel, e.data[1], true);
        return;
    }
    if (kind == kNoteOff || kind == kNoteOn) {
        if (!liveOn(channel, e.data[1])) return;
        out.push(e);
        setLiveOn(channel, e.data[1], false);
        return;
    }
    const auto bit = static_cast<uint16_t>(1u << channel);
    const bool isPedal = kind == kControlChange && e.data[1] == 64;
    const bool isBend = kind == 0xE0;
    // An event that starts something that must be ended later keeps room for that too.
    const uint32_t need = (isPedal && e.data[2] >= 64) || (isBend && !(e.data[1] == 0 && e.data[2] == 64)) ? 2 : 1;
    if (out.capacity() - out.size() < reserved() + need) {
        // Ending is always allowed: the room was reserved when it started.
        const bool ends = (isPedal && e.data[2] < 64 && (livePedal_ & bit)) ||
                          (isBend && e.data[1] == 0 && e.data[2] == 64 && (liveBend_ & bit));
        if (!ends) return;
    }
    if (!out.push(e)) return;
    if (isPedal) {
        if (e.data[2] >= 64) livePedal_ |= bit;
        else livePedal_ &= static_cast<uint16_t>(~bit);
    } else if (isBend) {
        if (e.data[1] == 0 && e.data[2] == 64) liveBend_ &= static_cast<uint16_t>(~bit);
        else liveBend_ |= bit;
    }
}

void MidiClipPlayer::flushLive(MidiEventWriter& out, uint32_t frame) DAW_RT {
    for (; liveCursor_ < liveSpan_.size(); ++liveCursor_) {  // bounded by the span
        const MidiEvent& e = liveSpan_[liveCursor_];
        if (e.frameOffset > frame) return;
        playLive(out, e);
    }
}

void MidiClipPlayer::playPreview(MidiEventWriter& out, bool resync) DAW_RT {
    constexpr uint8_t ch = MidiPreviewInbox::kChannel;
    previewBox_ = preview_->find(id_, previewBox_);
    if (previewBox_ < 0) return;
    auto noteOn = [&](uint8_t pitch, uint8_t velocity) DAW_RT {
        if (testBit(previewOn_, pitch) || !roomForOn(out)) return;  // dropped, never hanging
        if (!out.push(MidiEvent{0, 3, {uint8_t(kNoteOn | ch), pitch, velocity}})) return;
        previewOn_[pitch >> 6] |= uint64_t(1) << (pitch & 63);
        ++numPreviewOn_;
    };
    if (resync) {
        // After this instance's All Notes Off: the previews still held sound again.
        for (unsigned pitch = 0; pitch < 128; ++pitch) {
            uint8_t velocity = 0;
            if (preview_->held(previewBox_, uint8_t(pitch), velocity)) noteOn(uint8_t(pitch), velocity);
        }
    }
    // Bounded by the queue size (CONV-RT-04); offs always fit (roomForOn keeps room for them).
    MidiPreviewInbox::Event e;
    for (std::size_t n = 0; n < MidiPreviewInbox::kQueueSize && preview_->pop(previewBox_, e); ++n) {
        if (e.player != id_ || e.pitch > 127) continue;  // a mailbox just handed to another player
        if (e.on) {
            noteOn(e.pitch, e.velocity);
        } else if (testBit(previewOn_, e.pitch)) {
            out.push(MidiEvent{0, 3, {uint8_t(kNoteOff | ch), e.pitch, kReleaseVelocity}});
            previewOn_[e.pitch >> 6] &= ~(uint64_t(1) << (e.pitch & 63));
            --numPreviewOn_;
        }
    }
}

void MidiClipPlayer::reset() DAW_RT {
    // TIME-008: a locate while playing. reset() has no output to write to, so the notes still on
    // are released at the start of the next block, whose first segment is now a jump.
    havePos_ = false;
}

size_t MidiClipPlayer::firstStartingAtOrAfter(Tick tick) const DAW_RT {
    size_t lo = 0, hi = notes_.size();
    while (lo < hi) {  // O(log notes)
        const size_t mid = lo + (hi - lo) / 2;
        if (notes_[mid].start < tick) lo = mid + 1;
        else hi = mid;
    }
    return lo;
}

void MidiClipPlayer::chase(const TransportBlock& block, const TransportSegment& seg,
                           MidiEventWriter& out) DAW_RT {
    // DW-103: the notes that started before the segment and still sound at its first sample.
    // Ticks before startTick sound before startSample (TransportSegments.h), so start <
    // startTick puts the on in the past; the off must not be. maxEnd_ skips the prefix of notes
    // that all ended earlier; the scan is bounded by the note count (CONV-RT-04).
    const size_t stop = firstStartingAtOrAfter(seg.startTick);
    size_t lo = 0, hi = stop;
    while (lo < hi) {  // first i with maxEnd_[i] > startTick − 1, i.e. could still sound
        const size_t mid = lo + (hi - lo) / 2;
        if (maxEnd_[mid] < seg.startTick) lo = mid + 1;
        else hi = mid;
    }
    for (size_t i = lo; i < stop; ++i) {
        const Note& n = notes_[i];
        if (n.end < seg.startTick || block.tempo->tickToSample(n.end) <= seg.startSample) continue;
        if (!roomForOn(out)) continue;  // dropped, never hanging
        flushLive(out, seg.frameOffset);  // REC-011: frame order
        out.push(MidiEvent{seg.frameOffset, 3, {uint8_t(kNoteOn | n.channel), n.pitch, n.velocity}});
        activate(static_cast<uint32_t>(i));
    }
}

void MidiClipPlayer::activate(uint32_t index) DAW_RT {
    if (numActive_ == active_.size()) return;  // can't happen: a note is on at most once
    const Tick end = notes_[index].end;
    uint32_t i = numActive_++;
    for (; i > 0 && notes_[active_[i - 1]].end < end; --i) active_[i] = active_[i - 1];
    active_[i] = index;
}

void MidiClipPlayer::releaseAll(MidiEventWriter& out, uint32_t frame) DAW_RT {
    flushLive(out, frame);  // REC-011: frame order
    for (uint32_t i = numActive_; i > 0; --i) {
        const Note& n = notes_[active_[i - 1]];
        out.push(MidiEvent{frame, 3, {uint8_t(kNoteOff | n.channel), n.pitch, kReleaseVelocity}});
    }
    numActive_ = 0;
}

void MidiClipPlayer::playSegment(const TransportBlock& block, const TransportSegment& seg,
                                 MidiEventWriter& out) DAW_RT {
    // Hanging notes (DSP-003): a segment that doesn't continue the previous one's ticks (wrap,
    // locate, tempo edit under the playhead) first ends every note the old pass left on.
    if (!havePos_ || seg.afterWrap || seg.startTick != nextTick_) {
        releaseAll(out, seg.frameOffset);
        chase(block, seg, out);  // DW-103
    }
    havePos_ = true;
    nextTick_ = seg.endTick;

    // Merge the notes ending in [startTick, endTick) (active_, earliest end last) with the notes
    // starting there (notes_, by start), in tick order, offs first on a tie. Each step consumes
    // one off or one start, so the loop is bounded by the note count (CONV-RT-04).
    constexpr Tick kNever = std::numeric_limits<Tick>::max();
    size_t next = firstStartingAtOrAfter(seg.startTick);
    for (;;) {
        const Tick offTick = numActive_ > 0 ? notes_[active_[numActive_ - 1]].end : kNever;
        const Tick onTick = next < notes_.size() ? notes_[next].start : kNever;
        if (offTick < seg.endTick && offTick <= onTick) {
            const Note& n = notes_[active_[--numActive_]];
            flushLive(out, frameOfTick(block, seg, offTick));  // REC-011: frame order
            out.push(MidiEvent{frameOfTick(block, seg, offTick), 3,
                               {uint8_t(kNoteOff | n.channel), n.pitch, kReleaseVelocity}});
        } else if (onTick < seg.endTick) {
            // Keep room for this note's off and every other note's still to come.
            const Note& n = notes_[next];
            if (roomForOn(out)) {
                flushLive(out, frameOfTick(block, seg, onTick));  // REC-011: frame order
                out.push(MidiEvent{frameOfTick(block, seg, onTick), 3,
                                   {uint8_t(kNoteOn | n.channel), n.pitch, n.velocity}});
                activate(static_cast<uint32_t>(next));
            }
            ++next;
        } else {
            break;
        }
    }
}

void MidiClipPlayer::process(ProcessContext& ctx, NodeIO& io) DAW_RT {
    MidiEventWriter& out = io.midiOut;
    if (ctx.numFrames == 0) return;  // no frame to put an event on

    // A new instance (DW-051) replaces one whose notes may still be on downstream.
    const bool resync = !announced_;
    if (!announced_) {
        for (uint8_t ch = 0; ch < kNumChannels; ++ch)
            out.push(MidiEvent{0, 3, {uint8_t(kControlChange | ch), kAllNotesOff, 0}});
        announced_ = true;
    }
    if (preview_) playPreview(out, resync);  // UI-021, at frame 0 whether the transport plays or not
    beginLive(out);  // REC-011, whether the transport plays or not

    const TransportBlock& block = ctx.transport;
    if (block.numSegments == 0 || block.tempo == nullptr) {
        // Stopped: end everything now; whatever plays next starts as a jump.
        releaseAll(out, 0);
        havePos_ = false;
        flushLive(out, std::numeric_limits<uint32_t>::max());
        return;
    }
    forEachSegment(block, [&](const TransportSegment& seg) DAW_RT { playSegment(block, seg, out); });
    flushLive(out, std::numeric_limits<uint32_t>::max());  // REC-011: what's after the last clip event
}

} // namespace daw
