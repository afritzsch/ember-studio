#pragma once
// T-056 checks for a session-rate change through the facade (IO-033, DW-044, DW-077, DW-118,
// DW-130), run from Tests/DAWEngineTests/SessionRateTests.swift. C++ because they reach
// AssetReloader (facade/, hidden from Swift) and the fake driver's RT-violation count. Every
// facade check asserts the render scopes saw 0 violations (CONV §5.3).

#include "Checks.h"

namespace daw::testing {

// IO-033 bookkeeping (AssetReloader): a pass covers every recorded asset in ID order, counts
// failures, ignores a stale pass's results, leaves out an asset loaded again since it began
// (the newer load wins), and an empty pass is never active.
CheckResult assetReloaderBookkeeping();

// IO-033, DW-044, DW-118 (offline engine, MODEL-005's engine side): a 1 kHz 44.1 kHz file loaded
// into a 48 kHz session; setSessionSampleRate(96 kHz) re-converts it from the file in the
// background: assetsReloaded started (48 → 96 kHz, 1 asset), progress (asset, 1/1), finished.
// play() is queued while it runs (T-089; stop() cancels it), an export started at once waits for
// it, and the render plays
// the clip at 1 kHz from its tick (sample 96000). Peaks follow (96 kHz); the same rate is a no-op
// and 50 kHz is invalidArgument.
CheckResult facadeSessionRateReconvertsAssets();

// IO-033 (T-089, a change of T-056): play() during a re-conversion is queued, not refused:
// TransportPOD::playPending shows it, stop() cancels it (the pass finishing then starts nothing),
// a locate keeps it, and the transport starts when the pass finishes, from the located tick.
// Without a pass running, play() starts at once.
CheckResult facadeQueuedPlayDuringReconversion();

// IO-033: a file that is gone by the rate change: progress carries the error, assetLoadFailed
// names it, finished says 1 of 2 failed (io); the asset is dropped (silent, no peaks) and the
// other one converted. DW-077: a load with a peak-cache directory writes <dir>/<id>.peaks, and
// the re-conversion rewrites it at the new rate (IO-034 stale check).
CheckResult facadeSessionRateFailureAndPeakCache();

// IO-021 (5) + IO-033 on the fake devices: losing Fake Device A falls back to B (44.1 kHz only),
// so the assets loaded at 48 kHz are re-converted to 44.1 kHz (started/progress/finished after
// the deviceChanged event). setSessionSampleRate(48 kHz) on B is refused (unsupported) and
// changes nothing; once A is back it works and re-converts again.
CheckResult facadeDeviceFallbackReconvertsAssets();

} // namespace daw::testing
