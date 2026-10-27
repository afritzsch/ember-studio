#pragma once
// T-009 test helpers (private to DAWEngineTestSupport), shared by AudioFileWriterChecks.cpp and
// OfflineChecks.cpp: reading files back through ExtAudioFile, comparing bytes, and naming the
// export formats.

#include "TestAudio.h"
#include "core/Result.h"
#include "io/AudioFileWriter.h"

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace daw::testing {

// "caf-f32", "wav-i16", … ; ".caf", ".wav", ".aif".
struct ExportFormat {
    std::string name;
    AudioFileType type;
    AudioSampleFormat sample;
    std::string extension;
};
const std::vector<ExportFormat>& exportFormats();
const ExportFormat* findExportFormat(const std::string& name);

// What ExtAudioFile reports about a file on disk.
struct FileInfo {
    uint32_t fileType = 0;       // AudioFileTypeID
    uint32_t formatFlags = 0;    // of the file's data format
    uint32_t bitsPerChannel = 0;
    uint32_t channels = 0;
    double sampleRate = 0;
    int64_t frames = 0;
};
Result<FileInfo> readFileInfo(const std::filesystem::path& file);

// IO-035 round trip: decodes the file at its own rate through ExtAudioFile (AudioFileLoader).
Result<Channels> readBack(const std::filesystem::path& file, double sampleRate);

std::vector<char> fileBytes(const std::filesystem::path& file);

} // namespace daw::testing
