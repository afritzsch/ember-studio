#include "TestAudio.h"

#include "io/CoreAudioError.h"

#include <AudioToolbox/AudioToolbox.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <limits>
#include <numbers>

namespace daw::testing {

namespace fs = std::filesystem;

TempDir::TempDir() {
    static std::atomic<int> counter{0};
    std::error_code ec;
    path_ = fs::temp_directory_path(ec) /
            ("macdaw-t010-" + std::to_string(::getpid()) + "-" + std::to_string(counter++));
    fs::remove_all(path_, ec);
    fs::create_directories(path_, ec);
}

TempDir::~TempDir() {
    std::error_code ec;
    fs::remove_all(path_, ec);
}

Channels synthTones(double sampleRate, int64_t frames, uint32_t channels) {
    constexpr double kTones[][2] = {{50, 0.08},    {440, 0.08},   {1000, 0.07}, {3150, 0.06},
                                    {7000, 0.05},  {11025, 0.05}, {15000, 0.04}, {18000, 0.04}};
    constexpr double kFade = 0.020;
    const double duration = static_cast<double>(frames) / sampleRate;
    Channels out(channels, std::vector<float>(static_cast<size_t>(frames)));
    for (uint32_t c = 0; c < channels; ++c) {
        for (int64_t i = 0; i < frames; ++i) {
            const double t = static_cast<double>(i) / sampleRate;
            double x = 0;
            for (const auto& [freq, amp] : kTones)
                x += amp * std::sin(2 * std::numbers::pi * freq * t + 0.7 * c + freq * 1e-3);
            const double edge = std::min(t, duration - t);
            if (edge < kFade) x *= edge <= 0 ? 0 : 0.5 - 0.5 * std::cos(std::numbers::pi * edge / kFade);
            out[c][static_cast<size_t>(i)] = static_cast<float>(x);
        }
    }
    return out;
}

int64_t framesAtRate(int64_t frames, double fromRate, double toRate) {
    return std::llround(static_cast<double>(frames) * toRate / fromRate);
}

namespace {

template <class A>
double residual(const A& sampleAt, uint32_t channels, int64_t frames, const Channels& b) {
    if (channels != b.size()) return std::numeric_limits<double>::infinity();
    double err = 0, ref = 0;
    for (uint32_t c = 0; c < channels; ++c) {
        if (static_cast<int64_t>(b[c].size()) != frames) return std::numeric_limits<double>::infinity();
        for (int64_t i = 0; i < frames; ++i) {
            const double r = b[c][static_cast<size_t>(i)];
            const double d = sampleAt(c, i) - r;
            err += d * d;
            ref += r * r;
        }
    }
    return 10 * std::log10(err / ref);
}

} // namespace

double residualDb(const AudioAsset& a, const Channels& b) {
    return residual([&](uint32_t c, int64_t i) { return static_cast<double>(a.data[c][i]); },
                    a.channels, a.frames, b);
}

double residualDb(const Channels& a, const Channels& b) {
    const int64_t frames = a.empty() ? 0 : static_cast<int64_t>(a[0].size());
    return residual([&](uint32_t c, int64_t i) { return static_cast<double>(a[c][static_cast<size_t>(i)]); },
                    static_cast<uint32_t>(a.size()), frames, b);
}

Channels copyChannels(const AudioAsset& asset) {
    Channels out(asset.channels);
    for (uint32_t c = 0; c < asset.channels; ++c) out[c].assign(asset.data[c], asset.data[c] + asset.frames);
    return out;
}

const std::vector<TestFormat>& testFormats() {
    // maxResidualDb: 16-bit quantization of this signal is about −88 dB; 24-bit about −135 dB.
    // AAC is lossy, so its bound only proves decoding and priming alignment (a one-sample shift
    // of an 18 kHz tone alone is worse than −20 dB).
    static const std::vector<TestFormat> formats{
        {"wav-i16", ".wav", -80, false},   {"wav-i24", ".wav", -120, false},
        {"wav-f32", ".wav", -140, false},  {"aiff-i16", ".aiff", -80, false},
        {"aiff-i24", ".aiff", -120, false}, {"caf-f32", ".caf", -140, false},
        {"caf-i24", ".caf", -120, false},  {"flac-i16", ".flac", -80, false},
        {"flac-i24", ".flac", -120, false}, {"alac-i24", ".m4a", -120, false},
        {"aac", ".m4a", -20, true},
    };
    return formats;
}

const TestFormat* findTestFormat(const std::string& name) {
    for (const TestFormat& f : testFormats())
        if (f.name == name) return &f;
    return nullptr;
}

namespace {

struct FileSpec {
    AudioFileTypeID type;
    AudioStreamBasicDescription format;
};

AudioStreamBasicDescription pcm(double rate, uint32_t channels, uint32_t bits, bool isFloat, bool bigEndian) {
    AudioStreamBasicDescription f{};
    f.mSampleRate = rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = (isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) |
                     static_cast<AudioFormatFlags>(kAudioFormatFlagIsPacked) |
                     (bigEndian ? static_cast<AudioFormatFlags>(kAudioFormatFlagIsBigEndian) : 0u);
    f.mBitsPerChannel = bits;
    f.mChannelsPerFrame = channels;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = bits / 8 * channels;
    f.mBytesPerPacket = f.mBytesPerFrame;
    return f;
}

Result<AudioStreamBasicDescription> compressed(AudioFormatID id, AudioFormatFlags flags, double rate, uint32_t channels) {
    AudioStreamBasicDescription f{};
    f.mSampleRate = rate;
    f.mFormatID = id;
    f.mFormatFlags = flags;
    f.mChannelsPerFrame = channels;
    UInt32 size = sizeof(f);
    if (OSStatus s = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nullptr, &size, &f); s != noErr)
        return coreAudioError(s, ErrorCode::unsupported, "format info");
    return f;
}

Result<FileSpec> fileSpec(const std::string& name, double rate, uint32_t ch) {
    if (name == "wav-i16") return FileSpec{kAudioFileWAVEType, pcm(rate, ch, 16, false, false)};
    if (name == "wav-i24") return FileSpec{kAudioFileWAVEType, pcm(rate, ch, 24, false, false)};
    if (name == "wav-f32") return FileSpec{kAudioFileWAVEType, pcm(rate, ch, 32, true, false)};
    if (name == "aiff-i16") return FileSpec{kAudioFileAIFFType, pcm(rate, ch, 16, false, true)};
    if (name == "aiff-i24") return FileSpec{kAudioFileAIFFType, pcm(rate, ch, 24, false, true)};
    if (name == "caf-f32") return FileSpec{kAudioFileCAFType, pcm(rate, ch, 32, true, false)};
    if (name == "caf-i24") return FileSpec{kAudioFileCAFType, pcm(rate, ch, 24, false, false)};
    Result<AudioStreamBasicDescription> f = makeError(ErrorCode::notFound, "unknown test format " + name);
    AudioFileTypeID type = 0;
    if (name == "flac-i16") {
        f = compressed(kAudioFormatFLAC, kAppleLosslessFormatFlag_16BitSourceData, rate, ch);
        type = kAudioFileFLACType;
    } else if (name == "flac-i24") {
        f = compressed(kAudioFormatFLAC, kAppleLosslessFormatFlag_24BitSourceData, rate, ch);
        type = kAudioFileFLACType;
    } else if (name == "alac-i24") {
        f = compressed(kAudioFormatAppleLossless, kAppleLosslessFormatFlag_24BitSourceData, rate, ch);
        type = kAudioFileM4AType;
    } else if (name == "aac") {
        f = compressed(kAudioFormatMPEG4AAC, 0, rate, ch);
        type = kAudioFileM4AType;
    }
    if (!f) return f.error();
    return FileSpec{type, *f};
}

} // namespace

