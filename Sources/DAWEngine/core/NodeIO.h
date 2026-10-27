#pragma once
// ENG-003: what a node reads and writes in one process() call. Everything here is a view into
// storage the RenderGraph owns; nothing is allocated or copied to build one.

#include <cstdint>
#include <span>

#include "core/AudioBufferView.h"
#include "core/Realtime.h"

namespace daw {

// One short MIDI message, `frameOffset` frames into the block.
struct MidiEvent {
    uint32_t frameOffset;
    uint8_t size;     // 1..3 bytes used in `data`
    uint8_t data[3];
};

using MidiEventSpan = std::span<const MidiEvent>;

// Appends events to fixed storage owned by the graph. A full writer drops the event and says so;
// it never grows. A default-constructed writer has no storage and accepts nothing.
class MidiEventWriter {
public:
    MidiEventWriter() = default;
    MidiEventWriter(MidiEvent* storage, uint32_t capacity) DAW_RT
        : storage_(storage), capacity_(capacity) {}

    // Returns false (and drops `event`) when full.
    bool push(const MidiEvent& event) DAW_RT {
        if (size_ == capacity_) return false;
        storage_[size_++] = event;
        return true;
    }

    uint32_t size() const DAW_RT { return size_; }
    uint32_t capacity() const DAW_RT { return capacity_; }
    MidiEventSpan written() const DAW_RT { return MidiEventSpan(storage_, size_); }
    void clear() DAW_RT { size_ = 0; }

private:
    MidiEvent* storage_ = nullptr;
    uint32_t capacity_ = 0;
    uint32_t size_ = 0;
};

struct NodeIO {
    AudioBufferView audioIn;    // summed inputs; empty for sources
    AudioBufferView audioOut;   // the node writes every one of its numFrames frames
    MidiEventSpan midiIn;
    MidiEventWriter midiOut;
    AudioBufferView sidechain;  // empty when nothing is routed to it
};

} // namespace daw
