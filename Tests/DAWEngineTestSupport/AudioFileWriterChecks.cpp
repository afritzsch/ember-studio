// T-009 checks for AudioFileWriter and TpdfDither (IO-035, IO-011). Run from
// Tests/DAWEngineTests/AudioFileWriterTests.swift.

#include "AudioFileWriterChecks.h"

#include "ExportTestSupport.h"
#include "TestAudio.h"
#include "io/AudioFileWriter.h"
#include "io/TpdfDither.h"

#include <AudioToolbox/AudioToolbox.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <memory>
#include <vector>

namespace daw::testing {

namespace {

constexpr double kRate = 48000;

double lsbScale(AudioSampleFormat sample) {
    switch (sample) {
    case AudioSampleFormat::int16: return 32768.0;
    case AudioSampleFormat::int24: return 8388608.0;
    case AudioSampleFormat::float32: return 0;
    }
    return 0;
}

std::unique_ptr<AudioFileWriter> makeWriter(const std::filesystem::path& file, const AudioFileFormat& format) {
    auto created = AudioFileWriter::create(file, format);
    return created ? std::move(created).value() : nullptr;
}

// Writes `channels` in blocks cycling through `blocks`; false on any error.
bool writeInBlocks(AudioFileWriter& writer, const Channels& channels, const std::vector<uint32_t>& blocks) {
    const size_t frames = channels.empty() ? 0 : channels[0].size();
    std::vector<const float*> ptrs(channels.size());
    size_t pos = 0;
    for (size_t i = 0; pos < frames; ++i) {
        const auto n = static_cast<uint32_t>(std::min<size_t>(blocks[i % blocks.size()], frames - pos));
        for (size_t c = 0; c < channels.size(); ++c) ptrs[c] = channels[c].data() + pos;
        if (!writer.write(ptrs.data(), n)) return false;
        pos += n;
    }
    return true;
}

// The round-trip signal: test tones scaled to peak just under 0.95, so the 16-bit LSBs are busy.
Channels testSignal(int64_t frames) {
    Channels signal = synthTones(kRate, frames, 2);
    for (auto& channel : signal)
        for (float& x : channel) x *= 1.9f;
    return signal;
}

const std::vector<uint32_t> kUnevenBlocks{1, 1000, 4096, 3, 517};

} // namespace

CheckResult writerRoundTrip(const std::string& name, bool dither) {
    CheckResult checks;
    const ExportFormat* format = findExportFormat(name);
    DAW_CHECK(format != nullptr);
    if (!format) return checks;

    TempDir dir;
    const auto file = dir.path() / ("roundtrip" + format->extension);
    const Channels signal = testSignal(48000);
    {
        auto writer = makeWriter(file, {format->type, format->sample, kRate, 2, dither, kDefaultDitherSeed});
        DAW_CHECK(writer != nullptr);
        if (!writer) return checks;
        DAW_CHECK(writeInBlocks(*writer, signal, kUnevenBlocks));
        DAW_CHECK(writer->framesWritten() == 48000);
        DAW_CHECK(writer->clippedSamples() == 0);
        DAW_CHECK(writer->close());
    }

    // The file is what was asked for.
    const bool isFloat = format->sample == AudioSampleFormat::float32;
    Result<FileInfo> info = readFileInfo(file);
    DAW_CHECK(info.ok());
    if (!info) return checks;
    AudioFileTypeID expectedType = kAudioFileWAVEType;
    if (format->type == AudioFileType::caf) expectedType = kAudioFileCAFType;
    if (format->type == AudioFileType::aiff) expectedType = isFloat ? kAudioFileAIFCType : kAudioFileAIFFType;
    DAW_CHECK(info->fileType == expectedType);
    DAW_CHECK(info->bitsPerChannel == (format->sample == AudioSampleFormat::int16 ? 16u
                                       : format->sample == AudioSampleFormat::int24 ? 24u : 32u));
    DAW_CHECK(((info->formatFlags & kAudioFormatFlagIsFloat) != 0) == isFloat);
    DAW_CHECK(info->channels == 2);
    DAW_CHECK(info->sampleRate == kRate);
    DAW_CHECK(info->frames == 48000);

    // Round trip through ExtAudioFile.
    Result<Channels> back = readBack(file, kRate);
    DAW_CHECK(back.ok());
    if (!back) return checks;
    DAW_CHECK(back->size() == 2);
    if (back->size() != 2 || (*back)[0].size() != 48000 || (*back)[1].size() != 48000) {
        DAW_CHECK(!"read back has the wrong shape");
        return checks;
    }

    if (isFloat) {
        // Float is written unchanged (dither is ignored for it): bit-exact.
        for (int c = 0; c < 2; ++c)
            DAW_CHECK(std::memcmp((*back)[c].data(), signal[c].data(), 48000 * sizeof(float)) == 0);
        return checks;
    }

    // Integer: every read-back sample is on the grid, and the error is bounded by the
    // quantization (0.5 LSB) plus, with dither, the TPDF noise (< 1 LSB).
    const double scale = lsbScale(format->sample);
    double maxErr = 0, sum = 0, sumSq = 0;
    bool onGrid = true;
    for (int c = 0; c < 2; ++c) {
        for (size_t i = 0; i < 48000; ++i) {
            const double q = static_cast<double>((*back)[c][i]) * scale;
            onGrid = onGrid && q == std::floor(q);
            const double err = q - static_cast<double>(signal[c][i]) * scale;
            maxErr = std::max(maxErr, std::fabs(err));
            sum += err;
            sumSq += err * err;
        }
    }
    const double n = 2 * 48000;
    const double mean = sum / n, rms = std::sqrt(sumSq / n);
    DAW_CHECK(onGrid);
    if (dither) {
        DAW_CHECK(maxErr < 1.5);
        DAW_CHECK(std::fabs(mean) < 0.01);
        DAW_CHECK(std::fabs(rms - 0.5) < 0.02);       // sqrt(1/12 + 1/6)
    } else {
        DAW_CHECK(maxErr <= 0.5 + 1e-9);
        DAW_CHECK(std::fabs(rms - 0.2887) < 0.02);    // sqrt(1/12)
    }
    return checks;
}

CheckResult writerRecordingFormat() {
    CheckResult checks;
    const AudioFileFormat format = AudioFileFormat::recording(44100, 1);
    DAW_CHECK(format.type == AudioFileType::caf);
    DAW_CHECK(format.sample == AudioSampleFormat::float32);

    TempDir dir;
    const auto file = dir.path() / "take.caf";
    const Channels signal = synthTones(44100, 4410, 1);
    {
        auto writer = makeWriter(file, format);
        DAW_CHECK(writer != nullptr);
        if (!writer) return checks;
        DAW_CHECK(writeInBlocks(*writer, signal, {256}));
        DAW_CHECK(writer->close());
    }
    Result<FileInfo> info = readFileInfo(file);
    DAW_CHECK(info.ok());
    if (!info) return checks;
    DAW_CHECK(info->fileType == kAudioFileCAFType);
    DAW_CHECK((info->formatFlags & kAudioFormatFlagIsFloat) != 0);
    DAW_CHECK(info->bitsPerChannel == 32);
    DAW_CHECK(info->channels == 1);
    DAW_CHECK(info->sampleRate == 44100);
    Result<Channels> back = readBack(file, 44100);
    DAW_CHECK(back.ok() && back->size() == 1 && (*back)[0] == signal[0]);
    return checks;
}

CheckResult writerDitherDeterministic() {
    CheckResult checks;
    TempDir dir;
    const Channels signal = testSignal(20000);
    auto writeFile = [&](const char* name, bool dither, uint64_t seed, const std::vector<uint32_t>& blocks) {
        const auto file = dir.path() / name;
        auto writer = makeWriter(file, {AudioFileType::wav, AudioSampleFormat::int16, kRate, 2, dither, seed});
        if (!writer || !writeInBlocks(*writer, signal, blocks) || !writer->close()) return std::vector<char>{};
        return fileBytes(file);
    };
    const auto a = writeFile("a.wav", true, kDefaultDitherSeed, {512});
    const auto b = writeFile("b.wav", true, kDefaultDitherSeed, kUnevenBlocks);
    const auto otherSeed = writeFile("c.wav", true, 12345, {512});
    const auto plain = writeFile("d.wav", false, kDefaultDitherSeed, {512});
    DAW_CHECK(!a.empty());
    DAW_CHECK(a == b);
    DAW_CHECK(a.size() == otherSeed.size() && a != otherSeed);
    DAW_CHECK(a.size() == plain.size() && a != plain);

    // The same holds for 24-bit, and for files written by separate writers in one process.
    auto write24 = [&](const char* name) {
        const auto file = dir.path() / name;
        auto writer = makeWriter(file, {AudioFileType::aiff, AudioSampleFormat::int24, kRate, 2, true, 7});
        if (!writer || !writeInBlocks(*writer, signal, {333}) || !writer->close()) return std::vector<char>{};
        return fileBytes(file);
    };
    const auto x = write24("x.aif");
    DAW_CHECK(!x.empty());
    DAW_CHECK(x == write24("y.aif"));
    return checks;
}

CheckResult writerClipping() {
    CheckResult checks;
    TempDir dir;
    const float inf = std::numeric_limits<float>::infinity();
    const std::vector<float> input{1.0f, 1.5f, -1.0f, -1.5f, std::nanf(""), inf, -inf, 0.5f, -0.25f};

    struct Case { AudioSampleFormat sample; double scale; double lo, hi; };
    for (const Case& k : {Case{AudioSampleFormat::int16, 32768.0, -32768, 32767},
                          Case{AudioSampleFormat::int24, 8388608.0, -8388608, 8388607}}) {
        const auto file = dir.path() / (k.sample == AudioSampleFormat::int16 ? "clip16.wav" : "clip24.wav");
        {
            auto writer = makeWriter(file, {AudioFileType::wav, k.sample, kRate, 1, false, kDefaultDitherSeed});
            DAW_CHECK(writer != nullptr);
            if (!writer) return checks;
            const float* ch = input.data();
            DAW_CHECK(writer->write(&ch, static_cast<uint32_t>(input.size())));
            DAW_CHECK(writer->clippedSamples() == 5);  // 1.0, ±1.5, ±inf
            DAW_CHECK(writer->close());
        }
        Result<Channels> back = readBack(file, kRate);
        DAW_CHECK(back.ok() && back->size() == 1 && (*back)[0].size() == input.size());
        if (!back || back->size() != 1 || (*back)[0].size() != input.size()) return checks;
        const std::vector<double> expected{k.hi, k.hi, k.lo, k.lo, 0, k.hi, k.lo, 0.5 * k.scale, -0.25 * k.scale};
        for (size_t i = 0; i < input.size(); ++i)
            DAW_CHECK(static_cast<double>((*back)[0][i]) * k.scale == expected[i]);
    }

    // Float keeps over-range values.
    const auto file = dir.path() / "float.wav";
    const std::vector<float> loud{1.5f, -2.0f, 0.75f};
    {
        auto writer = makeWriter(file, {AudioFileType::wav, AudioSampleFormat::float32, kRate, 1, true, 1});
        DAW_CHECK(writer != nullptr);
        if (!writer) return checks;
        const float* ch = loud.data();
        DAW_CHECK(writer->write(&ch, 3));
        DAW_CHECK(writer->clippedSamples() == 0);
    }  // the destructor closes
    Result<Channels> back = readBack(file, kRate);
    DAW_CHECK(back.ok() && back->size() == 1 && (*back)[0] == loud);
    return checks;
}

CheckResult writerErrors() {
    CheckResult checks;
    TempDir dir;
    const auto file = dir.path() / "e.wav";
    auto fails = [&](const std::filesystem::path& path, AudioFileFormat format, ErrorCode code) {
        auto created = AudioFileWriter::create(path, format);
        return !created.ok() && created.error().code == code;
    };
    AudioFileFormat ok{AudioFileType::wav, AudioSampleFormat::int16, kRate, 2, false, kDefaultDitherSeed};
    AudioFileFormat bad = ok;
    bad.sampleRate = 0;
    DAW_CHECK(fails(file, bad, ErrorCode::invalidArgument));
    bad.sampleRate = std::nan("");
    DAW_CHECK(fails(file, bad, ErrorCode::invalidArgument));
    bad = ok;
    bad.numChannels = 0;
    DAW_CHECK(fails(file, bad, ErrorCode::invalidArgument));
    bad.numChannels = kMaxFileChannels + 1;
    DAW_CHECK(fails(file, bad, ErrorCode::invalidArgument));
    DAW_CHECK(fails(dir.path() / "missing" / "e.wav", ok, ErrorCode::io));
    DAW_CHECK(!std::filesystem::exists(file));

    auto writer = makeWriter(file, ok);
    DAW_CHECK(writer != nullptr);
    if (!writer) return checks;
    std::vector<float> l(8, 0.1f), r(8, -0.1f), x(8, 0);
    float* three[3] = {l.data(), r.data(), x.data()};
    DAW_CHECK(!writer->write(AudioBufferView{three, 3, 8}).ok());  // 3 channels into a stereo file
    DAW_CHECK(writer->write(AudioBufferView{three, 2, 8}));
    DAW_CHECK(writer->write(three, 0));  // empty writes are fine
    DAW_CHECK(writer->framesWritten() == 8);
    DAW_CHECK(writer->close());
    DAW_CHECK(writer->close());          // twice is fine
    DAW_CHECK(!writer->write(three, 8).ok());
    DAW_CHECK(writer->framesWritten() == 8);
    Result<FileInfo> info = readFileInfo(file);
    DAW_CHECK(info.ok() && info->frames == 8);
    return checks;
}

CheckResult tpdfDitherStatistics() {
    CheckResult checks;
    constexpr int kN = 1'000'000;
    TpdfDither dither(kDefaultDitherSeed);
    double sum = 0, sumSq = 0, minV = 1, maxV = -1;
    int inner = 0;
    for (int i = 0; i < kN; ++i) {
        const double v = dither.next();
        sum += v;
        sumSq += v * v;
        minV = std::min(minV, v);
        maxV = std::max(maxV, v);
        if (std::fabs(v) < 0.5) ++inner;
    }
    DAW_CHECK(minV > -1 && maxV < 1);
    DAW_CHECK(std::fabs(sum / kN) < 0.002);
    DAW_CHECK(std::fabs(sumSq / kN - 1.0 / 6.0) < 0.002);
    // Triangular on (−1, 1): P(|v| < 0.5) = 3/4 (uniform would give 1/2).
    DAW_CHECK(std::fabs(static_cast<double>(inner) / kN - 0.75) < 0.003);

    TpdfDither a(42), b(42), c(43);
    bool same = true, differs = false;
    for (int i = 0; i < 1000; ++i) {
        const double va = a.next();
        same = same && va == b.next();
        differs = differs || va != c.next();
    }
    DAW_CHECK(same);
    DAW_CHECK(differs);
    return checks;
}

} // namespace daw::testing
