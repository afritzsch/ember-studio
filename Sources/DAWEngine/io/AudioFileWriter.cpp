#include "io/AudioFileWriter.h"

#include "io/CoreAudioError.h"

#include <AudioToolbox/AudioToolbox.h>

#include <cmath>
#include <cstring>
#include <string>
#include <utility>

namespace daw {

namespace {

constexpr double kMinRate = 1'000;
constexpr double kMaxRate = 768'000;

uint32_t bytesPerSample(AudioSampleFormat sample) {
    switch (sample) {
    case AudioSampleFormat::int16: return 2;
    case AudioSampleFormat::int24: return 3;
    case AudioSampleFormat::float32: return 4;
    }
    return 4;
}

// Packed interleaved linear PCM. `bigEndian` only for the file side of AIFF.
AudioStreamBasicDescription pcmFormat(const AudioFileFormat& format, bool bigEndian) {
    const uint32_t bytes = bytesPerSample(format.sample);
    AudioStreamBasicDescription f{};
    f.mSampleRate = format.sampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = static_cast<AudioFormatFlags>(kAudioFormatFlagIsPacked) |
                     static_cast<AudioFormatFlags>(format.sample == AudioSampleFormat::float32
                                                       ? kAudioFormatFlagIsFloat
                                                       : kAudioFormatFlagIsSignedInteger);
    if (bigEndian) f.mFormatFlags |= static_cast<AudioFormatFlags>(kAudioFormatFlagIsBigEndian);
    f.mBitsPerChannel = bytes * 8;
    f.mChannelsPerFrame = format.numChannels;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = bytes * format.numChannels;
    f.mBytesPerPacket = f.mBytesPerFrame;
    return f;
}

AudioFileTypeID fileTypeID(const AudioFileFormat& format) {
    switch (format.type) {
    case AudioFileType::caf: return kAudioFileCAFType;
    case AudioFileType::wav: return kAudioFileWAVEType;
    case AudioFileType::aiff:
        // Plain AIFF has no float encoding; AIFF-C does.
        return format.sample == AudioSampleFormat::float32 ? kAudioFileAIFCType : kAudioFileAIFFType;
    }
    return kAudioFileWAVEType;
}

// Round to nearest after adding dither, clamp to [lo, hi]. NaN becomes 0.
int32_t quantize(float x, double scale, double ditherLsb, int32_t lo, int32_t hi, uint64_t& clipped) {
    const double v = static_cast<double>(x) * scale + ditherLsb;
    if (std::isnan(v)) return 0;
    const double r = std::floor(v + 0.5);
    if (r < lo) { ++clipped; return lo; }
    if (r > hi) { ++clipped; return hi; }
    return static_cast<int32_t>(r);
}

} // namespace

Result<std::unique_ptr<AudioFileWriter>> AudioFileWriter::create(const std::filesystem::path& file,
                                                                 const AudioFileFormat& format) {
    const std::string native = file.string();
    if (!(format.sampleRate >= kMinRate && format.sampleRate <= kMaxRate))
        return makeError(ErrorCode::invalidArgument, native + ": sample rate out of range");
    if (format.numChannels == 0 || format.numChannels > kMaxFileChannels)
        return makeError(ErrorCode::invalidArgument, native + ": unsupported channel count");

    const AudioStreamBasicDescription fileFormat = pcmFormat(format, format.type == AudioFileType::aiff);
    const AudioStreamBasicDescription clientFormat = pcmFormat(format, false);

    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, reinterpret_cast<const UInt8*>(native.c_str()),
        static_cast<CFIndex>(native.size()), false);
    if (url == nullptr) return makeError(ErrorCode::invalidArgument, native + ": invalid path");
    ExtAudioFileRef ref = nullptr;
    OSStatus s = ExtAudioFileCreateWithURL(url, fileTypeID(format), &fileFormat, nullptr,
                                           kAudioFileFlags_EraseFile, &ref);
    CFRelease(url);
    if (s != noErr) return coreAudioError(s, ErrorCode::io, native + ": cannot create");

