#include "facade/AssetTable.h"

#include <utility>

namespace daw {

AudioAssetRef AssetTable::find(uint64_t assetID) const {
    std::lock_guard lock(mutex_);
    auto it = assets_.find(assetID);
    return it == assets_.end() ? AudioAssetRef{} : it->second;
}

void AssetTable::put(uint64_t assetID, AudioAssetRef asset) {
    AudioAssetRef replaced;  // released after the lock
    {
        std::lock_guard lock(mutex_);
        AudioAssetRef& slot = assets_[assetID];
        replaced = std::move(slot);
        slot = std::move(asset);
    }
}

void AssetTable::remove(uint64_t assetID) {
    AudioAssetRef removed;
    {
        std::lock_guard lock(mutex_);
        auto it = assets_.find(assetID);
        if (it == assets_.end()) return;
        removed = std::move(it->second);
        assets_.erase(it);
    }
}

uint32_t AssetTable::size() const {
    std::lock_guard lock(mutex_);
    return static_cast<uint32_t>(assets_.size());
}

} // namespace daw
