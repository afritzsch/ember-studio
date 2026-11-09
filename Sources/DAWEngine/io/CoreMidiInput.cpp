// REC-010 (T-053): see CoreMidiInput.h.

#include "io/CoreMidiInput.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMIDI/CoreMIDI.h>
#include <pthread.h>
#include <pthread/qos.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <map>
#include <mutex>
#include <thread>

#include "record/MidiInputRouter.h"

namespace daw {

namespace {

constexpr CFTimeInterval kRunLoopSlice = 0.25;              // seconds; how quickly daw.midi notices a stop
constexpr auto kRescanInterval = std::chrono::seconds(2);   // in case a notification was missed

std::string toString(CFStringRef text) {
    if (text == nullptr) return {};
    char buffer[256];
    if (!CFStringGetCString(text, buffer, sizeof(buffer), kCFStringEncodingUTF8)) return {};
    return buffer;
}

std::string sourceName(MIDIEndpointRef endpoint) {
    CFStringRef name = nullptr;
    if (MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) != noErr || name == nullptr) return "MIDI Source";
    std::string out = toString(name);
    CFRelease(name);
    return out.empty() ? "MIDI Source" : out;
}

} // namespace

struct CoreMidiInput::Impl {
    explicit Impl(MidiInputRouter& r) : router(r) {
        thread = std::thread([this] { run(); });
    }

    ~Impl() {
        stopping.store(true, std::memory_order_release);
        // CFRunLoopStop is safe from any thread; the slice timeout covers a loop not running yet.
        if (CFRunLoopRef loop = runLoop.load(std::memory_order_acquire)) {
            CFRunLoopStop(loop);
            CFRunLoopWakeUp(loop);
        }
        thread.join();
    }

