#pragma once
// How node factories find decoded audio (D-10). Whoever owns the loaded assets (the facade's
// AssetTable, T-014; tests) passes one to registerBuiltinNodes.
//
// Non-RT: called on daw.compile while a node is created. Returns an empty ref for an asset that
// isn't loaded (offline, still decoding); clips on it play silence.

#include <cstdint>
#include <functional>

#include "io/AudioAsset.h"

namespace daw {

using AssetLookup = std::function<AudioAssetRef(uint64_t assetID)>;

} // namespace daw
