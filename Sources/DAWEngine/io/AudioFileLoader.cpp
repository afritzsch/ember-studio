#include "io/AudioFileLoader.h"

#include "io/CoreAudioError.h"

#include <AudioToolbox/AudioToolbox.h>
#include <os/log.h>
#include <pthread.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

namespace daw {

namespace {

constexpr UInt32 kChunkFrames = 8192;
constexpr double kMaxSampleRate = 768'000;

os_log_t ioLog() {
    static os_log_t log = os_log_create("dev.macdaw", "io");
    return log;
}

// 32-bit float, native endian, one buffer per channel: the AudioAsset layout.
AudioStreamBasicDescription floatFormat(double sampleRate, uint32_t channels) {
    AudioStreamBasicDescription f{};
    f.mSampleRate = sampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = static_cast<AudioFormatFlags>(kAudioFormatFlagsNativeFloatPacked) |
                     static_cast<AudioFormatFlags>(kAudioFormatFlagIsNonInterleaved);
    f.mBitsPerChannel = 32;
    f.mChannelsPerFrame = channels;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = sizeof(float); // per channel buffer, since non-interleaved
    f.mBytesPerPacket = sizeof(float);
    return f;
}

// An AudioBufferList with room for `channels` buffers (the struct declares one).
class BufferList {
public:
    explicit BufferList(uint32_t channels)
        : storage_(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * std::max(channels, 1u)),
          channels_(channels) {}

    AudioBufferList* get() { return reinterpret_cast<AudioBufferList*>(storage_.data()); }