    void run() {
        pthread_setname_np("daw.midi");
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
        runLoop.store(CFRunLoopGetCurrent(), std::memory_order_release);

        MIDIClientRef client = 0;
        OSStatus status = MIDIClientCreateWithBlock(CFSTR("Ember Studio"), &client, ^(const MIDINotification*) {
            needsScan.store(true, std::memory_order_release);
        });
        MIDIPortRef port = 0;
        if (status == noErr) {
            // The SDK marks the receive block nonblocking. Ours is: it does a bounded parse and
            // lock-free pushes (MidiInputRouter::receive).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
            status = MIDIInputPortCreateWithProtocol(
                client, CFSTR("Ember Studio MIDI In"), kMIDIProtocol_1_0, &port,
                ^(const MIDIEventList* list, void* srcConnRefCon) { receive(list, srcConnRefCon); });
#pragma clang diagnostic pop
        }
        clientAvailable.store(status == noErr, std::memory_order_release);

        if (status == noErr) scan(port);
        {
            std::lock_guard lock(mutex);
            ready = true;
        }
        readyChanged.notify_all();

        auto lastScan = std::chrono::steady_clock::now();
        while (!stopping.load(std::memory_order_acquire)) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, kRunLoopSlice, false);
            if (status != noErr) continue;
            const auto now = std::chrono::steady_clock::now();
            if (needsScan.exchange(false, std::memory_order_acq_rel) || now - lastScan >= kRescanInterval) {
                scan(port);
                lastScan = now;
            }
        }

        if (port != 0) {
            for (auto& [id, connection] : connections) MIDIPortDisconnectSource(port, connection.endpoint);
            MIDIPortDispose(port);
        }
        if (client != 0) MIDIClientDispose(client);
    }

    // daw.midi only (the map); the published list is under `mutex`.
    void scan(MIDIPortRef port) {
        std::map<MIDIUniqueID, Source> seen;
        const ItemCount count = MIDIGetNumberOfSources();
        for (ItemCount i = 0; i < count; ++i) {
            const MIDIEndpointRef endpoint = MIDIGetSource(i);
            if (endpoint == 0) continue;
            MIDIUniqueID id = 0;
            if (MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id) != noErr) continue;
            seen[id] = Source{endpoint, sourceName(endpoint)};
        }

        // Gone: disconnect first, so nothing more arrives for the slot, then close it.
        for (auto it = connections.begin(); it != connections.end();) {
            if (seen.count(it->first) != 0) {
                ++it;
                continue;
            }
            MIDIPortDisconnectSource(port, it->second.endpoint);
            router.closeInput(it->second.slot);
            it = connections.erase(it);
        }
        // New.
        for (const auto& [id, source] : seen) {
            if (connections.count(id) != 0) continue;
            const int slot = router.openInput();
            if (slot < 0) continue;  // all slots in use; a later scan tries again
            void* refCon = reinterpret_cast<void*>(static_cast<intptr_t>(slot + 1));
            if (MIDIPortConnectSource(port, source.endpoint, refCon) != noErr) {
                router.closeInput(slot);
                continue;
            }
            connections[id] = Connection{source.endpoint, slot};
        }

        std::vector<MidiSourceInfo> list;
        list.reserve(seen.size());
        for (const auto& [id, source] : seen)
            list.push_back(MidiSourceInfo{id, source.name, connections.count(id) != 0});
        std::lock_guard lock(mutex);
        published = std::move(list);
    }

    // CoreMIDI's receive thread, the slot's one producer. MIDI 1.0 protocol, so each message is a
    // 32-bit universal packet word; channel voice is message type 2.
    void receive(const MIDIEventList* list, void* refCon) {
        const auto slot = static_cast<int>(reinterpret_cast<intptr_t>(refCon)) - 1;
        const MIDIEventPacket* packet = &list->packet[0];
        for (UInt32 p = 0; p < list->numPackets; ++p) {
            for (UInt32 w = 0; w < packet->wordCount;) {
                const UInt32 word = packet->words[w];
                const UInt32 messageType = word >> 28;
                if (messageType == 2) {
                    const auto status = static_cast<uint8_t>((word >> 16) & 0xFF);
                    if (status >= 0x80 && status < 0xF0) {
                        const auto d1 = static_cast<uint8_t>((word >> 8) & 0x7F);
                        const auto d2 = static_cast<uint8_t>(word & 0x7F);
                        const uint8_t message[3] = {status, d1, d2};
                        const uint8_t kind = status & 0xF0;
                        (void)router.receive(slot, packet->timeStamp, message, kind == 0xC0 || kind == 0xD0 ? 2 : 3);
                    }
                }
                // Universal packet lengths in words, by message type.
                w += messageType == 3 || messageType == 4 ? 2 : messageType == 5 ? 4 : 1;
            }
            packet = MIDIEventPacketNext(packet);
        }
    }

    struct Source {
        MIDIEndpointRef endpoint = 0;
        std::string name;
    };
    struct Connection {
        MIDIEndpointRef endpoint = 0;
        int slot = -1;
    };

    MidiInputRouter& router;
    std::atomic<bool> stopping{false};
    std::atomic<bool> needsScan{false};
    std::atomic<bool> clientAvailable{false};
    std::atomic<CFRunLoopRef> runLoop{nullptr};
    std::map<MIDIUniqueID, Connection> connections;  // daw.midi only

    mutable std::mutex mutex;
    mutable std::condition_variable readyChanged;
    bool ready = false;
    std::vector<MidiSourceInfo> published;
    std::thread thread;  // last
};

CoreMidiInput::CoreMidiInput(MidiInputRouter& router) : impl_(std::make_unique<Impl>(router)) {}
CoreMidiInput::~CoreMidiInput() = default;

std::vector<MidiSourceInfo> CoreMidiInput::sources() const {
    std::lock_guard lock(impl_->mutex);
    return impl_->published;
}

bool CoreMidiInput::available() const { return impl_->clientAvailable.load(std::memory_order_acquire); }

bool CoreMidiInput::waitUntilReady(uint32_t timeoutMs) const {
    std::unique_lock lock(impl_->mutex);
    return impl_->readyChanged.wait_for(lock, std::chrono::milliseconds(timeoutMs), [this] { return impl_->ready; });
}

void CoreMidiInput::rescan() {
    impl_->needsScan.store(true, std::memory_order_release);
    if (CFRunLoopRef loop = impl_->runLoop.load(std::memory_order_acquire)) CFRunLoopWakeUp(loop);
}

} // namespace daw
