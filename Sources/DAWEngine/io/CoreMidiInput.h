#pragma once
// REC-010 (T-053): CoreMIDI input. Every source the system has is connected to one MIDI 1.0 input
// port (MIDIInputPortCreateWithProtocol) and gets a MidiInputRouter slot; each event list's
// messages go to the router with their host timestamps (REC-011: every source reaches every armed
// MIDI track, all channels).
//
// Sources come and go while running: a daw.midi thread owns the client and re-reads the source
// list on CoreMIDI's notifications (and every couple of seconds in case one is missed), connecting
// new sources and closing the slot of a gone one, whose held notes get their note-offs from the
// router. CoreMIDI being unavailable (no server) just means no inputs.
//
// Threads: construct and destroy on any non-RT thread; sources() from any thread. CoreMIDI
// delivers each source's messages on its own receive thread, the slot's single producer.

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace daw {

class MidiInputRouter;

struct MidiSourceInfo {
    int32_t uniqueID = 0;  // kMIDIPropertyUniqueID
    std::string name;
    bool connected = false;  // has a router slot
};

class CoreMidiInput {
public:
    explicit CoreMidiInput(MidiInputRouter& router);  // starts daw.midi
    ~CoreMidiInput();                                 // stops it; nothing is delivered any more
    CoreMidiInput(const CoreMidiInput&) = delete;
    CoreMidiInput& operator=(const CoreMidiInput&) = delete;

    // The sources seen at the last scan (empty until daw.midi has made its first one).
    std::vector<MidiSourceInfo> sources() const;
    // Whether a MIDI client could be created at all.
    bool available() const;

    // Tests: waits up to `timeoutMs` for the first scan to have happened.
    bool waitUntilReady(uint32_t timeoutMs) const;
    // Tests: makes daw.midi re-read the source list now (the scan runs on its thread).
    void rescan();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace daw
