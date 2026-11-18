#pragma once
// IO-035: writes non-interleaved float32 audio to a file: 32-bit float CAF for recordings (09),
// WAV/AIFF at 16/24-bit integer or 32-bit float for exports (OfflineDriver, IO-010). CAF also
// takes the integer formats; it costs nothing and keeps the format table uniform.
//
// Integer output is quantized here, not by ExtAudioFile's converter, so rounding, clipping and
// the optional TPDF dither are ours and deterministic (IO-011): round to nearest after adding
// the dither, clamp to the integer range. ExtAudioFile then only interleaves into the file's
// layout (and byte-swaps for AIFF). Float output is written unchanged, without clipping.
//
// Threads: non-RT only (CONV-RT-03: no file I/O on the audio thread). The recorder calls it from
// daw.diskwrite, the offline driver from its render thread between Engine::render calls. One
// writer is used by one thread at a time.
//
// Buffering (DW-279, T-092): write() interleaves into a buffer of kBufferFrames frames and hands
// it to ExtAudioFileWrite only when it is full, and close() (or the destructor) writes the rest
// before finalizing the header. So a file is complete only after close(); the bytes are the same
// as with one ExtAudioFileWrite per block. A failed file write is reported by the write() or
// close() that triggered it.

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <vector>

#include "core/AudioBufferView.h"
#include "core/Result.h"
#include "io/TpdfDither.h"

struct OpaqueExtAudioFile;  // ExtAudioFileRef; keeps <AudioToolbox> out of this header

namespace daw {

enum class AudioFileType : uint8_t {
    caf,   // .caf
    wav,   // .wav (WAVE_FORMAT_EXTENSIBLE where needed)
    aiff,  // .aif: AIFF for integers, AIFF-C ('fl32') for float32
};

enum class AudioSampleFormat : uint8_t { int16, int24, float32 };

struct AudioFileFormat {
    AudioFileType type = AudioFileType::wav;
    AudioSampleFormat sample = AudioSampleFormat::float32;
    double sampleRate = 48000.0;
    uint32_t numChannels = 2;
    // IO-035: TPDF dither before quantizing to int16/int24. Ignored for float32, so an export
    // dialog can keep the setting while the format changes.
    bool dither = false;
    uint64_t ditherSeed = kDefaultDitherSeed;

    // IO-035, 09: what recordings are written as.
    static AudioFileFormat recording(double sampleRate, uint32_t numChannels) {
        return {AudioFileType::caf, AudioSampleFormat::float32, sampleRate, numChannels, false,
                kDefaultDitherSeed};
    }
};

inline constexpr uint32_t kMaxFileChannels = 32;

class AudioFileWriter {
public:
    // Non-RT. Creates (or replaces) `file`. Fails with invalidArgument for a bad format (rate
    // outside 1 kHz…768 kHz, 0 or more than kMaxFileChannels channels) and with io/unsupported
    // when AudioToolbox can't create the file.
    static Result<std::unique_ptr<AudioFileWriter>> create(const std::filesystem::path& file,
                                                           const AudioFileFormat& format);

    // Closes the file if close() wasn't called; errors are lost then.
    ~AudioFileWriter();
    AudioFileWriter(const AudioFileWriter&) = delete;
    AudioFileWriter& operator=(const AudioFileWriter&) = delete;

    // Appends `numFrames` frames; channels[c] holds channel c (format().numChannels of them).
    // They reach the file when the buffer fills or at close() (DW-279).
    Result<void> write(const float* const* channels, uint32_t numFrames);
    // The view must have exactly format().numChannels channels.
    Result<void> write(const AudioBufferView& view);

    // Writes the buffered frames, finalizes the header and closes the file. Later writes fail; a
    // second close succeeds.
    Result<void> close();

    const AudioFileFormat& format() const { return format_; }
    const std::filesystem::path& path() const { return path_; }
    // Frames given to write() so far (the file holds them all once close() has succeeded).
    int64_t framesWritten() const { return framesWritten_; }
    // Integer formats: samples clamped to full scale so far (after dither).
    uint64_t clippedSamples() const { return clipped_; }

    // DW-279: frames buffered per ExtAudioFileWrite (one `pwrite` each, so 128-frame blocks
    // spent 3–7 % of an export in it).
    static constexpr uint32_t kBufferFrames = 65536;

private:
    AudioFileWriter(std::filesystem::path path, const AudioFileFormat& format, OpaqueExtAudioFile* file);
    // Hands the buffered frames to ExtAudioFileWrite; they are dropped from the buffer either way.
    Result<void> flush();

    std::filesystem::path path_;
    AudioFileFormat format_;
    OpaqueExtAudioFile* file_;  // null once closed
    TpdfDither dither_;
    std::vector<std::byte> interleaved_;  // kBufferFrames interleaved frames, from the first write
    uint32_t pending_ = 0;                // frames in interleaved_ not yet in the file
    int64_t framesWritten_ = 0;
    uint64_t clipped_ = 0;
};

} // namespace daw