    // Same encoding as the file, native endian: no sample conversion, only a byte swap for AIFF.
    s = ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat, sizeof(clientFormat),
                                &clientFormat);
    if (s != noErr) {
        ExtAudioFileDispose(ref);
        return coreAudioError(s, ErrorCode::unsupported, native + ": cannot set client format");
    }
    return std::unique_ptr<AudioFileWriter>(new AudioFileWriter(file, format, ref));
}

AudioFileWriter::AudioFileWriter(std::filesystem::path path, const AudioFileFormat& format,
                                 OpaqueExtAudioFile* file)
    : path_(std::move(path)), format_(format), file_(file), dither_(format.ditherSeed) {}

AudioFileWriter::~AudioFileWriter() { (void)close(); }

Result<void> AudioFileWriter::write(const AudioBufferView& view) {
    if (view.numChannels != format_.numChannels)
        return makeError(ErrorCode::invalidArgument, path_.string() + ": channel count mismatch");
    return write(view.channels, view.numFrames);
}

Result<void> AudioFileWriter::write(const float* const* channels, uint32_t numFrames) {
    if (file_ == nullptr) return makeError(ErrorCode::invalidArgument, path_.string() + ": closed");
    if (numFrames == 0) return {};

    const uint32_t numChannels = format_.numChannels;
    const uint32_t bytes = bytesPerSample(format_.sample);
    const std::size_t frameBytes = std::size_t{bytes} * numChannels;
    if (interleaved_.size() < frameBytes * numFrames) interleaved_.resize(frameBytes * numFrames);
    std::byte* out = interleaved_.data();

    // IO-035: interleave, quantizing integer formats. The dither sequence runs frame by frame,
    // channel by channel, so it depends only on the seed and the number of samples written,
    // not on how the caller splits them into blocks (IO-011).
    const bool dither = format_.dither && format_.sample != AudioSampleFormat::float32;
    for (uint32_t f = 0; f < numFrames; ++f) {
        for (uint32_t c = 0; c < numChannels; ++c, out += bytes) {
            const float x = channels[c][f];
            switch (format_.sample) {
            case AudioSampleFormat::float32:
                std::memcpy(out, &x, 4);
                break;
            case AudioSampleFormat::int16: {
                const auto q = static_cast<int16_t>(
                    quantize(x, 32768.0, dither ? dither_.next() : 0.0, -32768, 32767, clipped_));
                std::memcpy(out, &q, 2);
                break;
            }
            case AudioSampleFormat::int24: {
                const int32_t q =
                    quantize(x, 8388608.0, dither ? dither_.next() : 0.0, -8388608, 8388607, clipped_);
                // Packed little-endian (arm64 is little-endian, D-23), two's complement.
                const auto u = static_cast<uint32_t>(q);
                out[0] = static_cast<std::byte>(u);
                out[1] = static_cast<std::byte>(u >> 8);
                out[2] = static_cast<std::byte>(u >> 16);
                break;
            }
            }
        }
    }

    AudioBufferList list{};
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = numChannels;
    list.mBuffers[0].mDataByteSize = static_cast<UInt32>(frameBytes * numFrames);
    list.mBuffers[0].mData = interleaved_.data();
    const OSStatus s = ExtAudioFileWrite(file_, numFrames, &list);
    if (s != noErr) return coreAudioError(s, ErrorCode::io, path_.string() + ": write failed");
    framesWritten_ += numFrames;
    return {};
}

Result<void> AudioFileWriter::close() {
    if (file_ == nullptr) return {};
    const OSStatus s = ExtAudioFileDispose(file_);
    file_ = nullptr;
    if (s != noErr) return coreAudioError(s, ErrorCode::io, path_.string() + ": close failed");
    return {};
}

} // namespace daw
