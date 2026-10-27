import DAWEngineTestSupport
import Testing

// T-010: AudioAsset, AudioFileLoader, PeakMipmap, AudioImporter (Sources/DAWEngine/io). The
// checks are C++ (Tests/DAWEngineTestSupport/AudioAssetChecks.cpp, AudioFileChecks.cpp): the
// types are ref-counted or move-only behind daw::Result, the loader owns a thread, and test
// audio is synthesized and written with AudioToolbox at test time.

@Suite("IO-032: AudioAsset")
struct AudioAssetTests {
    @Test("IO-032: AudioAsset matches the 04 Interfaces struct and is read-only")
    func contract() { expectPasses(daw.testing.assetContractLayout()) }
    @Test("IO-032: copies retain, moves transfer, the last release retires")
    func refCounting() { expectPasses(daw.testing.assetRefCounting()) }
    @Test("IO-032: the last release goes to the RetireHook, not free() (ENG-014)")
    func retireHook() { expectPasses(daw.testing.assetRetireThroughHook()) }
    @Test("IO-032: concurrent releases retire exactly once")
    func concurrentRelease() { expectPasses(daw.testing.assetConcurrentRelease()) }
    @Test("IO-032: AudioAssetBuilder grows, validates and freezes")
    func builder() { expectPasses(daw.testing.assetBuilder()) }

    #if DEBUG  // the trap exists only in Debug (BUILD-005)
    @Test("IO-032, CONV §5.3: retain/release, including the last release, make 0 RT violations")
    func rtSafe() {
        #expect(daw.RtTrap.install())
        #expect(daw.testing.assetRetainReleaseViolations() == 0)
    }
    #endif
}

@Suite("IO-031: AudioFileLoader")
struct AudioFileLoaderTests {
    @Test("IO-031: 48k → 44.1k → 48k round trip has residual < −80 dB")
    func resampleRoundTrip() {
        let residual = daw.testing.resampleRoundTripResidualDb()
        #expect(residual < -80, "residual \(residual) dB")
    }

    /// Every format AudioToolbox can encode, so the tests write their own files. MP3 has no
    /// encoder on macOS and there is no MP3 fixture; it decodes through the same ExtAudioFile path.
    static let formats = ["wav-i16", "wav-i24", "wav-f32", "aiff-i16", "aiff-i24", "caf-f32", "caf-i24",
                          "flac-i16", "flac-i24", "alac-i24", "aac"]

    @Test("IO-031: decodes at the file rate and resamples to the session rate", arguments: formats)
    func decode(format: String) { expectPasses(daw.testing.decodeFormat(format)) }

    @Test("IO-031: mono, 6 channels and empty files")
    func channelCounts() { expectPasses(daw.testing.decodeChannelCounts()) }
    @Test("IO-031: missing, non-audio and invalid requests fail with daw::Error")
    func errors() { expectPasses(daw.testing.loadErrors()) }
    @Test("IO-031: requests run in order on the daw.loader thread")
    func loaderThread() { expectPasses(daw.testing.loaderThread()) }
}

@Suite("IO-034: Peak mipmaps")
struct PeakMipmapTests {
    @Test("IO-034: min/max at 256/1024/4096/16384 match brute force")
    func bruteForce() { expectPasses(daw.testing.peaksMatchBruteForce()) }
    @Test("IO-034: .peaks file round-trips with the documented layout")
    func fileFormat() { expectPasses(daw.testing.peakFileFormat()) }
    @Test("IO-034: corrupt or truncated .peaks files are rejected")
    func rejectsCorrupt() { expectPasses(daw.testing.peakFileRejectsCorrupt()) }
    @Test("IO-034: the loader writes, reuses and refreshes Project/Cache/<assetID>.peaks")
    func loaderCache() { expectPasses(daw.testing.loaderPeakCache()) }
}

@Suite("IO-030: Audio import")
struct AudioImportTests {
    @Test("IO-030: copies into Project/Audio/ unchanged by default")
    func copies() { expectPasses(daw.testing.importCopiesUnchanged()) }
    @Test("IO-030: name collisions never overwrite")
    func collisions() { expectPasses(daw.testing.importNameCollision()) }
    @Test("IO-030: reference mode leaves the file in place")
    func reference() { expectPasses(daw.testing.importReference()) }
    @Test("IO-030: non-audio and missing files are rejected without side effects")
    func rejects() { expectPasses(daw.testing.importRejectsNonAudio()) }
}
