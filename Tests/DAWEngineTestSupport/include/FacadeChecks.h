#pragma once
// T-014 checks for EngineFacade (08 BRIDGE-001..008) that need C++: a fake DriverAdapter that
// renders on demand inside its own RtScope, test nodes reading param slots (DAW_RT bodies), and
// facade internals (FacadeOptions, error mapping). Run from Tests/DAWEngineTests/FacadeTests.swift.
// Everything that renders asserts its RtScope counted 0 violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// ENG-023, DW-027: sweeping a fader param 1000 times through the facade reaches the audio thread
// block by block and builds/publishes no graph.
CheckResult facadeParamSweepPublishesNothing();

// DW-029: freed ParamIDs are reused only after a later graph replaced the ones that used them
// and the block that may still have been rendering the old graph has finished.
CheckResult facadeDeferredParamFree();

// DW-057, DW-064, BRIDGE-002: an export runs on a job thread with the device paused and
// restarted afterwards, disarms recording, renders the latest applied graph, reports progress
// and its result through pollJob, and posts jobFinished.
CheckResult facadeExportPausesDevice();

// DW-050: ErrorCode::cycle (Error::nodes) becomes FacadeErrorCode::cycle with the NodeIDs,
// both through toFacadeError and through applyGraph → graphStatus/graphRejected; other codes map
// one to one.
CheckResult facadeErrorMapping();

// BRIDGE-008: realtime mode with a driver starts it and builds graphs at the device's rate;
// setDevice restarts it and rejects a rate change; without a driver there are no devices.
CheckResult facadeRealtimeDriverSeam();

// DW-041, DW-048, DW-071, BRIDGE-005: the facade's registry has the built-in nodes. An asset
// loaded through loadAsset plays through audioClipPlayer → channelStrip → master into an
// export; the strip's meter reads back through meter(NodeID) and goes away with the node; the
// strip's params are described by paramInfoJSON.
CheckResult facadePlaysAssetThroughBuiltinNodes();

} // namespace daw::testing
