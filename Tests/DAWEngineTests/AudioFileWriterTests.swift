import DAWEngineTestSupport
import Testing

// T-009: AudioFileWriter and TPDF dither (Sources/DAWEngine/io). The checks are C++
// (Tests/DAWEngineTestSupport/AudioFileWriterChecks.cpp): the writer is move-only behind
// daw::Result, and the round trip reads files back through ExtAudioFile.

@Suite("IO-035: AudioFileWriter")
struct AudioFileWriterTests {
    /// 32-bit float CAF (recording) and WAV/AIFF at 16/24/32f (export), plus CAF integers.
    static let formats = ["caf-f32", "caf-i16", "caf-i24", "wav-i16", "wav-i24", "wav-f32",
                          "aiff-i16", "aiff-i24", "aiff-f32"]

    @Test("IO-035: round trip through ExtAudioFile within the quantization error", arguments: formats, [false, true])
    func roundTrip(format: String, dither: Bool) {
        expectPasses(daw.testing.writerRoundTrip(std.string(format), dither))
    }

    @Test("IO-035: recordings are 32-bit float CAF")
    func recordingFormat() { expectPasses(daw.testing.writerRecordingFormat()) }

    @Test("IO-035: integers clamp to full scale (counted), NaN writes 0, float doesn't clip")
    func clipping() { expectPasses(daw.testing.writerClipping()) }

    @Test("IO-035: bad formats, paths, closed writers and channel mismatches fail")
    func errors() { expectPasses(daw.testing.writerErrors()) }
}

@Suite("IO-035, IO-011: TPDF dither")
struct TpdfDitherTests {
    @Test("IO-035: triangular noise in (−1, 1) LSB, mean 0, variance 1/6; seeded")
    func statistics() { expectPasses(daw.testing.tpdfDitherStatistics()) }

    @Test("IO-011: same seed → same bytes whatever the block split; other seed or no dither differ")
    func deterministic() { expectPasses(daw.testing.writerDitherDeterministic()) }
}
