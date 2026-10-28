#pragma once
// IO-001: the device-independent half of a device IO cycle. A driver hands it the cycle's
// non-interleaved device buffers; it calls Engine::render in blocks of at most maxBlock() frames,
// so a device that asks for more frames than the configured buffer (or an uneven count) still
// gets rendered by graphs prepared for the buffer size. CoreAudioDriver calls it from the AUHAL
// render callback; a fake driver (T-050) can call it from its own thread.
//
// IO-023 (DW-068): it also times each cycle. A cycle whose render took longer than the audio it
// produced (numFrames / sampleRate) is an overrun: the device would have played a glitch. It
// counts as an xrun in telemetry. The first kXrunGraceSeconds of device time after configure()
// aren't judged: the first cycles after a start are slow (cold caches, page faults) and CoreAudio
// often reports a processor overload right at start, which CoreAudioDriver ignores for the same
// window (inStartGrace()).
//
// Threads: configure() while no cycle runs; renderCycle() from one thread at a time (it is the
// engine's render thread, 02); the counters from any thread.

#include <atomic>
#include <cstdint>

#include "core/Realtime.h"
#include "io/DriverConfig.h"

namespace daw {

class Engine;

// IO-023, DW-068: how long after a driver start overruns and overload notifications are ignored.
inline constexpr double kXrunGraceSeconds = 0.25;

class DeviceRenderer {
public:
    explicit DeviceRenderer(Engine& engine) : engine_(engine) {}
    DeviceRenderer(const DeviceRenderer&) = delete;
    DeviceRenderer& operator=(const DeviceRenderer&) = delete;

    // Non-RT. Blocks are at most `maxBlock` frames (clamped to 1…kMaxBlock); the published graph
    // must be prepared for at least that many (ENG-015 renders silence otherwise). `sampleRate`
    // is the device clock overruns are judged against (IO-023); 0 means there is no device clock
    // (a fake device rendering as fast as possible), so nothing is an overrun. Starts the grace
    // window.
    void configure(uint32_t maxBlock, double sampleRate = 0);
    uint32_t maxBlock() const DAW_RT { return maxBlock_; }

    // RT. Renders `numFrames` frames into `output` (its first kMaxDeviceChannels channels; any
    // beyond are cleared) with `input` as the device input. Either side may have 0 channels.
    void renderCycle(float* const* output, uint32_t outputChannels, float* const* input,
                     uint32_t inputChannels, uint32_t numFrames) DAW_RT;

    // Diagnostics (relaxed): cycles and frames rendered, Engine::render calls, largest cycle.
    uint64_t cycles() const { return cycles_.load(std::memory_order_relaxed); }
    uint64_t frames() const { return frames_.load(std::memory_order_relaxed); }
    uint64_t blocks() const { return blocks_.load(std::memory_order_relaxed); }
    uint32_t largestCycle() const { return largestCycle_.load(std::memory_order_relaxed); }
    // IO-023: cycles that overran (each also counted as a telemetry xrun), all runs.
    uint64_t overruns() const { return overruns_.load(std::memory_order_relaxed); }
    // Any thread: fewer than kXrunGraceSeconds of frames rendered since configure().
    bool inStartGrace() const {
        return frames_.load(std::memory_order_relaxed) < graceEndFrame_.load(std::memory_order_relaxed);
    }

private:
    Engine& engine_;
    uint32_t maxBlock_ = kDefaultDeviceBuffer;
    double nanosPerFrame_ = 0;  // 0: overruns aren't judged
    std::atomic<uint64_t> graceEndFrame_{0};
    std::atomic<uint64_t> overruns_{0};
    std::atomic<uint64_t> cycles_{0};
    std::atomic<uint64_t> frames_{0};
    std::atomic<uint64_t> blocks_{0};
    std::atomic<uint32_t> largestCycle_{0};
};

} // namespace daw
