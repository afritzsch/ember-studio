// REC-010..012 (T-053): see MidiInputRouter.h.

#include "record/MidiInputRouter.h"

#include <mach/mach_time.h>

#include <algorithm>
#include <array>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstring>
#include <deque>
#include <limits>
#include <thread>

#include "core/Telemetry.h"
#include "time/TempoMap.h"
#include "time/Transport.h"
#include "time/TransportBlock.h"

namespace daw {

namespace {

constexpr uint8_t kNoteOff = 0x80, kNoteOn = 0x90, kControlChange = 0xB0, kPitchBend = 0xE0;
constexpr uint8_t kSustain = 64, kAllSoundOff = 120, kAllNotesOff = 123;
constexpr int kAnchorRetries = 8;

// Three-byte channel messages, except program change and channel pressure.
uint8_t messageSize(uint8_t status) { return (status & 0xF0) == 0xC0 || (status & 0xF0) == 0xD0 ? 2 : 3; }

} // namespace

MidiInputRouter::MidiInputRouter()
    : inputs_(new Input[kNumSlots]), lanes_(new Lane[kMaxArmed]), recordBuffer_(new RecEvent[kMaxRecordEvents]) {
    mach_timebase_info_data_t timebase{};
    mach_timebase_info(&timebase);
    hostTicksPerSecond_ = timebase.numer != 0 ? 1e9 * double(timebase.denom) / double(timebase.numer) : 1e9;
    inputs_[kInjectedSlot].state.store(kOpen, std::memory_order_release);
    for (uint32_t i = 0; i < kMaxArmed; ++i) armedSlots_[i].filter.store(packFilter({}), std::memory_order_relaxed);
}

// MARK: Producers

int MidiInputRouter::openInput() {
    for (uint32_t i = 0; i < kMaxInputs; ++i) {
        uint8_t expected = kFree;
        if (inputs_[i].state.compare_exchange_strong(expected, kOpen, std::memory_order_acq_rel)) {
            inputs_[i].hasSource.store(false, std::memory_order_release);
            return int(i);
        }
    }
    return -1;
}

int MidiInputRouter::openInput(int32_t source) {
    // The source is set before the slot opens, so the audio thread never sees an open slot with
    // the ID of the input that had it before.
    for (uint32_t i = 0; i < kMaxInputs; ++i) {
        Input& input = inputs_[i];
        if (input.state.load(std::memory_order_acquire) != kFree) continue;
        input.source.store(source, std::memory_order_relaxed);
        input.hasSource.store(true, std::memory_order_relaxed);
        uint8_t expected = kFree;
        if (input.state.compare_exchange_strong(expected, kOpen, std::memory_order_acq_rel)) return int(i);
    }
    return -1;
}

void MidiInputRouter::closeInput(int slot) {
    if (slot < 0 || slot >= int(kMaxInputs)) return;
    uint8_t expected = kOpen;
    (void)inputs_[slot].state.compare_exchange_strong(expected, kClosing, std::memory_order_acq_rel);
}

bool MidiInputRouter::readAnchor(Anchor& out) const {
    for (int i = 0; i < kAnchorRetries; ++i) {
        const uint64_t before = anchorSeq_.load(std::memory_order_acquire);
        if (before & 1) continue;
        out.hostTicks = anchorHost_.load(std::memory_order_relaxed);
        out.hostSample = anchorHostSample_.load(std::memory_order_relaxed);
        out.renderSample = anchorRenderSample_.load(std::memory_order_relaxed);
        out.transportSample = anchorTransport_.load(std::memory_order_relaxed);
        out.sampleRate = anchorRate_.load(std::memory_order_relaxed);
        out.playing = anchorPlaying_.load(std::memory_order_relaxed);
        out.valid = anchorValid_.load(std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_acquire);
        if (anchorSeq_.load(std::memory_order_relaxed) == before) return true;
    }
    return false;
}

void MidiInputRouter::publishAnchor(const Anchor& a) DAW_RT {
    const uint64_t seq = anchorSeq_.load(std::memory_order_relaxed);
    anchorSeq_.store(seq + 1, std::memory_order_relaxed);
    std::atomic_thread_fence(std::memory_order_release);
    anchorHost_.store(a.hostTicks, std::memory_order_relaxed);
    anchorHostSample_.store(a.hostSample, std::memory_order_relaxed);
    anchorRenderSample_.store(a.renderSample, std::memory_order_relaxed);
    anchorTransport_.store(a.transportSample, std::memory_order_relaxed);
    anchorRate_.store(a.sampleRate, std::memory_order_relaxed);
    anchorPlaying_.store(a.playing, std::memory_order_relaxed);
    anchorValid_.store(a.valid, std::memory_order_relaxed);
    anchorSeq_.store(seq + 2, std::memory_order_release);
}

int64_t MidiInputRouter::sampleTimeOf(uint64_t hostTime, const Anchor& a) const {
    if (!a.valid || a.sampleRate <= 0) return a.renderSample;
    const double seconds = (double(hostTime) - double(a.hostTicks)) / hostTicksPerSecond_;
    return a.hostSample + static_cast<int64_t>(std::llround(seconds * a.sampleRate));
}

int64_t MidiInputRouter::sampleTimeOfHost(uint64_t hostTime) const {
    Anchor anchor;
    (void)readAnchor(anchor);
    return sampleTimeOf(hostTime, anchor);
}

bool MidiInputRouter::pushEvent(uint32_t slot, const MidiInEvent& event) {
    Input& input = inputs_[slot];
    if (input.queue.push(event)) return true;
    dropped_.fetch_add(1, std::memory_order_relaxed);
    // A dropped note-off must not leave a note on: the audio thread ends the input's notes.
    input.overflowed.store(true, std::memory_order_release);
    return false;
}

bool MidiInputRouter::receive(int slot, uint64_t hostTime, const uint8_t* bytes, uint8_t size) {
    if (slot < 0 || slot >= int(kMaxInputs) || size == 0 || size > 3 || !(bytes[0] & 0x80) || (bytes[0] & 0xF0) == 0xF0)
        return false;
    if (inputs_[slot].state.load(std::memory_order_acquire) != kOpen) return false;
    Anchor anchor;
    (void)readAnchor(anchor);
    const uint64_t host = hostTime != 0 ? hostTime : mach_absolute_time();
    MidiInEvent event;
    event.sampleTime = sampleTimeOf(host, anchor);  // REC-010
    event.hostTime = host;
    event.size = size;
    for (uint8_t i = 0; i < size; ++i) event.data[i] = bytes[i];
    return pushEvent(uint32_t(slot), event);
}

bool MidiInputRouter::inject(int64_t atSample, bool relativeToNow, const uint8_t* bytes, uint8_t size) {
    if (size == 0 || size > 3 || !(bytes[0] & 0x80) || (bytes[0] & 0xF0) == 0xF0) return false;
    Anchor anchor;
    (void)readAnchor(anchor);
    MidiInEvent event;
    // The render-clock sample the transport will be at `atSample`; earlier than the block about
    // to render means now (frame 0).
    int64_t offset = 0;
    if (relativeToNow) offset = atSample;
    else if (anchor.playing) offset = atSample - anchor.transportSample;
    event.sampleTime = anchor.renderSample + offset;
    event.hostTime = 0;
    event.size = size;
    for (uint8_t i = 0; i < size; ++i) event.data[i] = bytes[i];
    return pushEvent(kInjectedSlot, event);
}

uint32_t MidiInputRouter::bindInjected(int32_t source) {
    if (auto it = injectedSources_.find(source); it != injectedSources_.end()) return it->second;
    if (injectedSources_.size() >= kMaxInjectedSources) return kNumSlots;
    const auto slot = static_cast<uint32_t>(kInjectedSlot + 1 + injectedSources_.size());
    Input& input = inputs_[slot];
    input.source.store(source, std::memory_order_relaxed);
    input.hasSource.store(true, std::memory_order_relaxed);
    input.state.store(kOpen, std::memory_order_release);  // publishes the source with it
    injectedSources_[source] = slot;
    return slot;
}

bool MidiInputRouter::inject(int32_t source, int64_t atSample, bool relativeToNow, const uint8_t* bytes, uint8_t size) {
    if (size == 0 || size > 3 || !(bytes[0] & 0x80) || (bytes[0] & 0xF0) == 0xF0) return false;
    const uint32_t slot = bindInjected(source);
    if (slot >= kNumSlots) return false;
    Anchor anchor;
    (void)readAnchor(anchor);
    MidiInEvent event;
    int64_t offset = 0;
    if (relativeToNow) offset = atSample;
    else if (anchor.playing) offset = atSample - anchor.transportSample;
    event.sampleTime = anchor.renderSample + offset;
    event.hostTime = 0;
    event.size = size;
    for (uint8_t i = 0; i < size; ++i) event.data[i] = bytes[i];
    return pushEvent(slot, event);
}

// MARK: Control

// T-093: the filter in one word, so the audio thread reads it whole. Bits 0…31 the source ID,
// 32…36 the channel, 40 "all sources".
uint64_t MidiInputRouter::packFilter(const MidiInputFilter& f) {
    const uint64_t channel = f.channel <= 16 ? f.channel : 0;
    return uint64_t(static_cast<uint32_t>(f.source)) | (channel << 32) | (f.allSources ? uint64_t(1) << 40 : 0);
}

MidiInputFilter MidiInputRouter::unpackFilter(uint64_t packed) {
    MidiInputFilter f;
    f.allSources = (packed >> 40) & 1;
    f.source = static_cast<int32_t>(static_cast<uint32_t>(packed & 0xFFFFFFFFu));
    f.channel = static_cast<uint8_t>((packed >> 32) & 0x1F);
    return f;
}

void MidiInputRouter::setArmed(NodeID track, NodeID player, bool armed) {
    if (armed) {
        auto index = armedIndex_.find(track);
        if (index == armedIndex_.end()) {
            uint32_t free = kMaxArmed;
            for (uint32_t i = 0; i < kMaxArmed && free == kMaxArmed; ++i)
                if (armedSlots_[i].track.load(std::memory_order_relaxed) == 0) free = i;
            if (free == kMaxArmed) return;  // the table is full: the track doesn't hear MIDI
            index = armedIndex_.emplace(track, free).first;
        } else if (armed_[track] == player) {
            return;  // unchanged
        }
        // A new occupant or a new player: the audio thread counts its lane afresh.
        ArmedSlot& slot = armedSlots_[index->second];
        slot.filter.store(packFilter(inputFilter(track)), std::memory_order_relaxed);
        slot.player.store(player, std::memory_order_relaxed);
        slot.track.store(track, std::memory_order_relaxed);
        slot.generation.store(++nextGeneration_, std::memory_order_release);
        armed_[track] = player;
    } else if (auto existing = armed_.find(track); existing != armed_.end()) {
        if (auto it = armedIndex_.find(track); it != armedIndex_.end()) {
            ArmedSlot& slot = armedSlots_[it->second];
            slot.player.store(0, std::memory_order_relaxed);
            slot.track.store(0, std::memory_order_relaxed);
            slot.generation.store(++nextGeneration_, std::memory_order_release);
            armedIndex_.erase(it);
        }
        armed_.erase(existing);
    }
}

void MidiInputRouter::setInputFilter(NodeID track, const MidiInputFilter& filter) {
    MidiInputFilter f = filter;
    if (f.channel > 16) f.channel = 0;
    if (f.allSources) f.source = 0;
    if (f == MidiInputFilter{}) filters_.erase(track);
    else filters_[track] = f;
    // An armed track is retargeted from the next block (its generation stays, see syncLanes).
    if (auto it = armedIndex_.find(track); it != armedIndex_.end())
        armedSlots_[it->second].filter.store(packFilter(f), std::memory_order_release);
}

MidiInputFilter MidiInputRouter::inputFilter(NodeID track) const {
    auto it = filters_.find(track);
    return it == filters_.end() ? MidiInputFilter{} : it->second;
}

void MidiInputRouter::deactivate() {
    sessionActive_.store(false, std::memory_order_seq_cst);
    // Dekker with beginBlock (Recorder.h): once rtBusy_ reads false after the flag is cleared, the
    // audio thread is out of the session. Bounded by one block.
    while (rtBusy_.load(std::memory_order_seq_cst)) std::this_thread::sleep_for(std::chrono::microseconds(50));
}

std::vector<FinalizedMidiTake> MidiInputRouter::prepare(double sampleRate) {
    std::vector<NodeID> wanted;
    wanted.reserve(armed_.size());
    for (const auto& [track, player] : armed_)
        if (armedIndex_.count(track) != 0) wanted.push_back(track);

    std::vector<FinalizedMidiTake> late;
    if (sessionActive_.load(std::memory_order_seq_cst)) {
        if (recStarted_.load(std::memory_order_acquire)) return {};  // finalize first
        if (sessionTracks_ == wanted && sessionRate_ == sampleRate) return {};
        deactivate();
        late = collect();  // the audio thread may have started it just now
    }
    if (wanted.empty()) return late;

    recCount_.store(0, std::memory_order_relaxed);
    recDropped_.store(0, std::memory_order_relaxed);
    recStarted_.store(false, std::memory_order_relaxed);
    pass_ = 0;
    havePrev_ = false;
    sessionTracks_ = std::move(wanted);
    sessionSlots_.clear();
    for (const NodeID track : sessionTracks_) sessionSlots_.push_back(armedIndex_.at(track));
    sessionRate_ = sampleRate;
    sessionActive_.store(true, std::memory_order_seq_cst);
    return late;
}

bool MidiInputRouter::capturing() const {
    return sessionActive_.load(std::memory_order_seq_cst) && recStarted_.load(std::memory_order_acquire);
}

std::vector<FinalizedMidiTake> MidiInputRouter::finalize() {
    if (!sessionActive_.load(std::memory_order_seq_cst)) return {};
    deactivate();
    return collect();
}

// REC-012, with the audio thread out of the session: pairs the recorded events into notes.
std::vector<FinalizedMidiTake> MidiInputRouter::collect() {
    if (!recStarted_.exchange(false, std::memory_order_acq_rel)) return {};
    const uint32_t count = recCount_.load(std::memory_order_acquire);

    std::vector<FinalizedMidiTake> takes;
    takes.reserve(sessionTracks_.size());
    for (std::size_t t = 0; t < sessionTracks_.size(); ++t) {
        // T-093: each track gets the notes its filter passed when they were played.
        std::vector<RecordedMidiNote> notes = pairNotes(count, uint64_t(1) << sessionSlots_[t]);
        if (notes.empty()) continue;  // nothing played on this track: no clip, no undo entry
        FinalizedMidiTake take;
        take.track = sessionTracks_[t];
        take.startSample = recStartHeard_;
        take.endSample = recEndHeard_;
        take.sampleRate = sessionRate_;
        take.droppedEvents = recDropped_.load(std::memory_order_relaxed);
        take.notes = std::move(notes);
        if (recLastPass_ > 0) {  // REC-034 (T-080)
            take.passes = static_cast<uint32_t>(recLastPass_) + 1;
            take.loopStart = recLoopStart_;
            take.loopEnd = recLoopEnd_;
        }
        takes.push_back(std::move(take));
    }
    return takes;
}

std::vector<RecordedMidiNote> MidiInputRouter::pairNotes(uint32_t count, uint64_t laneBit) const {
    std::vector<RecordedMidiNote> notes;
    std::vector<int32_t> passes;  // of each note's on
    // The notes still open per channel and key, oldest first: an off ends the oldest (DSP-023).
    std::array<std::array<std::deque<size_t>, 128>, 16> open;

    // A note whose on and off are on different loop passes runs to the end of the first pass, so
    // it doesn't end before it starts (notes keep their transport ticks, one clip; with REC-034
    // takes, T-080, the note stays in the take of its start's pass).
    const auto noteEnd = [this](int64_t start, int32_t startPass, int64_t end, int32_t endPass) {
        if (endPass != startPass) end = recLoopEnd_;
        return std::max(end, start + 1);
    };

    for (uint32_t i = 0; i < count; ++i) {
        const RecEvent& e = recordBuffer_[i];
        if (!(e.lanes & laneBit)) continue;
        std::deque<size_t>& held = open[e.channel][e.pitch];
        if (e.on) {
            held.push_back(notes.size());
            notes.push_back(RecordedMidiNote{e.sample, e.sample, e.pitch, e.velocity, e.channel, e.pass});
            passes.push_back(e.pass);
        } else if (!held.empty()) {
            const size_t note = held.front();
            held.pop_front();
            notes[note].end = noteEnd(notes[note].start, passes[note], e.sample, e.pass);
        }
        // An off with no on: its note-on came before the take.
    }
    // REC-012: unpaired notes close at stop.
    for (auto& channel : open)
        for (std::deque<size_t>& held : channel)
            for (const size_t note : held)
                notes[note].end = noteEnd(notes[note].start, passes[note], recEndHeard_, recLastPass_);

    std::stable_sort(notes.begin(), notes.end(),
                     [](const RecordedMidiNote& a, const RecordedMidiNote& b) { return a.start < b.start; });
    return notes;
}

// MARK: RT

void MidiInputRouter::beginBlock(const Transport& transport, uint32_t numFrames, double sampleRate,
                                 uint64_t cycleHostTicks) DAW_RT {
    clearLive();
    if (numFrames == 0) return;  // a 0-frame block has no frame to put an event on
    blockActive_ = true;
    if (!liveEnabled_.load(std::memory_order_acquire)) return;  // an export: players release (isArmed)

    const TransportBlock& block = transport.block();
    const int64_t blockStart = renderSample_;
    if (cycleHostTicks != 0) {
        lastCycleHost_ = cycleHostTicks;
        lastCycleSample_ = blockStart;
    }
    Anchor anchor;
    anchor.hostTicks = lastCycleHost_;
    anchor.hostSample = lastCycleSample_;
    anchor.renderSample = blockStart;
    anchor.transportSample = block.numSegments > 0 ? block.seg[0].startSample : transport.samplePos();
    anchor.sampleRate = sampleRate;
    anchor.playing = block.playing && block.numSegments > 0;
    anchor.valid = lastCycleHost_ != 0;
    publishAnchor(anchor);

    BlockInfo info;
    info.block = &block;
    info.blockStart = blockStart;
    info.numFrames = numFrames;
    info.hostNow = lastCycleHost_;

    // Dekker with deactivate() (see Recorder.h).
    rtBusy_.store(true, std::memory_order_seq_cst);
    const bool session = sessionActive_.load(std::memory_order_seq_cst);
    info.recording = session && block.playing && block.recording && block.numSegments > 0 && block.tempo != nullptr;
    if (info.recording) {
        info.latency = static_cast<int64_t>(transport.outputLatency());
        const bool first = !recStarted_.load(std::memory_order_relaxed);
        if (first) {
            recStartHeard_ = block.seg[0].startSample - info.latency;
            pass_ = 0;
            havePrev_ = false;
        }
        info.passBefore = pass_;
        for (uint8_t s = 0; s < block.numSegments && s < 2; ++s) {
            if (block.seg[s].afterWrap && !(first && s == 0)) ++pass_;
            info.passOfSegment[s] = pass_;
        }
        if (transport.loopEnabled()) {
            info.loopStart = block.tempo->tickToSample(transport.loopStart());
            const int64_t loopEnd = block.tempo->tickToSample(transport.loopEnd());
            if (loopEnd > info.loopStart) {
                info.loopOn = true;
                info.loopLength = loopEnd - info.loopStart;
                recLoopStart_ = info.loopStart;
                recLoopEnd_ = loopEnd;
            }
        }
        recStarted_.store(true, std::memory_order_release);
    }

    syncLanes(info);  // T-093
    drain(info);

    if (info.recording) {
        const TransportSegment& last = block.seg[std::min<uint8_t>(block.numSegments, 2) - 1];
        const int64_t end = last.startSample + int64_t{last.numFrames};
        int64_t heard = end - info.latency;
        int32_t pass = pass_;
        if (info.loopOn && pass > 0 && heard < info.loopStart) {
            heard += info.loopLength;
            --pass;
        }
        recEndHeard_ = heard;
        recLastPass_ = pass;
        prevEnd_ = end;
        havePrev_ = true;
    }
    rtBusy_.store(false, std::memory_order_release);
    renderSample_ += numFrames;
}

void MidiInputRouter::idleBlock(uint32_t numFrames, uint64_t cycleHostTicks) DAW_RT {
    clearLive();
    if (numFrames == 0 || !liveEnabled_.load(std::memory_order_acquire)) return;
    const int64_t blockStart = renderSample_;
    if (cycleHostTicks != 0) {
        lastCycleHost_ = cycleHostTicks;
        lastCycleSample_ = blockStart;
    }
    BlockInfo info;
    info.blockStart = blockStart;
    info.numFrames = numFrames;
    info.hostNow = lastCycleHost_;
    syncLanes(info);  // T-093
    drain(info);
    renderSample_ += numFrames;
}

void MidiInputRouter::clearLive() DAW_RT {
    for (uint32_t i = 0; i < kMaxArmed; ++i) {  // bounded (CONV-RT-04)
        lanes_[i].numLive = 0;
        lanes_[i].lastFrame = 0;
    }
    maxLive_ = 0;
}

// MARK: RT, per-track lanes (T-093)

uint16_t MidiInputRouter::channelMask(uint64_t filter) DAW_RT {
    const auto channel = static_cast<uint8_t>((filter >> 32) & 0x1F);
    return channel == 0 || channel > 16 ? uint16_t(0xFFFF) : static_cast<uint16_t>(1u << (channel - 1));
}

bool MidiInputRouter::passes(uint64_t filter, const Input& input, uint8_t channel) const DAW_RT {
    if (!(channelMask(filter) & (1u << channel))) return false;
    if ((filter >> 40) & 1) return true;  // all sources
    return input.hasSource.load(std::memory_order_relaxed) &&
           input.source.load(std::memory_order_relaxed) == static_cast<int32_t>(static_cast<uint32_t>(filter));
}

void MidiInputRouter::countLane(const Lane& lane, uint8_t (&holders)[16][128], uint16_t& pedal,
                                uint16_t& bend) const DAW_RT {
    std::memset(holders, 0, sizeof(holders));
    pedal = bend = 0;
    for (uint32_t i = 0; i < kNumSlots; ++i) {  // bounded: inputs × channels × 128 keys
        const Input& input = inputs_[i];
        if (input.state.load(std::memory_order_acquire) == kFree) continue;
        for (uint8_t channel = 0; channel < 16; ++channel) {
            if (!passes(lane.filter, input, channel)) continue;
            const auto bit = static_cast<uint16_t>(1u << channel);
            pedal |= input.pedal & bit;
            bend |= input.bend & bit;
            for (uint8_t w = 0; w < 2; ++w) {
                uint64_t bits = input.held[channel][w];
                while (bits != 0) {  // bounded: 64 bits per word
                    const auto index = std::countr_zero(bits);
                    bits &= bits - 1;
                    ++holders[channel][w * 64 + index];
                }
            }
        }
    }
}

void MidiInputRouter::syncLanes(const BlockInfo& info) DAW_RT {
    for (uint32_t i = 0; i < kMaxArmed; ++i) {  // bounded (CONV-RT-04)
        ArmedSlot& slot = armedSlots_[i];
        Lane& lane = lanes_[i];
        const uint32_t generation = slot.generation.load(std::memory_order_acquire);
        const NodeID track = slot.track.load(std::memory_order_relaxed);
        const uint64_t filter = slot.filter.load(std::memory_order_acquire);
        if (track == 0) {
            lane.active = false;  // disarmed: the player releases what it sent (MidiClipPlayer)
            continue;
        }
        if (!lane.active || lane.generation != generation) {
            // A track just armed, or given a new player: it hears what is held from now on, and a
            // new player sounds those keys itself (heldNote).
            lane.active = true;
            lane.generation = generation;
            lane.player = slot.player.load(std::memory_order_relaxed);
            lane.filter = filter;
            countLane(lane, lane.holders, lane.pedal, lane.bend);
            continue;
        }
        if (lane.filter == filter) continue;

        // Retarget: what the old filter heard and the new one doesn't ends now, and keys held
        // through inputs the new filter passes sound (a filter change never hangs a note).
        lane.filter = filter;
        uint8_t holders[16][128];
        uint16_t pedal = 0, bend = 0;
        countLane(lane, holders, pedal, bend);
        for (uint8_t channel = 0; channel < 16; ++channel) {
            for (uint8_t pitch = 0; pitch < 128; ++pitch) {  // bounded: 2048 keys
                const bool before = lane.holders[channel][pitch] != 0, after = holders[channel][pitch] != 0;
                if (before == after) continue;
                const uint8_t velocity = after ? velocities_[channel][pitch] : 0;
                const uint8_t message[3] = {uint8_t((after ? kNoteOn : kNoteOff) | channel), pitch,
                                            after ? velocity : uint8_t(64)};
                emitLane(lane, message, 3, 0, info);
                // The take records what the track heard: the note ends (or starts) at the switch.
                recordEvent(uint64_t(1) << i, after, channel, pitch, velocity, 0, info);
            }
            const auto bit = static_cast<uint16_t>(1u << channel);
            if ((lane.pedal ^ pedal) & bit) {
                const uint8_t message[3] = {uint8_t(kControlChange | channel), kSustain, uint8_t(pedal & bit ? 127 : 0)};
                emitLane(lane, message, 3, 0, info);
            }
            if ((lane.bend & bit) && !(bend & bit)) {
                const uint8_t message[3] = {uint8_t(kPitchBend | channel), 0, 64};
                emitLane(lane, message, 3, 0, info);
            }
        }
        std::memcpy(lane.holders, holders, sizeof(holders));
        lane.pedal = pedal;
        lane.bend &= bend;  // a bend it was never sent can't be restored; the next one arrives
    }
}

int MidiInputRouter::laneOf(NodeID player) const DAW_RT {
    if (player == 0) return -1;
    for (uint32_t i = 0; i < kMaxArmed; ++i)  // bounded (CONV-RT-04)
        if (lanes_[i].active && lanes_[i].player == player) return int(i);
    return -1;
}

void MidiInputRouter::drain(const BlockInfo& info) DAW_RT {
    const int64_t blockEnd = info.blockStart + info.numFrames;

    // One input a block may close or recover from an overflow: 16 × 128 note-offs at most, which
    // leaves room for the merge below.
    for (uint32_t i = 0; i < kNumSlots; ++i) {
        Input& input = inputs_[i];
        const uint8_t state = input.state.load(std::memory_order_acquire);
        if (state == kFree) continue;
        const bool closing = state == kClosing;
        if (!closing && !input.overflowed.load(std::memory_order_acquire)) continue;
        input.overflowed.store(false, std::memory_order_release);
        for (uint8_t channel = 0; channel < 16; ++channel) releaseChannel(input, channel, 0, info, true);
        if (closing) {
            input.hasPending = false;
            MidiInEvent discarded;
            for (std::size_t n = 0; n < kQueueSize && input.queue.pop(discarded); ++n) {}
            input.state.store(kFree, std::memory_order_release);
        }
        break;
    }

    // REC-011: merge in time order. Each pass consumes one event (CONV-RT-04: bounded by the cap
    // times the input count); room for a CC 123's offs stays free.
    for (uint32_t merged = 0; merged < kMaxMergedPerBlock && maxLive_ + 128 <= kMaxLiveEvents; ++merged) {
        int best = -1;
        int64_t bestTime = std::numeric_limits<int64_t>::max();
        for (uint32_t i = 0; i < kNumSlots; ++i) {
            Input& input = inputs_[i];
            if (input.state.load(std::memory_order_acquire) != kOpen) continue;
            if (!input.hasPending) {
                if (!input.queue.pop(input.pending)) continue;
                input.hasPending = true;
            }
            int64_t time = input.pending.sampleTime;
            // A real input can't be ahead of the block being rendered; it looks that way only
            // after a stale anchor (a device that was stopped). Due now.
            if (i < kInjectedSlot && time >= blockEnd) {
                time = info.blockStart;
                input.pending.sampleTime = time;
            }
            if (time >= blockEnd) continue;  // scheduled for a later block
            if (time < bestTime) {
                bestTime = time;
                best = int(i);
            }
        }
        if (best < 0) break;
        Input& input = inputs_[best];
        input.hasPending = false;
        handleEvent(input, input.pending, info);
    }
}

void MidiInputRouter::handleEvent(Input& input, const MidiInEvent& e, const BlockInfo& info) DAW_RT {
    const uint8_t kind = e.data[0] & 0xF0, channel = e.data[0] & 0x0F;
    const uint8_t d1 = e.data[1] & 0x7F, d2 = e.data[2] & 0x7F;
    const int64_t frame = e.sampleTime - info.blockStart;

    if (kind == kNoteOn && d2 > 0) {
        // A key pressed long ago (the device was stopped) shouldn't sound now.
        if (e.hostTime != 0 && info.hostNow > e.hostTime &&
            double(info.hostNow - e.hostTime) > kStaleSeconds * hostTicksPerSecond_)
            return;
        noteOn(input, channel, d1, d2, frame, info);
    } else if (kind == kNoteOff || kind == kNoteOn) {
        noteOff(input, channel, d1, frame, info);
    } else if (kind == kControlChange && (d1 == kAllSoundOff || d1 == kAllNotesOff)) {
        releaseChannel(input, channel, frame, info, false);  // this input's notes only
    } else if (kind == kControlChange && d1 == kSustain) {
        setPedal(input, channel, d2 >= 64, frame, info);
    } else {
        if (kind == kPitchBend) {
            const auto bit = static_cast<uint16_t>(1u << channel);
            const bool centre = d1 == 0 && d2 == 64;
            if (centre) input.bend &= static_cast<uint16_t>(~bit);
            else input.bend |= bit;
            for (uint32_t i = 0; i < kMaxArmed; ++i) {  // bounded (CONV-RT-04)
                Lane& lane = lanes_[i];
                if (!lane.active || !passes(lane.filter, input, channel)) continue;
                if (centre) lane.bend &= static_cast<uint16_t>(~bit);
                else lane.bend |= bit;
            }
        }
        emitLive(input, e.data, messageSize(e.data[0]), frame, info);
    }
}

void MidiInputRouter::noteOn(Input& input, uint8_t channel, uint8_t pitch, uint8_t velocity, int64_t frame,
                             const BlockInfo& info) DAW_RT {
    uint64_t& word = input.held[channel][pitch >> 6];
    const uint64_t bit = uint64_t(1) << (pitch & 63);
    if (word & bit) return;  // already held on this input: not a new note
    word |= bit;
    velocities_[channel][pitch] = velocity;
    const uint8_t message[3] = {uint8_t(kNoteOn | channel), pitch, velocity};
    for (uint32_t i = 0; i < kMaxArmed; ++i) {  // bounded (CONV-RT-04)
        Lane& lane = lanes_[i];
        if (!lane.active || !passes(lane.filter, input, channel)) continue;
        if (lane.holders[channel][pitch]++ == 0) emitLane(lane, message, 3, frame, info);
    }
    recordNote(input, true, channel, pitch, velocity, frame, info);
}

void MidiInputRouter::noteOff(Input& input, uint8_t channel, uint8_t pitch, int64_t frame,
                              const BlockInfo& info) DAW_RT {
    uint64_t& word = input.held[channel][pitch >> 6];
    const uint64_t bit = uint64_t(1) << (pitch & 63);
    if (!(word & bit)) return;  // not held on this input
    word &= ~bit;
    const uint8_t message[3] = {uint8_t(kNoteOff | channel), pitch, 64};
    for (uint32_t i = 0; i < kMaxArmed; ++i) {  // bounded (CONV-RT-04)
        Lane& lane = lanes_[i];
        if (!lane.active || !passes(lane.filter, input, channel) || lane.holders[channel][pitch] == 0) continue;
        if (--lane.holders[channel][pitch] == 0) emitLane(lane, message, 3, frame, info);
    }
    recordNote(input, false, channel, pitch, 0, frame, info);
}

void MidiInputRouter::releaseChannel(Input& input, uint8_t channel, int64_t frame, const BlockInfo& info,
                                     bool pedalToo) DAW_RT {
    for (uint8_t w = 0; w < 2; ++w) {
        uint64_t bits = input.held[channel][w];
        while (bits != 0) {  // bounded: 64 bits per word
            const auto index = static_cast<uint8_t>(std::countr_zero(bits));
            bits &= bits - 1;
            noteOff(input, channel, static_cast<uint8_t>(w * 64 + index), frame, info);
        }
    }
    if (pedalToo) setPedal(input, channel, false, frame, info);
}

void MidiInputRouter::setPedal(Input& input, uint8_t channel, bool down, int64_t frame, const BlockInfo& info) DAW_RT {
    const auto bit = static_cast<uint16_t>(1u << channel);
    if (((input.pedal & bit) != 0) == down) return;
    if (down) input.pedal |= bit;
    else input.pedal &= static_cast<uint16_t>(~bit);
    const uint8_t message[3] = {uint8_t(kControlChange | channel), kSustain, uint8_t(down ? 127 : 0)};
    for (uint32_t i = 0; i < kMaxArmed; ++i) {  // bounded (CONV-RT-04)
        Lane& lane = lanes_[i];
        if (!lane.active || !passes(lane.filter, input, channel)) continue;
        // The track's pedal is down while any input it hears holds it down.
        bool anyDown = false;
        for (uint32_t j = 0; j < kNumSlots && !anyDown; ++j) {  // bounded: the inputs
            const Input& other = inputs_[j];
            anyDown = (other.pedal & bit) && other.state.load(std::memory_order_relaxed) != kFree &&
                      passes(lane.filter, other, channel);
        }
        if (((lane.pedal & bit) != 0) == anyDown) continue;
        if (anyDown) lane.pedal |= bit;
        else lane.pedal &= static_cast<uint16_t>(~bit);
        emitLane(lane, message, 3, frame, info);
    }
}

void MidiInputRouter::emitLive(const Input& input, const uint8_t* data, uint8_t size, int64_t frame,
                               const BlockInfo& info) DAW_RT {
    const uint8_t channel = data[0] & 0x0F;
    for (uint32_t i = 0; i < kMaxArmed; ++i) {  // bounded (CONV-RT-04)
        Lane& lane = lanes_[i];
        if (lane.active && passes(lane.filter, input, channel)) emitLane(lane, data, size, frame, info);
    }
}

void MidiInputRouter::emitLane(Lane& lane, const uint8_t* data, uint8_t size, int64_t frame,
                               const BlockInfo& info) DAW_RT {
    // A track without a player (no instrument) records but has nobody to play to.
    if (lane.player == 0 || lane.numLive >= kMaxLiveEvents || info.numFrames == 0) return;
    const auto last = int64_t{info.numFrames} - 1;
    auto f = static_cast<uint32_t>(std::clamp<int64_t>(frame, 0, last));
    f = std::max(f, lane.lastFrame);  // frame order, even for out-of-order injected events
    lane.lastFrame = f;
    MidiEvent& out = lane.live[lane.numLive++];
    maxLive_ = std::max(maxLive_, lane.numLive);
    out.frameOffset = f;
    out.size = size;
    out.data[0] = data[0];
    out.data[1] = size > 1 ? data[1] : 0;
    out.data[2] = size > 2 ? data[2] : 0;
}

bool MidiInputRouter::heardPosition(int64_t frame, const BlockInfo& info, int64_t& heard, int32_t& pass) const DAW_RT {
    const TransportBlock& block = *info.block;
    int64_t position;
    int32_t p;
    if (frame < 0) {
        // Struck during an earlier block (the normal case: CoreMIDI events are a little in the
        // past): before the take began it isn't part of it.
        if (!havePrev_) return false;
        position = prevEnd_ + frame;
        p = info.passBefore;
    } else {
        const uint8_t s = block.numSegments == 2 && frame >= block.seg[1].frameOffset ? 1 : 0;
        position = block.seg[s].startSample + (frame - block.seg[s].frameOffset);
        p = info.passOfSegment[s];
    }
    heard = position - info.latency;
    // Just after a wrap the player still hears the end of the previous pass (TIME-009).
    if (info.loopOn && p > 0 && heard < info.loopStart) {
        heard += info.loopLength;
        --p;
    }
    pass = p;
    return true;
}

void MidiInputRouter::recordNote(const Input& input, bool on, uint8_t channel, uint8_t pitch, uint8_t velocity,
                                 int64_t frame, const BlockInfo& info) DAW_RT {
    if (!info.recording) return;
    // T-093: the tracks whose filter passes it (a track records what it hears).
    uint64_t heardBy = 0;
    for (uint32_t i = 0; i < kMaxArmed; ++i)  // bounded (CONV-RT-04)
        if (lanes_[i].active && passes(lanes_[i].filter, input, channel)) heardBy |= uint64_t(1) << i;
    recordEvent(heardBy, on, channel, pitch, velocity, frame, info);
}

void MidiInputRouter::recordEvent(uint64_t heardBy, bool on, uint8_t channel, uint8_t pitch, uint8_t velocity,
                                  int64_t frame, const BlockInfo& info) DAW_RT {
    if (!info.recording || heardBy == 0) return;
    const uint32_t index = recCount_.load(std::memory_order_relaxed);
    if (index >= kMaxRecordEvents) {
        recDropped_.fetch_add(1, std::memory_order_relaxed);
        dropped_.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    int64_t heard = 0;
    int32_t pass = 0;
    if (!heardPosition(frame, info, heard, pass)) return;
    recordBuffer_[index] = RecEvent{heard, pass, on, pitch, velocity, channel, heardBy};
    recCount_.store(index + 1, std::memory_order_release);
}

bool MidiInputRouter::isArmed(NodeID player) const DAW_RT {
    if (!liveEnabled_.load(std::memory_order_acquire)) return false;
    return laneOf(player) >= 0;
}

MidiEventSpan MidiInputRouter::events(NodeID player) const DAW_RT {
    const int lane = laneOf(player);
    if (lane < 0) return {};
    return MidiEventSpan(lanes_[lane].live, lanes_[lane].numLive);
}

bool MidiInputRouter::heldNote(NodeID player, uint8_t channel, uint8_t pitch, uint8_t& velocity) const DAW_RT {
    const int lane = laneOf(player);
    if (lane < 0 || lanes_[lane].holders[channel][pitch] == 0) return false;
    velocity = velocities_[channel][pitch];
    return true;
}

uint16_t MidiInputRouter::pedalMask(NodeID player) const DAW_RT {
    const int lane = laneOf(player);
    return lane < 0 ? 0 : lanes_[lane].pedal;
}

uint16_t MidiInputRouter::bendMask(NodeID player) const DAW_RT {
    const int lane = laneOf(player);
    return lane < 0 ? 0 : lanes_[lane].bend;
}

} // namespace daw
