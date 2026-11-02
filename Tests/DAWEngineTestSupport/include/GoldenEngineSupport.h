#pragma once
// T-019: the engine golden tests render with (14-testing, TEST-001/004). A real EngineFacade
// whose registry also has test-only nodes (TestNodes.h), registered under real kinds through
// FacadeOptions::registerNodes, so fixture scripts built from ordinary commands can put a
// SineNode where a track's clip player would be. Nothing here is in Sources/DAWEngine.
//
// Swift imports this header as its own module, DAWGoldenSupport (include/module.modulemap), so it
// includes only what the DAWEngine module already shows Swift: no engine-internal headers, no
// DAW_RT_TRAP dependence, no extra include paths for the importer.

#include <cstdint>
#include <vector>

#include "daw/EngineFacade.h"

#ifndef SWIFT_RETURNS_RETAINED
#define SWIFT_RETURNS_RETAINED
#endif

namespace daw::testing {

// TEST-004.
enum class TestNodeType : uint8_t {
    sine,        // level · sin(2π · frequency · n / rate) on every channel, n from the last reset
    impulse,     // level at frames offset, offset + samples, … since the last reset (samples 0: once)
    fakeLatency, // its input delayed by `samples`, reporting latencySamples() = samples
    allocating,  // silence, allocating and freeing once per block (the RT trap must count it)
    nan,         // quiet NaN on every channel
    sidechainMix, // input + level · sidechain (MIX-008, T-023); register it under an insert kind (compressor)
};

// One test node registered under a real kind. Under audioClipPlayer it stands in only for
// players with no clips, so a fixture can mix test sources with real clips (wav_playback goldens).
// Under any other kind it replaces that kind outright.
struct TestNodeSpec {
    NodeKind kind = NodeKind::audioClipPlayer;
    TestNodeType type = TestNodeType::sine;
    double frequency = 0;  // sine, Hz
    float level = 1;       // sine peak, impulse amplitude
    uint32_t samples = 0;  // impulse period; fakeLatency latency
    uint32_t offset = 0;   // impulse: first frame
};

using TestNodeSpecs = std::vector<TestNodeSpec>;

// An offline facade (BRIDGE-008) at `sampleRate` with `specs` registered after the built-in
// kinds. One reference, like EngineFacade::create. Null if the rate is out of range or a kind
// appears twice.
EngineFacade* makeTestFacade(double sampleRate, const TestNodeSpecs& specs) SWIFT_RETURNS_RETAINED;

} // namespace daw::testing