    // Points buffer c at channels[c] + offset, with room for `frames`.
    template <class ChannelFn>
    AudioBufferList* point(ChannelFn channel, UInt32 frames) {
        AudioBufferList* list = get();
        list->mNumberBuffers = channels_;
        for (uint32_t c = 0; c < channels_; ++c) {
            list->mBuffers[c].mNumberChannels = 1;
            list->mBuffers[c].mDataByteSize = frames * sizeof(float);
            list->mBuffers[c].mData = channel(c);
        }
        return list;
    }

private:
    std::vector<std::byte> storage_;
    uint32_t channels_;
};

struct ExtAudioFileCloser {
    void operator()(OpaqueExtAudioFile* file) const { ExtAudioFileDispose(file); }
};
using ExtAudioFilePtr = std::unique_ptr<OpaqueExtAudioFile, ExtAudioFileCloser>;

struct AudioConverterCloser {
    void operator()(OpaqueAudioConverter* converter) const { AudioConverterDispose(converter); }
};
using AudioConverterPtr = std::unique_ptr<OpaqueAudioConverter, AudioConverterCloser>;

Result<ExtAudioFilePtr> openFile(const std::filesystem::path& path) {
    const std::string native = path.string();
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, reinterpret_cast<const UInt8*>(native.c_str()),
        static_cast<CFIndex>(native.size()), false);
    if (!url) return makeError(ErrorCode::invalidArgument, native + ": invalid path");
    ExtAudioFileRef file = nullptr;
    const OSStatus status = ExtAudioFileOpenURL(url, &file);
    CFRelease(url);
    if (status != noErr) {
        std::error_code ec;
        if (!std::filesystem::exists(path, ec))
            return makeError(ErrorCode::notFound, native + ": no such file");
        return coreAudioError(status, ErrorCode::unsupported, native + ": cannot open as audio");
    }
    return ExtAudioFilePtr(file);
}

// Reads the whole file at its own rate straight into the builder.
Result<int64_t> readDirect(ExtAudioFileRef file, AudioAssetBuilder& builder, const std::string& name) {
    BufferList buffers(builder.channels());
    int64_t written = 0;
    for (;;) {
        // Estimated lengths can be short (VBR MP3), so keep reading until the file says EOF.
        if (builder.capacity() - written < kChunkFrames) {
            if (Result<void> grown = builder.reserve(written + kChunkFrames); !grown) return grown.error();
        }
        UInt32 frames = kChunkFrames;
        AudioBufferList* list = buffers.point([&](uint32_t c) { return builder.channel(c) + written; }, frames);
        if (OSStatus s = ExtAudioFileRead(file, &frames, list); s != noErr)
            return coreAudioError(s, ErrorCode::io, name + ": decode failed");
        if (frames == 0) return written;
        written += frames;
    }
}

// AudioConverter pulls file frames through this.
struct ConverterInput {
    ExtAudioFileRef file;
    std::vector<std::vector<float>> scratch; // one chunk per channel
    BufferList fileBuffers;
    int64_t framesRead = 0;
    OSStatus readError = noErr;
    bool ended = false;
};

OSStatus pullFromFile(AudioConverterRef, UInt32* ioPackets, AudioBufferList* ioData,
                      AudioStreamPacketDescription**, void* userData) {
    auto* in = static_cast<ConverterInput*>(userData);
    UInt32 frames = in->ended ? 0 : std::min<UInt32>(*ioPackets, kChunkFrames);
    if (frames > 0) {
        AudioBufferList* list = in->fileBuffers.point([&](uint32_t c) { return in->scratch[c].data(); }, frames);
        if (OSStatus s = ExtAudioFileRead(in->file, &frames, list); s != noErr) {
            in->readError = s;
            *ioPackets = 0;
            return s;
        }
    }
    // Zero frames with noErr is end of stream: the converter then flushes its filter tail.
    in->ended = frames == 0;
    in->framesRead += frames;
    for (UInt32 c = 0; c < ioData->mNumberBuffers; ++c) {
        ioData->mBuffers[c].mData = in->scratch[c].data();
        ioData->mBuffers[c].mDataByteSize = frames * sizeof(float);
    }
    *ioPackets = frames;
    return noErr;
}

Result<AudioConverterPtr> makeResampler(double fromRate, double toRate, uint32_t channels) {
    const AudioStreamBasicDescription in = floatFormat(fromRate, channels);
    const AudioStreamBasicDescription out = floatFormat(toRate, channels);
    AudioConverterRef converter = nullptr;
    if (OSStatus s = AudioConverterNew(&in, &out, &converter); s != noErr)
        return coreAudioError(s, ErrorCode::unsupported, "cannot create sample rate converter");
    AudioConverterPtr owned(converter);

    // IO-031: Mastering algorithm at Max quality. Normal priming assumes silence before the
    // first frame, so the output has no leading delay and lines up with the input sample for
    // sample; the tail comes out when the input ends.
    const UInt32 complexity = kAudioConverterSampleRateConverterComplexity_Mastering;
    const UInt32 quality = kAudioConverterQuality_Max;
    const UInt32 prime = kConverterPrimeMethod_Normal;
    const std::pair<AudioConverterPropertyID, UInt32> settings[] = {
        {kAudioConverterSampleRateConverterComplexity, complexity},
        {kAudioConverterSampleRateConverterQuality, quality},
        {kAudioConverterPrimeMethod, prime},
    };
    for (const auto& [property, value] : settings) {
        if (OSStatus s = AudioConverterSetProperty(converter, property, sizeof(value), &value); s != noErr)
            return coreAudioError(s, ErrorCode::unsupported, "cannot configure sample rate converter");
    }
    return owned;
}

// Streams the file through the resampler into the builder. Returns the output frame count.
Result<int64_t> readResampled(ExtAudioFileRef file, double fileRate, double sessionRate,
                              AudioAssetBuilder& builder, int64_t& framesRead, const std::string& name) {
    const uint32_t channels = builder.channels();
    Result<AudioConverterPtr> converter = makeResampler(fileRate, sessionRate, channels);
    if (!converter) return converter.error();

    ConverterInput input{file, std::vector<std::vector<float>>(channels, std::vector<float>(kChunkFrames)),
                         BufferList(channels)};
    BufferList outBuffers(channels);
    int64_t written = 0;
    for (;;) {
        if (builder.capacity() - written < kChunkFrames) {
            if (Result<void> grown = builder.reserve(written + kChunkFrames); !grown) return grown.error();
        }
        UInt32 frames = kChunkFrames;
        AudioBufferList* list = outBuffers.point([&](uint32_t c) { return builder.channel(c) + written; }, frames);
        const OSStatus s = AudioConverterFillComplexBuffer(converter->get(), pullFromFile, &input, &frames, list, nullptr);
        if (input.readError != noErr)
            return coreAudioError(input.readError, ErrorCode::io, name + ": decode failed");
        if (s != noErr) return coreAudioError(s, ErrorCode::internal, name + ": resampling failed");
        if (frames == 0) break;
        written += frames;
    }
    framesRead = input.framesRead;

    // The converter's flush can overshoot or undershoot by a few frames. The asset is exactly the
    // input duration at the new rate, so lengths are predictable (and IO-033 reconversions agree).
    const int64_t expected = std::llround(static_cast<double>(framesRead) * sessionRate / fileRate);
    if (written < expected) {
        if (Result<void> grown = builder.reserve(expected); !grown) return grown.error();
        for (uint32_t c = 0; c < channels; ++c)
            std::fill(builder.channel(c) + written, builder.channel(c) + expected, 0.0f);
    }
    return expected;
}

// IO-034: reuse a current cache file, or compute the peaks and (re)write it.
void ensurePeaks(const AudioLoadRequest& request, LoadedAudio& loaded) {
    const AudioAsset& asset = *loaded.asset;
    const std::filesystem::path file = PeakMipmap::cachePath(request.peakCacheDir, asset.assetID);
    if (Result<PeakMipmap> cached = PeakMipmap::read(file); cached && cached->isCurrentFor(asset)) {
        loaded.peaks = std::make_shared<const PeakMipmap>(std::move(cached).value());
        loaded.peaksFromCache = true;
        return;
    }
    auto peaks = std::make_shared<const PeakMipmap>(PeakMipmap::compute(asset));
    // The cache is an optimization: a read-only project still loads, with in-memory peaks.
    if (Result<void> written = peaks->write(file); !written)
        os_log_error(ioLog(), "peak cache not written: %{public}s", written.error().message.c_str());
    loaded.peaks = std::move(peaks);
}

} // namespace

