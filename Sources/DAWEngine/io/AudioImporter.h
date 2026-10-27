#pragma once
// IO-030: the engine side of importing an audio file into a project. By default the original is
// copied, byte for byte, into Project/Audio/; as a user option it is referenced where it lies.
// Either way the file is never modified: the loader resamples into RAM (IO-031, D-27) and a
// session-rate change re-reads it (IO-033). Recording the file in the document is the model's
// ImportAsset command (07), which calls this.

#include "core/Result.h"

#include <cstdint>
#include <filesystem>

namespace daw {

enum class ImportMode : uint8_t {
    copy,      // default: copy into Project/Audio/
    reference, // leave the file where it is and point at it
};

struct ImportedAudioFile {
    std::filesystem::path path;         // absolute path the loader should open
    // Path relative to the project folder ("Audio/kick.wav") when the file lives inside it,
    // for portable persistence. Empty for referenced files outside the project.
    std::filesystem::path projectRelativePath;
    bool copied = false;
};

class AudioImporter {
public:
    static std::filesystem::path audioDirectory(const std::filesystem::path& projectDir) {
        return projectDir / "Audio";
    }
    static std::filesystem::path cacheDirectory(const std::filesystem::path& projectDir) {
        return projectDir / "Cache";
    }

    // Non-RT. Fails without side effects if `source` is missing or not readable as audio.
    // Copying never overwrites: a name already taken in Project/Audio/ gets " 2", " 3", … before
    // the extension. A source already inside Project/Audio/ is used in place, not copied again.
    // The copy appears under its final name only once complete.
    static Result<ImportedAudioFile> importFile(const std::filesystem::path& source,
                                                const std::filesystem::path& projectDir,
                                                ImportMode mode = ImportMode::copy);
};

} // namespace daw
