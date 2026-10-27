#pragma once
// T-009 checks for AudioFileWriter and TpdfDither (IO-035, IO-011), run from
// Tests/DAWEngineTests/AudioFileWriterTests.swift. C++ because the writer is move-only behind
// daw::Result and the round trip reads files back with AudioToolbox.

#include "Checks.h"

#include <string>

namespace daw::testing {

// IO-035: writes a two-channel test signal in uneven blocks as `format` (caf-f32, caf-i16, caf-i24,
// wav-i16, wav-i24, wav-f32, aiff-i16, aiff-i24, aiff-f32), checks the file's type and data format,
// and reads it back through ExtAudioFile. Float is bit-exact; integers are within 0.5 LSB, or
// 1.5 LSB with TPDF dither, whose error has mean ≈ 0 and RMS ≈ 0.5 LSB (1/4 LSB² total).
CheckResult writerRoundTrip(const std::string& format, bool dither);

// IO-035: AudioFileFormat::recording is 32-bit float CAF.
CheckResult writerRecordingFormat();

// IO-011, IO-035: the same seed gives the same bytes however the frames are split into blocks;
// another seed, or no dither, gives different bytes.
CheckResult writerDitherDeterministic();

// IO-035: integers clamp to full scale (counted), NaN writes 0, float doesn't clip.
CheckResult writerClipping();

// IO-035: bad formats, uncreatable paths, writes after close and channel mismatches fail.
CheckResult writerErrors();

// IO-035: TPDF noise lies in (−1, 1) LSB, has mean 0, variance 1/6 and a triangular shape;
// a seed always gives the same sequence.
CheckResult tpdfDitherStatistics();

} // namespace daw::testing
