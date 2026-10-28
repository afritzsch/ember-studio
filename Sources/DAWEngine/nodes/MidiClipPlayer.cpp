#include "nodes/MidiClipPlayer.h"

#include <algorithm>
#include <limits>
#include <utility>

#include "core/ProcessContext.h"
#include "time/TransportSegments.h"

namespace daw {

NodeKindInfo MidiClipPlayer::kindInfo() {
    NodeKindInfo info{[](const NodeCreateInfo& create) -> Result<std::unique_ptr<Node>> {
        return std::unique_ptr<Node>(MidiClipPlayer::create(create.notes));
    }};
    info.audioOutput = false;  // MIDI only: its instrument hangs off a MIDI edge
    return info;
}

std::unique_ptr<MidiClipPlayer> MidiClipPlayer::create(std::span<const NoteDesc> descs) {
    std::vector<Note> notes;
    notes.reserve(descs.size());
    for (const NoteDesc& d : descs) {
        if (d.length <= 0 || d.pitch > 127 || d.channel >= kNumChannels) continue;
        notes.push_back(Note{d.start, d.start + d.length, d.pitch,
                             std::clamp<uint8_t>(d.velocity, 1, 127), d.channel});
    }
    return std::make_unique<MidiClipPlayer>(std::move(notes));
}

MidiClipPlayer::MidiClipPlayer(std::vector<Note> notes) : notes_(std::move(notes)) {
    std::stable_sort(notes_.begin(), notes_.end(),
                     [](const Note& a, const Note& b) { return a.start < b.start; });
    active_.resize(notes_.size());
    maxEnd_.reserve(notes_.size());
    for (const Note& n : notes_) maxEnd_.push_back(maxEnd_.empty() ? n.end : std::max(maxEnd_.back(), n.end));
}

void MidiClipPlayer::prepare(const PrepareInfo&) {
    numActive_ = 0;
    havePos_ = false;
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
            out.push(MidiEvent{frameOfTick(block, seg, offTick), 3,
                               {uint8_t(kNoteOff | n.channel), n.pitch, kReleaseVelocity}});
        } else if (onTick < seg.endTick) {
            // Keep room for this note's off and every other note's still to come.
            const Note& n = notes_[next];
            if (roomForOn(out)) {
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
    if (!announced_) {
        for (uint8_t ch = 0; ch < kNumChannels; ++ch)
            out.push(MidiEvent{0, 3, {uint8_t(kControlChange | ch), kAllNotesOff, 0}});
        announced_ = true;
    }

    const TransportBlock& block = ctx.transport;
    if (block.numSegments == 0 || block.tempo == nullptr) {
        // Stopped: end everything now; whatever plays next starts as a jump.
        releaseAll(out, 0);
        havePos_ = false;
        return;
    }
    forEachSegment(block, [&](const TransportSegment& seg) DAW_RT { playSegment(block, seg, out); });
}

} // namespace daw
