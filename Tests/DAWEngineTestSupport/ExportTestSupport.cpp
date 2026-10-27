#include "ExportTestSupport.h"

#include "io/AudioFileLoader.h"
#include "io/CoreAudioError.h"

#include <AudioToolbox/AudioToolbox.h>

#include <fstream>
#include <iterator>

namespace daw::testing {

const std::vector<ExportFormat>& exportFormats() {
    static const std::vector<ExportFormat> formats{
        {"caf-f32", AudioFileType::caf, AudioSampleFormat::float32, ".caf"},
        {"caf-i16", AudioFileType::caf, AudioSampleFormat::int16, ".caf"},
        {"caf-i24", AudioFileType::caf, AudioSampleFormat::int24, ".caf"},
        {"wav-i16", AudioFileType::wav, AudioSampleFormat::int16, ".wav"},
        {"wav-i24", AudioFileType::wav, AudioSampleFormat::int24, ".wav"},
        {"wav-f32", AudioFileType::wav, AudioSampleFormat::float32, ".wav"},
        {"aiff-i16", AudioFileType::aiff, AudioSampleFormat::int16, ".aif"},
        {"aiff-i24", AudioFileType::aiff, AudioSampleFormat::int24, ".aif"},
        {"aiff-f32", AudioFileType::aiff, AudioSampleFormat::float32, ".aif"},
    };
    return formats;
}

const ExportFormat* findExportFormat(const std::string& name) {
    for (const auto& f : exportFormats())
        if (f.name == name) return &f;
    return nullptr;
}

Result<FileInfo> readFileInfo(const std::filesystem::path& file) {
    const std::string native = file.string();
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, reinterpret_cast<const UInt8*>(native.c_str()), static_cast<CFIndex>(native.size()), false);
    ExtAudioFileRef ext = nullptr;
    OSStatus s = ExtAudioFileOpenURL(url, &ext);
    CFRelease(url);
    if (s != noErr) return coreAudioError(s, ErrorCode::io, native + ": cannot open");

    FileInfo info;
    AudioStreamBasicDescription format{};
    UInt32 size = sizeof(format);
    s = ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileDataFormat, &size, &format);
    SInt64 frames = 0;
    size = sizeof(frames);
    if (s == noErr) s = ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileLengthFrames, &size, &frames);
    AudioFileID audioFile = nullptr;
    size = sizeof(audioFile);
    if (s == noErr) s = ExtAudioFileGetProperty(ext, kExtAudioFileProperty_AudioFile, &size, &audioFile);
    AudioFileTypeID type = 0;
    size = sizeof(type);
    if (s == noErr) s = AudioFileGetProperty(audioFile, kAudioFilePropertyFileFormat, &size, &type);
    ExtAudioFileDispose(ext);
    if (s != noErr) return coreAudioError(s, ErrorCode::io, native + ": cannot read properties");

    info.fileType = type;
    info.formatFlags = format.mFormatFlags;
    info.bitsPerChannel = format.mBitsPerChannel;
    info.channels = format.mChannelsPerFrame;
    info.sampleRate = format.mSampleRate;
    info.frames = frames;
    return info;
}

Result<Channels> readBack(const std::filesystem::path& file, double sampleRate) {
    AudioLoadRequest request;
    request.assetID = 1;
    request.file = file;
    request.sessionRate = sampleRate;
    Result<LoadedAudio> loaded = AudioFileLoader::load(request);
    if (!loaded) return loaded.error();
    if (loaded->resampled) return makeError(ErrorCode::internal, "read back was resampled");
    return copyChannels(*loaded->asset);
}

std::vector<char> fileBytes(const std::filesystem::path& file) {
    std::ifstream in(file, std::ios::binary);
    return {std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
}

} // namespace daw::testing
