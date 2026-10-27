#include "io/AudioImporter.h"

#include "io/CoreAudioError.h"

#include <AudioToolbox/AudioToolbox.h>
#include <unistd.h>

#include <cerrno>
#include <string>
#include <system_error>

namespace daw {

namespace {

namespace fs = std::filesystem;

// Rejects files AudioToolbox can't open, before anything is copied.
Result<void> probeAudio(const fs::path& path) {
    const std::string native = path.string();
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, reinterpret_cast<const UInt8*>(native.c_str()),
        static_cast<CFIndex>(native.size()), false);
    if (!url) return makeError(ErrorCode::invalidArgument, native + ": invalid path");
    ExtAudioFileRef file = nullptr;
    const OSStatus status = ExtAudioFileOpenURL(url, &file);
    CFRelease(url);
    if (status != noErr) return coreAudioError(status, ErrorCode::unsupported, native + ": not a readable audio file");
    ExtAudioFileDispose(file);
    return {};
}

bool isInside(const fs::path& file, const fs::path& dir) {
    const fs::path rel = file.lexically_relative(dir);
    return !rel.empty() && *rel.begin() != ".." && rel.is_relative();
}

} // namespace

Result<ImportedAudioFile> AudioImporter::importFile(const fs::path& source, const fs::path& projectDir,
                                                     ImportMode mode) {
    std::error_code ec;
    if (!fs::is_regular_file(source, ec))
        return makeError(ErrorCode::notFound, source.string() + ": no such file");
    const fs::path original = fs::weakly_canonical(fs::absolute(source, ec), ec);
    if (ec) return makeError(ErrorCode::io, source.string() + ": " + ec.message());
    if (Result<void> probed = probeAudio(original); !probed) return probed.error();

    const fs::path project = fs::weakly_canonical(fs::absolute(projectDir, ec), ec);
    if (ec) return makeError(ErrorCode::io, projectDir.string() + ": " + ec.message());
    const fs::path audioDir = audioDirectory(project);

    if (mode == ImportMode::reference || isInside(original, audioDir)) {
        ImportedAudioFile result{original, {}, false};
        if (isInside(original, project)) result.projectRelativePath = original.lexically_relative(project);
        return result;
    }

    fs::create_directories(audioDir, ec);
    if (ec) return makeError(ErrorCode::io, audioDir.string() + ": " + ec.message());

    // Copy under a temporary name, then link it to a free final name. link() fails if the name
    // exists, so a concurrent import can't take the same name, and nothing is ever overwritten.
    const fs::path tmp = audioDir / (".import-" + std::to_string(::getpid()) + "-" + original.filename().string());
    fs::copy_file(original, tmp, fs::copy_options::overwrite_existing, ec);
    if (ec) {
        std::error_code ignored;
        fs::remove(tmp, ignored);
        return makeError(ErrorCode::io, original.string() + ": copy failed: " + ec.message());
    }

    const std::string stem = original.stem().string();
    const std::string ext = original.extension().string();
    for (int n = 1; n < 10'000; ++n) {
        const fs::path target = audioDir / (n == 1 ? stem + ext : stem + " " + std::to_string(n) + ext);
        if (::link(tmp.c_str(), target.c_str()) == 0) {
            fs::remove(tmp, ec);
            return ImportedAudioFile{target, target.lexically_relative(project), true};
        }
        if (errno != EEXIST) break;
    }
    const std::string reason = std::generic_category().message(errno);
    fs::remove(tmp, ec);
    return makeError(ErrorCode::io, audioDir.string() + ": cannot name the copy: " + reason);
}

} // namespace daw
