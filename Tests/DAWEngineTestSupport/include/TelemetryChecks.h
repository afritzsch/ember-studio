#pragma once
// T-006 checks for engine telemetry (TelemetryChecks.cpp), run from
// Tests/DAWEngineTests/TelemetryTests.swift. They're C++ because they need Engine (non-movable),
// threads, RtScope and DAW_RT test nodes. Every check that renders or writes from RT code asserts
// that its RtScope counted 0 violations (CONV §5.3, DW-019), except the deliberate ones below.

#include <cstdint>

#include "Checks.h"
#include "core/Telemetry.h"

namespace daw::testing {

// ENG-051: clockTicks() is monotonic and ticksToNanos() converts with the mach timebase.
CheckResult telemetryClock();

// ENG-050: recordBlock() load math (render time / block duration, EMA with a fixed time constant),
// unknown and inherited sample rates, 0-frame blocks, violation and epoch accounting.
CheckResult telemetryDspLoadMath();

// ENG-050/051, ENG-041, DW-024: Engine::render publishes telemetry every block: graphEpoch, a load
// that covers a node's measured busy time, rtViolations 0, and the render scope counts 0.
CheckResult engineTelemetryPerBlock();

// DW-037: blocks larger than the graph's maxBlock render silence and are counted.
CheckResult engineCountsOversizeBlocks();

// DW-037: a block that ends with the RetireQueue full is counted (daw.reclaim held up on purpose).
CheckResult engineCountsRetireQueueFull();

// ENG-050 producer paths that have no producer yet: xruns from several threads, device output
// latency, the per-node latency table (truncation included) and meters. Every writer runs inside
// an RtScope that must count 0.
CheckResult telemetryProducerPaths();

// ENG-050 "read without locks": a writer thread publishes latency tables and meters while a
// reader thread checks it never sees a torn table or a torn peak/RMS pair.
CheckResult telemetryConcurrentReadersSeeConsistentValues();

// For the Swift side: renders `blocks` blocks of a constant graph and returns the snapshot, so
// Swift reads the plain-data type the facade will copy into TelemetryPOD.
TelemetrySnapshot snapshotAfterRendering(uint32_t blocks);

// DW-011, DW-024 (process-wide trap state, so run only from the serialized RtTrapTests suite):
// an allocating node's violations show in that engine's rtViolations and firstViolation(), while
// violations made outside its render scope don't change its count.
CheckResult engineRtViolationsFromRenderScope();
CheckResult engineRtViolationsIgnoreOtherScopes();

} // namespace daw::testing
