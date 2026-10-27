#pragma once
// IO-031: decodes an audio file into an AudioAsset in RAM at the session rate (D-10, D-27).
//
// Decoding is ExtAudioFile (WAV/AIFF/CAF/MP3/AAC/FLAC, whatever AudioToolbox reads) to float32
// non-interleaved at the file's rate. If that differs from the session rate, an AudioConverter
// resamples the stream as it is read, at Mastering complexity and Max quality, so no second copy
// of the file is ever held. The original file is never modified: a session-rate change re-runs
// load() on it (IO-033, T-056) rather than resampling an already resampled asset.
//
// IO-034: when the request names a cache directory, load() also makes sure
// <cacheDir>/<assetID>.peaks matches the asset, reusing it if current and rewriting it if not.
//
// Threads (00-conventions §3): load() is synchronous and runs on any non-RT thread. The engine
// uses an AudioFileLoader instance, which runs requests one at a time on its own daw.loader
// thread and reports each result through the request's completion, on that thread.

#include "core/Result.h"
#include "io/AudioAsset.h"
#include "io/PeakMipmap.h"

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>

namespace daw {

struct AudioLoadRequest {
    uint64_t assetID = 0;
    std::filesystem::path file;  // the original (Project/Audio/… or a referenced file, IO-030)
    double sessionRate = 0;      // the asset's rate; the file is resampled if it differs
    // IO-034: Project/Cache. Empty skips the peak cache (peaks are then not computed).
    std::filesystem::path peakCacheDir;
    // IO-032: where the asset goes when its last reference is released. Engine-owned assets use
    // a RetireQueue hook; the default frees on the releasing thread.
    RetireHook retire = RetireHook::immediate();
};

struct LoadedAudio {
    AudioAssetRef asset;
    double fileSampleRate = 0;
    int64_t fileFrames = 0;      // length in the file, at fileSampleRate
    bool resampled = false;
    // IO-034: set when the request had a peakCacheDir.
    std::shared_ptr<const PeakMipmap> peaks;
    bool peaksFromCache = false; // true if an existing, current cache file was reused
};

class AudioFileLoader {
public:
    using Completion = std::function<void(Result<LoadedAudio>)>;

    // Non-RT. Decodes (and resamples, and caches peaks) on the calling thread.
    static Result<LoadedAudio> load(const AudioLoadRequest& request);

    // Starts the daw.loader thread.
    AudioFileLoader();
    // Finishes the request in progress, drops queued ones without calling their completions, and
    // joins the thread.
    ~AudioFileLoader();
    AudioFileLoader(const AudioFileLoader&) = delete;
    AudioFileLoader& operator=(const AudioFileLoader&) = delete;

    // Non-RT, any thread. Requests run in submission order; `done` runs on daw.loader.
    void submit(AudioLoadRequest request, Completion done);

    // Non-RT. Blocks until every request submitted so far has completed.
    void waitUntilIdle();

private:
    struct Job {
        AudioLoadRequest request;
        Completion done;
    };
    void run();

    std::mutex mutex_;
    std::condition_variable wake_;
    std::condition_variable idle_;
    std::deque<Job> queue_;
    bool busy_ = false;
    bool stopping_ = false;
    std::thread thread_;
};

} // namespace daw
