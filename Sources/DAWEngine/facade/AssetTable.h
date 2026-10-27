#pragma once
// DW-041: the decoded assets the facade's AudioFileLoader produced, by assetID. Node factories
// (clip players, T-013) look assets up here on daw.compile when a graph is built; each node then
// holds its own references, so replacing or dropping an asset here never pulls samples out from
// under a graph (IO-032: the last reference dies wherever the last holder lets go, normally
// daw.reclaim).
//
// Threads: non-RT, any thread (a mutex guards the map).

#include <cstdint>
#include <mutex>
#include <unordered_map>

#include "io/AudioAsset.h"

namespace daw {

class AssetTable {
public:
    // An empty ref when `assetID` hasn't loaded.
    AudioAssetRef find(uint64_t assetID) const;
    // Adds `asset` or replaces the one already loaded for its assetID.
    void put(uint64_t assetID, AudioAssetRef asset);
    void remove(uint64_t assetID);
    uint32_t size() const;

private:
    mutable std::mutex mutex_;
    std::unordered_map<uint64_t, AudioAssetRef> assets_;
};

} // namespace daw
