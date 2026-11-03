#pragma once
// IO-033 (T-056): the bookkeeping of a session-rate change's asset re-conversion. The facade keeps
// where every asset came from (DW-118), and when the session rate changes it decodes each one
// again from its original file at the new rate on daw.loader (D-27: never from the resampled copy
// in RAM). The results are staged here until every asset of the pass is done; then the facade
// swaps them in all at once and rebuilds the graph, so the clip players and samplers that resolve
// assets when they're created pick them up in one new snapshot.
//
// A pass is abandoned when another rate change starts a new one: its late results are stale. So
// is the result for an asset that was loaded again (loadAsset) after the pass began: that newer
// load, already at the new rate, wins.
//
// Threads: none of its own and no lock. The facade calls it with its mutex held.

#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "io/AudioAsset.h"
#include "io/PeakMipmap.h"

namespace daw {

class AssetReloader {
public:
    // Where an asset is decoded from (loadAsset's arguments).
    struct Source {
        std::string path;
        std::string peakCacheDir;  // IO-034, DW-077: empty computes the peaks without a cache file
    };

    // One asset to decode again. `pass` and `serial` tell its result apart from stale ones.
    struct Request {
        uint64_t assetID = 0;
        Source source;
        uint64_t pass = 0;
        uint64_t serial = 0;
    };

    // What a pass produced for one asset. A null `asset` means the reload failed: the asset is
    // dropped (an asset at the old rate would only play silence, AudioClipPlayer/Sampler check
    // the rate), and its clips render silence like any offline asset (MODEL-046).
    struct Staged {
        uint64_t assetID = 0;
        AudioAssetRef asset;
        std::shared_ptr<const PeakMipmap> peaks;
    };

    struct Progress {
        bool active = false;
        double previousRate = 0;  // the session rate the pass converts from
        double rate = 0;          // and to
        uint32_t done = 0;        // results so far, failed and superseded ones included
        uint32_t total = 0;
        uint32_t failed = 0;
    };

    enum class Outcome : uint8_t {
        stale,     // from an abandoned pass: ignore it
        progress,  // counted; more to come
        finished,  // counted, and it was the last: takeStaged() and swap
    };

    // loadAsset: remembers where `assetID` comes from and returns the load's serial. A later
    // load of the same ID supersedes what a running pass would stage for it.
    uint64_t recordLoad(uint64_t assetID, Source source);

    // A session-rate change from `previousRate` to `rate`: abandons a running pass and starts a
    // new one over every asset loaded so far (by assetID, so the order is deterministic). An empty
    // list means there is nothing to convert, and no pass is active.
    std::vector<Request> beginPass(double previousRate, double rate);

    // The result of `request`: `staged.asset` null if it failed.
    Outcome complete(const Request& request, Staged staged);

    // Once complete() said finished: the pass's results in assetID order, and the pass ends.
    // Superseded assets aren't in it.
    std::vector<Staged> takeStaged();

    bool active() const { return progress_.active; }
    const Progress& progress() const { return progress_; }
    size_t knownAssets() const { return sources_.size(); }

private:
    struct Known {
        Source source;
        uint64_t serial = 0;
    };
    std::unordered_map<uint64_t, Known> sources_;
    uint64_t nextSerial_ = 1;
    uint64_t pass_ = 0;
    Progress progress_;
    std::vector<Staged> staged_;
};

} // namespace daw
