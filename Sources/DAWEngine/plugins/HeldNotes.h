#pragma once
// DW-225 (T-097): which notes a hosted plugin is holding, so a bypass toggle can release them
// before the plugin stops receiving MIDI (BypassNode stops processing it). Fixed size, audio
// thread only: a count per channel and key (a key struck twice needs two note-offs to end, as in
// most synths, so the host sends as many as it saw note-ons).

#include <cstdint>
#include <cstring>

#include "core/NodeIO.h"
#include "core/Realtime.h"

namespace daw {

class HeldNotes {
public:
    static constexpr uint32_t kChannels = 16, kKeys = 128;
    // CC 123 (All Notes Off), sent on each channel that had notes after its note-offs.
    static constexpr uint8_t kAllNotesOff = 123;

    // RT. Follows a MIDI message the plugin was given (note on, note off, velocity-0 note on).
    void track(const MidiEvent& e) DAW_RT {
        if (e.size < 3) return;
        const uint8_t status = e.data[0] & 0xF0, channel = e.data[0] & 0x0F, key = e.data[1] & 0x7F;
        uint8_t& count = counts_[channel][key];
        if (status == 0x90 && (e.data[2] & 0x7F) > 0) {
            if (count < 255) ++count;
            channels_ |= static_cast<uint16_t>(1u << channel);
        } else if ((status == 0x80 || status == 0x90) && count > 0) {
            --count;
        }
    }

    bool any() const DAW_RT { return channels_ != 0; }
    // Channels that had a note since the last release() (a bit per channel).
    uint16_t channels() const DAW_RT { return channels_; }

    // RT. Calls noteOff(channel, key) once per held note-on, then allNotesOff(channel) for each
    // channel that had notes, and forgets them all. CONV-RT-04: bounded by 16 × 128 × 255.
    template <class NoteOff, class AllOff>
    void release(NoteOff&& noteOff, AllOff&& allNotesOff) DAW_RT {
        if (channels_ == 0) return;
        for (uint32_t c = 0; c < kChannels; ++c) {
            if ((channels_ & (1u << c)) == 0) continue;
            for (uint32_t k = 0; k < kKeys; ++k)
                for (uint8_t n = counts_[c][k]; n > 0; --n) noteOff(static_cast<uint8_t>(c), static_cast<uint8_t>(k));
            allNotesOff(static_cast<uint8_t>(c));
        }
        clear();
    }

    void clear() DAW_RT {
        std::memset(counts_, 0, sizeof(counts_));
        channels_ = 0;
    }

private:
    uint8_t counts_[kChannels][kKeys] = {};
    uint16_t channels_ = 0;
};

} // namespace daw