Result<void> writeTestFile(const fs::path& file, const std::string& formatName, double sampleRate,
                           const Channels& channels) {
    const uint32_t ch = static_cast<uint32_t>(channels.size());
    Result<FileSpec> spec = fileSpec(formatName, sampleRate, ch);
    if (!spec) return spec.error();

    const std::string native = file.string();
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, reinterpret_cast<const UInt8*>(native.c_str()), static_cast<CFIndex>(native.size()), false);
    ExtAudioFileRef out = nullptr;
    OSStatus s = ExtAudioFileCreateWithURL(url, spec->type, &spec->format, nullptr, kAudioFileFlags_EraseFile, &out);
    CFRelease(url);
    if (s != noErr) return coreAudioError(s, ErrorCode::unsupported, native + ": cannot create");

    AudioStreamBasicDescription client{};
    client.mSampleRate = sampleRate;
    client.mFormatID = kAudioFormatLinearPCM;
    client.mFormatFlags = static_cast<AudioFormatFlags>(kAudioFormatFlagsNativeFloatPacked) |
                          static_cast<AudioFormatFlags>(kAudioFormatFlagIsNonInterleaved);
    client.mBitsPerChannel = 32;
    client.mChannelsPerFrame = ch;
    client.mFramesPerPacket = 1;
    client.mBytesPerFrame = 4;
    client.mBytesPerPacket = 4;
    s = ExtAudioFileSetProperty(out, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);

    std::vector<std::byte> listStorage(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * ch);
    auto* list = reinterpret_cast<AudioBufferList*>(listStorage.data());
    const size_t frames = channels.empty() ? 0 : channels[0].size();
    for (size_t pos = 0; s == noErr && pos < frames;) {
        const UInt32 n = static_cast<UInt32>(std::min<size_t>(4096, frames - pos));
        list->mNumberBuffers = ch;
        for (uint32_t c = 0; c < ch; ++c) {
            list->mBuffers[c].mNumberChannels = 1;
            list->mBuffers[c].mDataByteSize = n * 4;
            list->mBuffers[c].mData = const_cast<float*>(channels[c].data() + pos);
        }
        s = ExtAudioFileWrite(out, n, list);
        pos += n;
    }
    const OSStatus closed = ExtAudioFileDispose(out);
    if (s != noErr) return coreAudioError(s, ErrorCode::io, native + ": write failed");
    if (closed != noErr) return coreAudioError(closed, ErrorCode::io, native + ": close failed");
    return {};
}

} // namespace daw::testing
