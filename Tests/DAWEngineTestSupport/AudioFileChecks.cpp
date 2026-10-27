// T-010: AudioFileLoader (IO-031), PeakMipmap (IO-034) and AudioImporter (IO-030). Test files
// are synthesized and written at test time (TestAudio.h), in every format AudioToolbox encodes.

#include "AudioFileChecks.h"

#include "TestAudio.h"
#include "io/AudioFileLoader.h"
#include "io/AudioImporter.h"
#include "io/PeakMipmap.h"

#include <pthread.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <limits>
#include <mutex>
#include <string>
#include <vector>

namespace daw::testing {

namespace fs = std::filesystem;

namespace {

std::string fileBytes(const fs::path& file) {
    std::ifstream in(file, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
}

void writeBytes(const fs::path& file, const std::string& bytes) {
    std::ofstream(file, std::ios::binary | std::ios::trunc).write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
}

Result<LoadedAudio> loadFile(const fs::path& file, double sessionRate, uint64_t id = 1,
                             const fs::path& cacheDir = {}) {
    AudioLoadRequest request;
    request.assetID = id;
    request.file = file;
    request.sessionRate = sessionRate;
    request.peakCacheDir = cacheDir;
    return AudioFileLoader::load(request);
}

// Writes a float32 CAF of `asset`, so a loaded asset can be loaded again (the round trip).
Result<void> writeAsset(const fs::path& file, const AudioAsset& asset) {
    return writeTestFile(file, "caf-f32", asset.sampleRate, copyChannels(asset));
}

} // namespace

// MARK: IO-031

double resampleRoundTripResidualDb() {
    constexpr double kInf = std::numeric_limits<double>::infinity();
    TempDir dir;
    const int64_t frames = 96'011; // ~2 s, not a multiple of any chunk size
    const Channels original = synthTones(48000, frames, 2);
    const fs::path source = dir.path() / "source-48k.wav";
    if (!writeTestFile(source, "wav-f32", 48000, original)) return kInf;

    Result<LoadedAudio> down = loadFile(source, 44100);
    if (!down || !down->resampled || down->asset->frames != framesAtRate(frames, 48000, 44100)) return kInf;
    const fs::path mid = dir.path() / "mid-44k.caf";
    if (!writeAsset(mid, *down->asset)) return kInf;

    Result<LoadedAudio> up = loadFile(mid, 48000);
    if (!up || !up->resampled || up->asset->frames != frames || up->asset->sampleRate != 48000) return kInf;
    return residualDb(*up->asset, original);
}

CheckResult decodeFormat(const char* formatName) {
    CheckResult checks;
    const TestFormat* format = findTestFormat(formatName);
    DAW_CHECK(format != nullptr);
    if (!format) return checks;

    TempDir dir;
    const int64_t frames = 66'157;
    const double duration = frames / 44100.0;
    auto tones = [&](double rate, int64_t n) { return synthTones(rate, n, 2, duration, format->maxFrequency); };
    const fs::path file = dir.path() / ("tones" + format->extension);
    const Result<void> written = writeTestFile(file, format->name, 44100, tones(44100, frames));
    DAW_CHECK(written.ok());
    if (!written) {
        checks.firstFailure += " (" + written.error().message + ")";
        return checks;
    }

    // At the file's rate: decoded as-is, the exact length (lossy codecs' priming and padding
    // are trimmed by ExtAudioFile), and as close to the source as the encoding allows.
    Result<LoadedAudio> same = loadFile(file, 44100);
    DAW_CHECK(same.ok());
    if (same) {
        DAW_CHECK(!same->resampled && same->fileSampleRate == 44100 && same->fileFrames == frames);
        const AudioAsset& a = *same->asset;
        DAW_CHECK(a.channels == 2 && a.frames == frames && a.sampleRate == 44100);
        DAW_CHECK(residualDb(a, tones(44100, frames)) < format->maxResidualDb);
    }

    // At another session rate: resampled to the signal sampled at 48 kHz (D-27).
    Result<LoadedAudio> resampled = loadFile(file, 48000);
    DAW_CHECK(resampled.ok());
    if (resampled) {
        const int64_t expected = framesAtRate(frames, 44100, 48000);
        DAW_CHECK(resampled->resampled && resampled->fileFrames == frames);
        const AudioAsset& a = *resampled->asset;
        DAW_CHECK(a.channels == 2 && a.frames == expected && a.sampleRate == 48000);
        DAW_CHECK(residualDb(a, tones(48000, expected)) < std::max(format->maxResidualDb, -80.0));
    }
    return checks;
}

CheckResult decodeChannelCounts() {
    CheckResult checks;
    TempDir dir;
    for (uint32_t channels : {1u, 6u}) {
        const int64_t frames = 20'000;
        const fs::path file = dir.path() / ("ch" + std::to_string(channels) + ".caf");
        DAW_CHECK(writeTestFile(file, "caf-f32", 96000, synthTones(96000, frames, channels)).ok());
        for (double rate : {96000.0, 44100.0}) {
            Result<LoadedAudio> loaded = loadFile(file, rate);
            DAW_CHECK(loaded.ok());
            if (!loaded) continue;
            const int64_t expected = framesAtRate(frames, 96000, rate);
            DAW_CHECK(loaded->asset->channels == channels && loaded->asset->frames == expected);
            DAW_CHECK(residualDb(*loaded->asset, synthTones(rate, expected, channels, frames / 96000.0)) < -80);
        }
    }
    // An empty file loads as an empty asset, resampled or not.
    const fs::path empty = dir.path() / "empty.wav";
    DAW_CHECK(writeTestFile(empty, "wav-i16", 44100, Channels(2)).ok());
    for (double rate : {44100.0, 48000.0}) {
        Result<LoadedAudio> loaded = loadFile(empty, rate);
        DAW_CHECK(loaded.ok() && loaded->asset->frames == 0 && loaded->asset->channels == 2);
    }
    return checks;
}

CheckResult loadErrors() {
    CheckResult checks;
    TempDir dir;
    Result<LoadedAudio> missing = loadFile(dir.path() / "nope.wav", 48000);
    DAW_CHECK(!missing.ok() && missing.error().code == ErrorCode::notFound);

    const fs::path text = dir.path() / "notes.wav";
    writeBytes(text, "this is not audio, whatever the extension says\n");
    Result<LoadedAudio> notAudio = loadFile(text, 48000);
    DAW_CHECK(!notAudio.ok() && notAudio.error().code == ErrorCode::unsupported);

    const fs::path good = dir.path() / "good.wav";
    DAW_CHECK(writeTestFile(good, "wav-i16", 48000, synthTones(48000, 100, 1)).ok());
    DAW_CHECK(loadFile(good, 0).error().code == ErrorCode::invalidArgument);
    DAW_CHECK(loadFile(good, -48000).error().code == ErrorCode::invalidArgument);
    AudioLoadRequest noHook{1, good, 48000, {}, RetireHook{}};
    DAW_CHECK(AudioFileLoader::load(noHook).error().code == ErrorCode::invalidArgument);
    return checks;
}

CheckResult loaderThread() {
    CheckResult checks;
    TempDir dir;
    const fs::path file = dir.path() / "a.wav";
    DAW_CHECK(writeTestFile(file, "wav-f32", 44100, synthTones(44100, 4410, 2)).ok());

    std::mutex mutex;
    std::vector<uint64_t> order;
    std::vector<std::string> threadNames;
    std::vector<bool> succeeded;
    {
        AudioFileLoader loader;
        for (uint64_t id = 1; id <= 4; ++id) {
            AudioLoadRequest request;
            request.assetID = id;
            request.file = id == 3 ? dir.path() / "missing.wav" : file;
            request.sessionRate = 48000;
            loader.submit(std::move(request), [&, id](Result<LoadedAudio> result) {
                char name[64] = {};
                pthread_getname_np(pthread_self(), name, sizeof(name));
                std::lock_guard lock(mutex);
                order.push_back(id);
                threadNames.emplace_back(name);
                succeeded.push_back(result.ok() && result->asset->assetID == id && result->asset->frames == 4800);
            });
        }
        loader.waitUntilIdle();
        std::lock_guard lock(mutex);
        // In submission order, on daw.loader (00-conventions §3); a failed request reports its
        // error and doesn't stop the queue.
        DAW_CHECK((order == std::vector<uint64_t>{1, 2, 3, 4}));
        DAW_CHECK(std::all_of(threadNames.begin(), threadNames.end(), [](const std::string& n) { return n == "daw.loader"; }));
        DAW_CHECK((succeeded == std::vector<bool>{true, true, false, true}));
    }
    {
        // Destroying a loader with work queued neither hangs nor runs dropped completions late.
        int calls = 0;
        {
            AudioFileLoader loader;
            for (int i = 0; i < 50; ++i) {
                AudioLoadRequest request{static_cast<uint64_t>(i), file, 48000, {}, RetireHook::immediate()};
                loader.submit(std::move(request), [&calls](Result<LoadedAudio>) { ++calls; });
            }
        }
        DAW_CHECK(calls <= 50);
    }
    return checks;
}

// MARK: IO-034

CheckResult peaksMatchBruteForce() {
    CheckResult checks;
    const int64_t frames = 100'003; // partial last block at every level
    Channels channels = synthTones(48000, frames, 2);
    // A few isolated extremes, so a block that misses a sample shows.
    channels[0][77'777] = 0.99f;
    channels[1][16'384] = -0.97f;
    channels[1][frames - 1] = 0.95f;
    Result<AudioAssetBuilder> builder = AudioAssetBuilder::make(2, frames);
    DAW_CHECK(builder.ok());
    if (!builder) return checks;
    for (uint32_t c = 0; c < 2; ++c) std::copy(channels[c].begin(), channels[c].end(), builder->channel(c));
    AudioAssetRef asset = builder->finish(5, 48000, frames, RetireHook::immediate()).value();

    const PeakMipmap mip = PeakMipmap::compute(*asset);
    DAW_CHECK(mip.assetID() == 5 && mip.sampleRate() == 48000 && mip.channels() == 2 && mip.frames() == frames);
    const uint32_t expectedSizes[] = {256, 1024, 4096, 16384};
    for (size_t l = 0; l < 4; ++l) {
        const PeakMipmap::Level& level = mip.levels()[l];
        DAW_CHECK(level.blockSize == expectedSizes[l]);
        DAW_CHECK(level.blockCount == (frames + level.blockSize - 1) / level.blockSize);
        DAW_CHECK(static_cast<int64_t>(level.peaks.size()) == level.blockCount * 2);
        for (uint32_t c = 0; c < 2; ++c) {
            for (int64_t b = 0; b < level.blockCount; ++b) {
                const auto first = channels[c].begin() + b * level.blockSize;
                const auto last = channels[c].begin() + std::min<int64_t>((b + 1) * level.blockSize, frames);
                const auto [lo, hi] = std::minmax_element(first, last);
                DAW_CHECK(level.channel(c)[b].min == *lo && level.channel(c)[b].max == *hi);
            }
        }
    }
    DAW_CHECK(mip.levels()[3].channel(0)[77'777 / 16384].max == 0.99f);
    DAW_CHECK(mip.levels()[0].channel(1)[16'384 / 256].min == -0.97f);
    return checks;
}

CheckResult peakFileFormat() {
    CheckResult checks;
    TempDir dir;
    const int64_t frames = 5000;
    Result<AudioAssetBuilder> builder = AudioAssetBuilder::make(3, frames);
    DAW_CHECK(builder.ok());
    if (!builder) return checks;
    for (uint32_t c = 0; c < 3; ++c)
        for (int64_t i = 0; i < frames; ++i) builder->channel(c)[i] = std::sin(0.01f * static_cast<float>(i) * static_cast<float>(c + 1));
    AudioAssetRef asset = builder->finish(0x1122334455667788ULL, 44100, frames, RetireHook::immediate()).value();
    const PeakMipmap mip = PeakMipmap::compute(*asset);

    const fs::path file = PeakMipmap::cachePath(dir.path() / "Cache", asset->assetID);
    DAW_CHECK(file.filename() == "1234605616436508552.peaks");
    DAW_CHECK(mip.write(file).ok()); // creates Cache/
    Result<PeakMipmap> read = PeakMipmap::read(file);
    DAW_CHECK(read.ok() && *read == mip && read->isCurrentFor(*asset));

    // The byte layout documented in PeakMipmap.h, which the UI (12) reads independently.
    const std::string bytes = fileBytes(file);
    auto u32 = [&](size_t at) { uint32_t v; std::memcpy(&v, bytes.data() + at, 4); return v; };
    auto u64 = [&](size_t at) { uint64_t v; std::memcpy(&v, bytes.data() + at, 8); return v; };
    auto f32 = [&](size_t at) { float v; std::memcpy(&v, bytes.data() + at, 4); return v; };
    double rate;
    std::memcpy(&rate, bytes.data() + 24, 8);
    DAW_CHECK(bytes.compare(0, 8, "DAWPEAKS") == 0);
    DAW_CHECK(u32(8) == 1 && u32(12) == 3 && u64(16) == 0x1122334455667788ULL && rate == 44100);
    DAW_CHECK(u64(32) == 5000 && u32(40) == 4 && u32(44) == 0);
    const uint64_t counts[] = {20, 5, 2, 1}; // ceil(5000 / blockSize)
    size_t expectedSize = 48 + 16 * 4;
    for (size_t l = 0; l < 4; ++l) {
        DAW_CHECK(u32(48 + 16 * l) == PeakMipmap::kBlockSizes[l] && u32(52 + 16 * l) == 0);
        DAW_CHECK(u64(56 + 16 * l) == counts[l]);
        expectedSize += 3 * counts[l] * 8;
    }
    DAW_CHECK(bytes.size() == expectedSize);
    // Level 1 (1024), channel 2, block 3: dataStart(1) + (2 × 5 + 3) × 8.
    const size_t at = 48 + 16 * 4 + 3 * 20 * 8 + (2 * 5 + 3) * 8;
    DAW_CHECK(f32(at) == mip.levels()[1].channel(2)[3].min && f32(at + 4) == mip.levels()[1].channel(2)[3].max);

    // A zero-length asset still gets a valid file with four empty levels.
    Result<AudioAssetBuilder> none = AudioAssetBuilder::make(1, 0);
    AudioAssetRef empty = none->finish(9, 48000, 0, RetireHook::immediate()).value();
    const PeakMipmap emptyMip = PeakMipmap::compute(*empty);
    const fs::path emptyFile = PeakMipmap::cachePath(dir.path(), 9);
    DAW_CHECK(emptyMip.write(emptyFile).ok());
    Result<PeakMipmap> emptyRead = PeakMipmap::read(emptyFile);
    DAW_CHECK(emptyRead.ok() && *emptyRead == emptyMip && emptyRead->levels()[0].blockCount == 0);
    DAW_CHECK(fs::file_size(emptyFile) == 48 + 16 * 4);
    return checks;
}

CheckResult peakFileRejectsCorrupt() {
    CheckResult checks;
    TempDir dir;
    Result<AudioAssetBuilder> builder = AudioAssetBuilder::make(1, 3000);
    std::fill(builder->channel(0), builder->channel(0) + 3000, 0.25f);
    AudioAssetRef asset = builder->finish(3, 48000, 3000, RetireHook::immediate()).value();
    const fs::path file = dir.path() / "3.peaks";
    DAW_CHECK(PeakMipmap::compute(*asset).write(file).ok());
    const std::string good = fileBytes(file);

    DAW_CHECK(PeakMipmap::read(dir.path() / "absent.peaks").error().code == ErrorCode::notFound);
    auto rejects = [&](std::string bytes) {
        writeBytes(file, bytes);
        return !PeakMipmap::read(file).ok();
    };
    std::string bad = good;
    bad[0] = 'X';
    DAW_CHECK(rejects(bad)); // magic
    bad = good;
    bad[8] = 2;
    DAW_CHECK(rejects(bad)); // version
    bad = good;
    bad[49] = 0; // 256 → 0
    DAW_CHECK(rejects(bad)); // block size
    bad = good;
    bad[33] = static_cast<char>(0xFF); // 3000 → 65464 frames
    DAW_CHECK(rejects(bad)); // frames no longer match the block counts
    DAW_CHECK(rejects(good.substr(0, good.size() - 1)));
    DAW_CHECK(rejects(good + "x"));
    DAW_CHECK(rejects(good.substr(0, 20)));
    DAW_CHECK(!rejects(good));
    return checks;
}

CheckResult loaderPeakCache() {
    CheckResult checks;
    TempDir dir;
    const fs::path project = dir.path() / "Song.dawproj";
    const fs::path cache = AudioImporter::cacheDirectory(project);
    const fs::path file = dir.path() / "loop.wav";
    DAW_CHECK(writeTestFile(file, "wav-i24", 44100, synthTones(44100, 30'000, 2)).ok());

    // First load computes and writes Project/Cache/<assetID>.peaks.
    Result<LoadedAudio> first = loadFile(file, 44100, 42, cache);
    DAW_CHECK(first.ok());
    if (!first) return checks;
    const fs::path peakFile = cache / "42.peaks";
    DAW_CHECK(first->peaks && !first->peaksFromCache && fs::exists(peakFile));
    DAW_CHECK(first->peaks && *first->peaks == PeakMipmap::compute(*first->asset));
    Result<PeakMipmap> onDisk = PeakMipmap::read(peakFile);
    DAW_CHECK(onDisk.ok() && first->peaks && *onDisk == *first->peaks);

    // Loading again reuses the current cache.
    Result<LoadedAudio> again = loadFile(file, 44100, 42, cache);
    DAW_CHECK(again.ok() && again->peaksFromCache && again->peaks && *again->peaks == *first->peaks);

    // At another session rate the cache is stale: recomputed and rewritten for the new asset.
    Result<LoadedAudio> other = loadFile(file, 48000, 42, cache);
    DAW_CHECK(other.ok() && !other->peaksFromCache);
    Result<PeakMipmap> rewritten = PeakMipmap::read(peakFile);
    DAW_CHECK(rewritten.ok() && rewritten->sampleRate() == 48000 && rewritten->isCurrentFor(*other->asset));

    // A corrupt cache file is replaced, not trusted.
    writeBytes(peakFile, "garbage");
    Result<LoadedAudio> repaired = loadFile(file, 48000, 42, cache);
    DAW_CHECK(repaired.ok() && !repaired->peaksFromCache && PeakMipmap::read(peakFile).ok());

    // No cache folder requested: no peaks.
    Result<LoadedAudio> none = loadFile(file, 44100, 43);
    DAW_CHECK(none.ok() && !none->peaks && !fs::exists(cache / "43.peaks"));
    return checks;
}

// MARK: IO-030

CheckResult importCopiesUnchanged() {
    CheckResult checks;
    TempDir dir;
    const fs::path source = dir.path() / "incoming" / "Kick 01.aiff";
    fs::create_directories(source.parent_path());
    DAW_CHECK(writeTestFile(source, "aiff-i24", 96000, synthTones(96000, 9600, 2)).ok());
    const std::string original = fileBytes(source);
    const fs::path project = dir.path() / "Song.dawproj";

    Result<ImportedAudioFile> imported = AudioImporter::importFile(source, project); // default: copy
    DAW_CHECK(imported.ok());
    if (!imported) return checks;
    DAW_CHECK(imported->copied);
    DAW_CHECK(imported->path == fs::weakly_canonical(project) / "Audio" / "Kick 01.aiff");
    DAW_CHECK(imported->projectRelativePath == fs::path("Audio") / "Kick 01.aiff");
    // Unchanged: byte for byte, still at its original rate, and the source is left alone.
    DAW_CHECK(fileBytes(imported->path) == original && fileBytes(source) == original);
    // No temporary files left behind.
    int entries = 0;
    for ([[maybe_unused]] const auto& e : fs::directory_iterator(project / "Audio")) ++entries;
    DAW_CHECK(entries == 1);
    // The copy is what the loader reads.
    Result<LoadedAudio> loaded = loadFile(imported->path, 48000);
    DAW_CHECK(loaded.ok() && loaded->fileSampleRate == 96000 && loaded->asset->frames == 4800);

    // Importing a file that already lives in Project/Audio/ uses it in place.
    Result<ImportedAudioFile> inPlace = AudioImporter::importFile(imported->path, project);
    DAW_CHECK(inPlace.ok() && !inPlace->copied && inPlace->path == imported->path);
    DAW_CHECK(inPlace.ok() && inPlace->projectRelativePath == fs::path("Audio") / "Kick 01.aiff");
    return checks;
}

CheckResult importNameCollision() {
    CheckResult checks;
    TempDir dir;
    const fs::path project = dir.path() / "P";
    const fs::path a = dir.path() / "a" / "take.wav";
    const fs::path b = dir.path() / "b" / "take.wav";
    fs::create_directories(a.parent_path());
    fs::create_directories(b.parent_path());
    DAW_CHECK(writeTestFile(a, "wav-i16", 48000, synthTones(48000, 1000, 1)).ok());
    DAW_CHECK(writeTestFile(b, "wav-i16", 48000, synthTones(48000, 2000, 1)).ok());

    Result<ImportedAudioFile> first = AudioImporter::importFile(a, project);
    Result<ImportedAudioFile> second = AudioImporter::importFile(b, project);
    Result<ImportedAudioFile> third = AudioImporter::importFile(a, project);
    DAW_CHECK(first.ok() && second.ok() && third.ok());
    if (!first || !second || !third) return checks;
    // Never overwritten: each copy keeps its own content under a free name.
    DAW_CHECK(first->path.filename() == "take.wav");
    DAW_CHECK(second->path.filename() == "take 2.wav");
    DAW_CHECK(third->path.filename() == "take 3.wav");
    DAW_CHECK(fileBytes(first->path) == fileBytes(a) && fileBytes(second->path) == fileBytes(b));
    DAW_CHECK(fileBytes(third->path) == fileBytes(a));
    return checks;
}

CheckResult importReference() {
    CheckResult checks;
    TempDir dir;
    const fs::path source = dir.path() / "library" / "pad.caf";
    fs::create_directories(source.parent_path());
    DAW_CHECK(writeTestFile(source, "caf-f32", 44100, synthTones(44100, 1000, 2)).ok());
    const fs::path project = dir.path() / "P";

    Result<ImportedAudioFile> ref = AudioImporter::importFile(source, project, ImportMode::reference);
    DAW_CHECK(ref.ok());
    if (!ref) return checks;
    DAW_CHECK(!ref->copied && ref->path == fs::weakly_canonical(source) && ref->projectRelativePath.empty());
    DAW_CHECK(!fs::exists(project / "Audio"));

    // A referenced file inside the project folder still gets a portable relative path.
    const fs::path inside = project / "Bounces" / "mix.caf";
    fs::create_directories(inside.parent_path());
    fs::copy_file(source, inside);
    Result<ImportedAudioFile> insideRef = AudioImporter::importFile(inside, project, ImportMode::reference);
    DAW_CHECK(insideRef.ok() && insideRef->projectRelativePath == fs::path("Bounces") / "mix.caf");
    return checks;
}

CheckResult importRejectsNonAudio() {
    CheckResult checks;
    TempDir dir;
    const fs::path project = dir.path() / "P";
    const fs::path text = dir.path() / "readme.wav";
    writeBytes(text, "not audio\n");
    Result<ImportedAudioFile> bad = AudioImporter::importFile(text, project);
    DAW_CHECK(!bad.ok() && bad.error().code == ErrorCode::unsupported);
    Result<ImportedAudioFile> missing = AudioImporter::importFile(dir.path() / "gone.wav", project);
    DAW_CHECK(!missing.ok() && missing.error().code == ErrorCode::notFound);
    Result<ImportedAudioFile> folder = AudioImporter::importFile(dir.path(), project);
    DAW_CHECK(!folder.ok());
    // Nothing was created.
    DAW_CHECK(!fs::exists(project));
    return checks;
}

} // namespace daw::testing