Result<LoadedAudio> AudioFileLoader::load(const AudioLoadRequest& request) {
    const std::string name = request.file.string();
    if (!(request.sessionRate > 0 && request.sessionRate <= kMaxSampleRate))
        return makeError(ErrorCode::invalidArgument, "session rate out of range");
    if (!request.retire.fn) return makeError(ErrorCode::invalidArgument, "missing retire hook");

    Result<ExtAudioFilePtr> opened = openFile(request.file);
    if (!opened) return opened.error();
    ExtAudioFileRef file = opened->get();

    AudioStreamBasicDescription fileFormat{};
    UInt32 size = sizeof(fileFormat);
    if (OSStatus s = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &fileFormat); s != noErr)
        return coreAudioError(s, ErrorCode::unsupported, name + ": no data format");
    SInt64 estimatedFrames = 0;
    size = sizeof(estimatedFrames);
    if (OSStatus s = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &estimatedFrames); s != noErr)
        return coreAudioError(s, ErrorCode::unsupported, name + ": unknown length");

    const double fileRate = fileFormat.mSampleRate;
    const uint32_t channels = fileFormat.mChannelsPerFrame;
    if (!(fileRate > 0 && fileRate <= kMaxSampleRate) || channels == 0)
        return makeError(ErrorCode::unsupported, name + ": unsupported sample rate or channel count");

    // Decode to the asset layout at the file's own rate; resampling, if any, is ours (IO-031).
    const AudioStreamBasicDescription client = floatFormat(fileRate, channels);
    if (OSStatus s = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client); s != noErr)
        return coreAudioError(s, ErrorCode::unsupported, name + ": cannot decode to float");

    const bool resample = fileRate != request.sessionRate;
    const double ratio = request.sessionRate / fileRate;
    const int64_t capacity = std::max<int64_t>(estimatedFrames, 0);
    Result<AudioAssetBuilder> builder = AudioAssetBuilder::make(
        channels, resample ? static_cast<int64_t>(std::ceil(static_cast<double>(capacity) * ratio)) + 1 : capacity);
    if (!builder) return builder.error();

    LoadedAudio loaded;
    loaded.fileSampleRate = fileRate;
    loaded.resampled = resample;
    Result<int64_t> frames = resample
        ? readResampled(file, fileRate, request.sessionRate, *builder, loaded.fileFrames, name)
        : readDirect(file, *builder, name);
    if (!frames) return frames.error();
    if (!resample) loaded.fileFrames = *frames;

    Result<AudioAssetRef> asset = builder->finish(request.assetID, request.sessionRate, *frames, request.retire);
    if (!asset) return asset.error();
    loaded.asset = std::move(asset).value();

    if (!request.peakCacheDir.empty()) ensurePeaks(request, loaded);
    return loaded;
}

// MARK: daw.loader thread

AudioFileLoader::AudioFileLoader() : thread_([this] { run(); }) {}

AudioFileLoader::~AudioFileLoader() {
    {
        std::lock_guard lock(mutex_);
        stopping_ = true;
        queue_.clear();
    }
    wake_.notify_one();
    idle_.notify_all();
    thread_.join();
}

void AudioFileLoader::submit(AudioLoadRequest request, Completion done) {
    {
        std::lock_guard lock(mutex_);
        queue_.push_back(Job{std::move(request), std::move(done)});
    }
    wake_.notify_one();
}

void AudioFileLoader::waitUntilIdle() {
    std::unique_lock lock(mutex_);
    idle_.wait(lock, [this] { return stopping_ || (queue_.empty() && !busy_); });
}

void AudioFileLoader::run() {
    pthread_setname_np("daw.loader"); // 00-conventions §3
    std::unique_lock lock(mutex_);
    for (;;) {
        wake_.wait(lock, [this] { return stopping_ || !queue_.empty(); });
        if (stopping_) return;
        Job job = std::move(queue_.front());
        queue_.pop_front();
        busy_ = true;
        lock.unlock();

        Result<LoadedAudio> result = load(job.request);
        if (job.done) job.done(std::move(result));

        lock.lock();
        busy_ = false;
        if (queue_.empty()) idle_.notify_all();
    }
}

} // namespace daw
