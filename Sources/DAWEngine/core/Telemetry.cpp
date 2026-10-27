#include "core/Telemetry.h"

#include <bit>
#include <thread>

#include <mach/mach_time.h>

namespace daw {

namespace {

uint64_t packMeter(float peak, float rms) DAW_RT {
    return uint64_t{std::bit_cast<uint32_t>(peak)} | uint64_t{std::bit_cast<uint32_t>(rms)} << 32;
}

MeterReading unpackMeter(uint64_t word) DAW_RT {
    return {std::bit_cast<float>(static_cast<uint32_t>(word)),
            std::bit_cast<float>(static_cast<uint32_t>(word >> 32))};
}

} // namespace

Telemetry::Telemetry()
    : meters_(new std::atomic<uint64_t>[kMaxMeters]()) {
    latencies_.slots.reset(new LatencySlot[kMaxNodeLatencies]());
    mach_timebase_info_data_t timebase{};
    if (mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.denom != 0)
        nanosPerTick_ = static_cast<double>(timebase.numer) / timebase.denom;
}

Telemetry::~Telemetry() = default;

// ENG-051: mach_absolute_time reads the timebase counter through the commpage: no syscall, no
// lock, no allocation. The effect analysis can't know that about an unannotated libc function.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunknown-warning-option"
#pragma clang diagnostic ignored "-Wfunction-effects"
uint64_t Telemetry::clockTicks() DAW_RT { return mach_absolute_time(); }
#pragma clang diagnostic pop

uint64_t Telemetry::ticksToNanos(uint64_t ticks) const DAW_RT {
    return static_cast<uint64_t>(static_cast<double>(ticks) * nanosPerTick_);
}

void Telemetry::recordBlock(uint64_t renderNanos, uint32_t numFrames, double sampleRate,
                            uint64_t violations, uint64_t epoch) DAW_RT {
    BlockFields& b = block_;
    if (sampleRate > 0) b.lastSampleRate = sampleRate;

    if (numFrames > 0 && b.lastSampleRate > 0) {
        // ENG-050: load = render time / block duration.
        const double blockSeconds = numFrames / b.lastSampleRate;
        const float percent = static_cast<float>(renderNanos * 1e-9 / blockSeconds * 100.0);
        // EMA with a fixed time constant, so the smoothing doesn't depend on the block size:
        // alpha = dt / (tau + dt), the first-order approximation of 1 - exp(-dt / tau).
        if (!b.emaSeeded) {
            b.emaPercent = percent;
            b.emaSeeded = true;
        } else {
            const float alpha =
                static_cast<float>(blockSeconds / (kDspLoadTimeConstant + blockSeconds));
            b.emaPercent += alpha * (percent - b.emaPercent);
        }
        b.lastBlockLoadPercent.store(percent, std::memory_order_relaxed);
        b.dspLoadPercent.store(b.emaPercent, std::memory_order_relaxed);
    }

    // Single writer, so load + store is enough (and cheaper than an RMW).
    if (violations != 0)
        b.rtViolations.store(b.rtViolations.load(std::memory_order_relaxed) + violations,
                             std::memory_order_relaxed);
    b.graphEpoch.store(epoch, std::memory_order_relaxed);
}

void Telemetry::countOversizeBlock() DAW_RT {
    block_.oversizeBlocks.store(block_.oversizeBlocks.load(std::memory_order_relaxed) + 1,
                                std::memory_order_relaxed);
}

void Telemetry::countRetireQueueFull() DAW_RT {
    block_.retireQueueFullBlocks.store(
        block_.retireQueueFullBlocks.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
}

void Telemetry::countXrun() DAW_RT {
    // Several producers (overload listener, render callback): a real RMW.
    device_.xruns.fetch_add(1, std::memory_order_relaxed);
}

void Telemetry::setDeviceOutputLatency(uint32_t samples) DAW_RT {
    device_.deviceOutputLatency.store(samples, std::memory_order_relaxed);
}

void Telemetry::publishNodeLatencies(const NodeLatency* entries, uint32_t count,
                                     uint32_t graphLatency) DAW_RT {
    if (count > kMaxNodeLatencies) count = kMaxNodeLatencies;
    LatencyTable& t = latencies_;
    // Seqlock write side (one writer): odd, fence, data, even with release. A reader that saw the
    // same even value before and after its copy read no part of this write.
    const uint64_t sequence = t.sequence.load(std::memory_order_relaxed);
    t.sequence.store(sequence + 1, std::memory_order_relaxed);
    std::atomic_thread_fence(std::memory_order_release);
    for (uint32_t i = 0; i < count; ++i) {
        t.slots[i].node.store(entries[i].node, std::memory_order_relaxed);
        t.slots[i].samples.store(entries[i].samples, std::memory_order_relaxed);
    }
    t.count.store(count, std::memory_order_relaxed);
    t.graphLatency.store(graphLatency, std::memory_order_relaxed);
    t.sequence.store(sequence + 2, std::memory_order_release);
}

void Telemetry::writeMeter(MeterID meter, float peak, float rms) DAW_RT {
    if (meter >= kMaxMeters) return;
    meters_[meter].store(packMeter(peak, rms), std::memory_order_relaxed);
}

TelemetrySnapshot Telemetry::snapshot() const {
    TelemetrySnapshot s;
    s.dspLoadPercent = block_.dspLoadPercent.load(std::memory_order_relaxed);
    s.lastBlockLoadPercent = block_.lastBlockLoadPercent.load(std::memory_order_relaxed);
    s.xruns = device_.xruns.load(std::memory_order_relaxed);
    s.rtViolations = block_.rtViolations.load(std::memory_order_relaxed);
    s.graphEpoch = block_.graphEpoch.load(std::memory_order_relaxed);
    s.oversizeBlocks = block_.oversizeBlocks.load(std::memory_order_relaxed);
    s.retireQueueFullBlocks = block_.retireQueueFullBlocks.load(std::memory_order_relaxed);
    s.deviceOutputLatency = device_.deviceOutputLatency.load(std::memory_order_relaxed);
    // The two table scalars come from the same write; the seqlock isn't needed for a scalar
    // each, but reading both under it keeps graphLatency and the count from different graphs
    // out of one snapshot.
    for (;;) {
        const uint64_t before = latencies_.sequence.load(std::memory_order_acquire);
        if ((before & 1u) == 0) {
            s.graphLatency = latencies_.graphLatency.load(std::memory_order_relaxed);
            s.numNodeLatencies = latencies_.count.load(std::memory_order_relaxed);
            std::atomic_thread_fence(std::memory_order_acquire);
            if (latencies_.sequence.load(std::memory_order_relaxed) == before) break;
        }
        std::this_thread::yield();
    }
    s.outputLatency = s.deviceOutputLatency + s.graphLatency;
    return s;
}

uint32_t Telemetry::nodeLatencies(NodeLatency* out, uint32_t max) const {
    const LatencyTable& t = latencies_;
    // Seqlock read side: retry until no write overlapped the copy. Writes are rare (once per
    // graph) and wait-free, so this settles at once in practice.
    for (;;) {
        const uint64_t before = t.sequence.load(std::memory_order_acquire);
        if ((before & 1u) == 0) {
            uint32_t n = t.count.load(std::memory_order_relaxed);
            if (n > max) n = max;
            for (uint32_t i = 0; i < n; ++i) {
                out[i].node = t.slots[i].node.load(std::memory_order_relaxed);
                out[i].samples = t.slots[i].samples.load(std::memory_order_relaxed);
            }
            std::atomic_thread_fence(std::memory_order_acquire);
            if (t.sequence.load(std::memory_order_relaxed) == before) return n;
        }
        std::this_thread::yield();
    }
}

MeterReading Telemetry::meter(MeterID meter) const DAW_RT {
    if (meter >= kMaxMeters) return {};
    return unpackMeter(meters_[meter].load(std::memory_order_relaxed));
}

std::optional<RtViolationReport> Telemetry::firstViolation() const {
    return RtTrap::firstViolation();
}

} // namespace daw
