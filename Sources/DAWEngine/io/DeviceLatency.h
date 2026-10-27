#pragma once
// IO-005: device latency in samples, per direction, and where the driver publishes it.

#include <cstdint>

namespace daw {

class Engine;

// The CoreAudio properties one direction's latency is made of, in device frames.
struct LatencyComponents {
    uint32_t device = 0;        // kAudioDevicePropertyLatency
    uint32_t safetyOffset = 0;  // kAudioDevicePropertySafetyOffset
    uint32_t stream = 0;        // kAudioStreamPropertyLatency of the first stream
    uint32_t bufferFrames = 0;  // kAudioDevicePropertyBufferFrameSize
};

// 04 Interfaces: AudioDriver::latency(). Samples at the session rate; 0 when not running (or no
// input).
struct DeviceLatency {
    uint32_t input = 0;
    uint32_t output = 0;
};

// IO-005: device + safety offset + buffer + stream, saturating at UINT32_MAX.
uint32_t totalLatency(const LatencyComponents& components);

// IO-005, DW-049, DW-059: makes `latency.output` the engine's device output latency, both in
// telemetry (deviceOutputLatency, so outputLatency = it + PDC) and in the transport (the playhead
// shows what is heard, TIME-009). Any thread; drivers call it whenever they start.
void publishDeviceLatency(Engine& engine, const DeviceLatency& latency);

} // namespace daw
