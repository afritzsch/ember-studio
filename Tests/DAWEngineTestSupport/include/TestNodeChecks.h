#pragma once
// T-019 checks for the TEST-004 test-only nodes (TestNodes.h) and their registration under real
// kinds, run from Tests/DAWEngineTests/TestNodeTests.swift. C++ because they call DAW_RT
// process() inside an RtScope; all but the AllocatingNode check assert 0 RT violations
// (CONV §5.3).

#include <cstdint>

#include "Checks.h"

namespace daw::testing {

// TEST-004 SineNode: level · sin(2π f n / rate) on every channel across odd block sizes
// (including 0); reset() restarts at phase 0.
CheckResult testSineNode();

// TEST-004 ImpulseNode: impulses at first + k · period, single with period 0; reset() restarts.
CheckResult testImpulseNode();

// TEST-004 FakeLatencyNode(n): output is the input n frames later, latencySamples() == n,
// reset() clears the delay line; n = 0 passes through.
CheckResult testFakeLatencyNode();

// TEST-004 NaNNode: quiet NaN on every channel.
CheckResult testNaNNode();

// TEST-004: registered under audioClipPlayer, a test node stands in only for players with no
// clips (the real player keeps clip-ful ones); under another kind it replaces it (a
// FakeLatencyNode's latency is reported and compensated, MIX-023); a kind given twice is
// rejected. Renders through GraphBuilder + Engine with 0 RT violations.
CheckResult testNodeRegistration();

// TEST-004 AllocatingNode: what one RtScope counts across `blocks` blocks (expected 2 per
// block: a malloc and a free). Deliberate violations: only for the serialized RtTrapTests suite.
uint64_t allocatingNodeViolations(uint32_t blocks);

} // namespace daw::testing
