#pragma once
// ENG-050/051: engine telemetry. Lock-free counters and gauges written by the audio thread (and a
// few other producers, below) and read by any thread without locks. Engine::render publishes the
// per-block values; the facade (08, T-014) copies snapshot() into its TelemetryPOD.
//
// Producers and how they write (every write is wait-free and DAW_RT, so RT code may call it):
//   Engine::render (audio thread)    recordBlock() once per block, countOversizeBlock(),
//                                    countRetireQueueFull()
//   device driver (T-011/T-051)      countXrun() from any thread (overload notification or the
//                                    render callback, IO-023); setDeviceOutputLatency() whenever
//                                    the device starts or changes (IO-005)
//   graph / PDC (T-012/T-021)        publishNodeLatencies() with the latencies of the graph being
//                                    rendered; one writer at a time (see below)
//   built-in effects (T-070)         countNanBlock() from process() when the NaN guard silences a
//                                    block (DSP-040, DW-142)
//   channel strips, meters (T-013/T-020)  writeMeter() from process() for the MeterID the node was
//                                    configured with (MIX-005); one node per MeterID
//
// Consistency (what a reader gets). Scalars are separate relaxed atomics: each value is one a
// producer actually wrote, but snapshot() may combine fields from adjacent blocks (say, the load
// of block n with the violation count of block n+1). Counters only grow, gauges are latest-value,
// so that's harmless for display and for "is it 0" checks. Two things need more and get it:
//   - a meter's peak and RMS are one 64-bit atomic word, so a reading is always a pair one write
//     produced;
//   - the per-node latency table (count, entries, graph latency) is a seqlock: the writer is
//     wait-free, a reader retries until it copies a table no write overlapped.

#include <atomic>
#include <cstdint>
#include <memory>
#include <optional>

#include "core/Node.h"
#include "core/Realtime.h"
#include "core/RtTrap.h"

namespace daw {

// The plain-data copy readers get (trivially copyable, so the facade copies it field by field
// into TelemetryPOD).
struct TelemetrySnapshot {
    // ENG-050/051: render time / block duration in percent, as an exponential moving average
    // (time constant Telemetry::kDspLoadTimeConstant) and for the last block alone.
    float dspLoadPercent = 0;
    float lastBlockLoadPercent = 0;
    // Device xruns (IO-023), counted by the driver.
    uint64_t xruns = 0;
    // DW-024: violations counted by the render RtScope of this engine's blocks (ENG-032). In
    // production only the engine opens RT scopes, so it equals RtTrap::violationCount(); unlike
    // that one it can't see other threads' or other engines' violations. Always 0 in Release.
    uint64_t rtViolations = 0;
    // ENG-012: the engine's renderEpoch after its last completed block (even; 2 × blocks
    // rendered). It identifies how far the audio thread has got, i.e. which graphs reclaim may
    // already have freed.
    uint64_t graphEpoch = 0;
    // DW-037: blocks rendered as silence because numFrames exceeded the graph's maxBlock.
    uint64_t oversizeBlocks = 0;
    // DW-037: blocks that ended with the RetireQueue full, so RT retire() calls were failing
    // (callers keep the object and retry; a growing count means daw.reclaim isn't keeping up).
    uint64_t retireQueueFullBlocks = 0;
    // DSP-040, DW-142: blocks the built-in effects' NaN guards silenced (each effect's own block
    // counts once, so one bad input through two effects counts twice).
    uint64_t nanBlocks = 0;
    // Output latency in samples: the device's (IO-005) plus the current graph's PDC latency
    // (MIX-021); outputLatency is their sum.
    uint32_t deviceOutputLatency = 0;
    uint32_t graphLatency = 0;
    uint32_t outputLatency = 0;
    // Entries in the per-node latency table (read them with Telemetry::nodeLatencies).
    uint32_t numNodeLatencies = 0;
};

struct NodeLatency {
    NodeID node = 0;
    uint32_t samples = 0;
};

// Index into the meter table. GraphBuilder assigns one per metering node, like a ParamID.
using MeterID = uint32_t;

// Linear amplitude. What the window is (e.g. MIX-005's 300 ms RMS) is up to the producer.
struct MeterReading {
    float peak = 0;
    float rms = 0;
};

class Telemetry {
public:
    static constexpr uint32_t kMaxNodeLatencies = 4096;
    static constexpr uint32_t kMaxMeters = 4096;
    static constexpr double kDspLoadTimeConstant = 0.3;  // seconds

