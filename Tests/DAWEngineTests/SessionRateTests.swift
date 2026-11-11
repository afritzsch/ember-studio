import DAWEngineTestSupport
import Testing

// T-056: a session-rate change through the facade (IO-033; DW-044 progress events, DW-077 peak
// cache through loadAsset, DW-118 asset paths kept for the re-conversion). The checks are C++
// (Tests/DAWEngineTestSupport/SessionRateChecks.cpp) to reach AssetReloader and the fake driver's
// RT-violation count; each asserts 0 (CONV §5.3).

@Suite("Session sample rate (IO-033, T-056)")
struct SessionRateTests {
    @Test("IO-033: a pass covers every loaded asset in ID order; stale passes and superseded assets are ignored")
    func reloaderBookkeeping() { expectPasses(daw.testing.assetReloaderBookkeeping()) }

    @Test("IO-033, DW-044: setSessionSampleRate re-converts from the file in the background (started/progress/finished); play queued meanwhile; an export waits and plays the clip at the right pitch and position")
    func reconvertsAssets() { expectPasses(daw.testing.facadeSessionRateReconvertsAssets()) }

    @Test("IO-033 (T-089): play() during a re-conversion is queued (playPending), stop() cancels it, it starts when the pass finishes")
    func queuedPlay() { expectPasses(daw.testing.facadeQueuedPlayDuringReconversion()) }

    @Test("IO-033: a missing file fails its asset (assetLoadFailed, finished with io); DW-077: the peak cache is written and rewritten at the new rate")
    func failureAndPeakCache() { expectPasses(daw.testing.facadeSessionRateFailureAndPeakCache()) }

    @Test("IO-021 (5) + IO-033: a device fallback to a 44.1 kHz-only device re-converts; a rate the device can't run is refused and changes nothing")
    func deviceFallbackReconverts() { expectPasses(daw.testing.facadeDeviceFallbackReconvertsAssets()) }
}
