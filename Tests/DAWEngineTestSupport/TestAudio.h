#pragma once
// T-010 test helpers (private to DAWEngineTestSupport): temporary folders, an analytic test
// signal, a writer for test files in every format AudioToolbox can encode, and the residual
// measure the IO-031 acceptance uses. The engine's own AudioFileWriter (IO-035) is T-009's and
// is deliberately not used here.

#include "core/Result.h"
#include "io/AudioAsset.h"

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace daw::testing {

using Channels = std::vector<std::vector<float>>;

// A fresh folder under $TMPDIR, unique per process and call (CONV §9), removed on destruction.
class TempDir {
public:
    TempDir();
    ~TempDir();
    TempDir(const TempDir&) = delete;
    TempDir& operator=(const TempDir&) = delete;
    const std::filesystem::path& path() const { return path_; }

private:
    std::filesystem::path path_;
};

// A sum of sines (50 Hz … 18 kHz, a different phase per channel) with 20 ms raised-cosine fades
// at both ends, peaking below 0.5. It is defined in continuous time, so sampling it at another
// rate gives the exact reference for a resampled load, provided the reference uses the source's
// `duration` (the fade-out is anchored to it; frames / sampleRate differs by the rounding of the
// resampled length). Everything is inside 20 kHz, and the fades keep the edges band-limited.
// `maxFrequency` drops the tones above it, for lossy codecs that low-pass.
Channels synthTones(double sampleRate, int64_t frames, uint32_t channels, double duration = 0,
                    double maxFrequency = 20000);

// The same duration at another rate, rounded like the loader's resampled length.
int64_t framesAtRate(int64_t frames, double fromRate, double toRate);

// 10·log10(Σ(a−b)² / Σb²) over all channels: the residual relative to reference `b`, in dB.
// +inf on a shape mismatch, −inf when identical.
double residualDb(const AudioAsset& a, const Channels& b);
double residualDb(const Channels& a, const Channels& b);

Channels copyChannels(const AudioAsset& asset);

// Test file formats, by name: wav-i16, wav-i24, wav-f32, aiff-i16, aiff-i24, caf-f32, caf-i24,
// flac-i16, flac-i24, alac-i24 (.m4a), aac (.m4a).
struct TestFormat {
    std::string name;
    std::string extension;
    double maxResidualDb; // what the encoding itself costs, vs the float source
    double maxFrequency;  // highest test tone the codec keeps
};
const std::vector<TestFormat>& testFormats();
const TestFormat* findTestFormat(const std::string& name);

Result<void> writeTestFile(const std::filesystem::path& file, const std::string& formatName,
                           double sampleRate, const Channels& channels);

} // namespace daw::testing