    // Non-RT: allocates the tables and reads the mach timebase.
    Telemetry();
    ~Telemetry();
    Telemetry(const Telemetry&) = delete;
    Telemetry& operator=(const Telemetry&) = delete;

    // MARK: Clock (ENG-051)

    // mach_absolute_time(): reads the timebase counter in user space; no syscall, no lock.
    static uint64_t clockTicks() DAW_RT;
    uint64_t ticksToNanos(uint64_t ticks) const DAW_RT;

    // MARK: Writers

    // Engine::render only (single writer). One completed block of `numFrames` at `sampleRate`
    // that took `renderNanos`; `violations` is what the block's RtScope counted, `epoch` the
    // renderEpoch after it. sampleRate 0 (no graph) means "same rate as the previous block";
    // until a rate is known, and for 0-frame blocks, the load is left as it was.
    void recordBlock(uint64_t renderNanos, uint32_t numFrames, double sampleRate,
                     uint64_t violations, uint64_t epoch) DAW_RT;
    void countOversizeBlock() DAW_RT;     // Engine::render only
    void countRetireQueueFull() DAW_RT;   // Engine::render only

    // Any thread, any number of them.
    void countXrun() DAW_RT;
    void countNanBlock() DAW_RT;  // DSP-040, DW-142
    void setDeviceOutputLatency(uint32_t samples) DAW_RT;

    // One writer at a time; it's simplest for the audio thread to copy the table from the graph
    // it is rendering whenever the graph changes, so telemetry describes what is heard. Entries
    // beyond kMaxNodeLatencies are dropped.
    void publishNodeLatencies(const NodeLatency* entries, uint32_t count,
                              uint32_t graphLatency) DAW_RT;

    // One writer per MeterID. Out-of-range IDs are ignored.
    void writeMeter(MeterID meter, float peak, float rms) DAW_RT;

    // MARK: Readers (any thread)

    TelemetrySnapshot snapshot() const;

    // Copies up to `max` entries of one consistent latency table into `out` and returns how many
    // it copied. Non-RT: it may spin while a write is in progress.
    uint32_t nodeLatencies(NodeLatency* out, uint32_t max) const;

    // Zero for out-of-range IDs and meters nobody wrote.
    MeterReading meter(MeterID meter) const DAW_RT;

    // Non-RT. DW-011, ENG-032: the first violation's backtrace, symbolized here, off the audio
    // thread (RtTrap::firstViolation). It is process-wide: in production that is this engine's
    // render scope; in tests it may be another suite's deliberate violation.
    std::optional<RtViolationReport> firstViolation() const;

private:
    struct LatencySlot {
        std::atomic<NodeID> node{0};
        std::atomic<uint32_t> samples{0};
    };

    // Written by the audio thread every block. Kept off the cache lines other producers write.
    struct alignas(kCacheLineSize) BlockFields {
        std::atomic<float> dspLoadPercent{0};
        std::atomic<float> lastBlockLoadPercent{0};
        std::atomic<uint64_t> rtViolations{0};
        std::atomic<uint64_t> graphEpoch{0};
        std::atomic<uint64_t> oversizeBlocks{0};
        std::atomic<uint64_t> retireQueueFullBlocks{0};
        std::atomic<uint64_t> nanBlocks{0};  // DW-142
        // Writer-private (audio thread): EMA state and the last known sample rate.
        float emaPercent = 0;
        bool emaSeeded = false;
        double lastSampleRate = 0;
    };
    struct alignas(kCacheLineSize) DeviceFields {
        std::atomic<uint64_t> xruns{0};
        std::atomic<uint32_t> deviceOutputLatency{0};
    };
    struct alignas(kCacheLineSize) LatencyTable {
        std::atomic<uint64_t> sequence{0};  // odd while a write is in progress
        std::atomic<uint32_t> count{0};
        std::atomic<uint32_t> graphLatency{0};
        std::unique_ptr<LatencySlot[]> slots;
    };

    static_assert(std::atomic<uint64_t>::is_always_lock_free);
    static_assert(std::atomic<float>::is_always_lock_free);

    double nanosPerTick_ = 1.0;
    BlockFields block_;
    DeviceFields device_;
    LatencyTable latencies_;
    // MeterReading packed as two floats in one word, so a reading is never torn.
    std::unique_ptr<std::atomic<uint64_t>[]> meters_;
};

} // namespace daw
