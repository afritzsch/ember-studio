#pragma once
// T-011 checks for the device driver (IO-001..005), run from
// Tests/DAWEngineTests/DeviceDriverTests.swift. C++ because they own Engines, render DAW_RT test
// nodes, use threads and RtScope, and fake os_workgroup with DAW_RT functions. Every RT path is
// run inside an RtScope that must count 0 (CONV §5.3, DW-019).
//
// Most checks need no audio device. The device checks (coreAudio*) report `skipped` when there is
// no device to use, so they pass cleanly on headless CI.

#include <cstdint>
#include <string>

#include "Checks.h"

namespace daw::testing {

// IO-003: rate (0 = nominal, fallback when the nominal isn't a session rate, explicit, invalid,
// unsupported), buffer size (32…2048, clamped to the device range) and channels are resolved.
CheckResult driverConfigResolves();

// IO-004: a separate input device is used only when it shares the output's (known) clock.
CheckResult inputDeviceChoice();

// IO-005: latency = device + safety offset + buffer + stream (saturating), and publishing it sets
// telemetry's deviceOutputLatency (DW-049) and the transport's output latency (DW-059).
CheckResult deviceLatencyMathAndPublish();

// IO-001: an IO cycle renders through Engine::render in blocks of at most the configured buffer
// (any cycle length, contiguous output), clears device channels the master doesn't have and those
// beyond kMaxDeviceChannels, and makes 0 RT violations.
CheckResult deviceRendererBlocks();

// IO-004: InputFifo keeps frames in order across the wrap, clears and counts underruns, drops the
// oldest backlog, and counts overflow.
CheckResult inputFifoBasics();

// IO-004: one producer and one consumer thread, each inside an RtScope: every frame arrives in
// order and both scopes count 0.
CheckResult inputFifoTwoThreads();

// IO-002: WorkgroupJoin with fake os_workgroup ops: joins on the first cycle only, again when the
// IO thread changes, leaves on request from the joining thread, handles EALREADY and errors,
// releases the workgroup, and makes 0 RT violations.
CheckResult workgroupBookkeeping();

// MARK: Device checks (real CoreAudio)

// Whether the system has a default output device; DAW_SKIP_DEVICE_TESTS=1 forces false.
bool hasDefaultOutputDevice();

// What a run on a real device saw, for the test log (IO-002 acceptance: the os_workgroup result).
struct DeviceRunReport {
    bool skipped = false;     // no usable device
    CheckResult checks;
    std::string device;
    double sampleRate = 0;
    uint32_t bufferFrames = 0;
    uint64_t cycles = 0;
    uint64_t blocks = 0;
    uint64_t framesProcessed = 0;  // by the test sine node
    int joinResult = 0;            // os_workgroup_join's return value
    std::string workgroupState;    // after the run, and stateAfterStop after stop()
    std::string stateAfterStop;
    uint32_t inputLatency = 0;
    uint32_t outputLatency = 0;
    uint64_t rtViolations = 0;     // the engine's render scopes (telemetry, DW-024)
    uint64_t xruns = 0;
    bool separateInput = false;    // IO-004: input through the InputFifo
    uint64_t fifoUnderruns = 0;
    uint64_t fifoDropped = 0;
};

// IO-001/002/003/005: the default output device plays a sine (at −80 dBFS, or −20 dBFS for a
// second with DAW_AUDIBLE_DEVICE_TEST=1) through the engine: the IO thread joins the device's
// workgroup, latency matches the properties and reaches telemetry and the transport, stop() ends
// rendering and leaves the workgroup, and the driver restarts.
DeviceRunReport coreAudioPlaysSine();

// IO-001/004: input enabled on a device with both input and output (e.g. BlackHole): input comes
// from the same AUHAL unit and AudioUnitRender succeeds. Opt-in (DAW_DEVICE_INPUT_TESTS=1): input
// needs microphone permission, which would prompt on a developer machine.
DeviceRunReport coreAudioDuplexInput();

// IO-004/005: input enabled with the default input and output devices. When they are different
// devices on one clock (e.g. a Mac's built-in mic and speakers), input runs on a second AUHAL unit
// through the InputFifo without errors or dropped frames; otherwise it falls back to the output
// device. Opt-in like coreAudioDuplexInput.
DeviceRunReport coreAudioDefaultInput();

} // namespace daw::testing
