#include "io/DeviceLatency.h"

#include <limits>

#include "core/Engine.h"

namespace daw {

uint32_t totalLatency(const LatencyComponents& c) {
    // Garbage from a driver mustn't wrap into a small latency.
    const uint64_t sum = uint64_t{c.device} + c.safetyOffset + c.stream + c.bufferFrames;
    constexpr uint64_t kMax = std::numeric_limits<uint32_t>::max();
    return static_cast<uint32_t>(sum < kMax ? sum : kMax);
}

void publishDeviceLatency(Engine& engine, const DeviceLatency& latency) {
    engine.telemetry().setDeviceOutputLatency(latency.output);  // DW-049
    engine.transport().setOutputLatency(latency.output);        // DW-059
}

} // namespace daw
