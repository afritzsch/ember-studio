#pragma once
// IO-034: waveform overview. Min/max peaks of an AudioAsset at four block sizes, computed at
// import/load and cached as Project/Cache/<assetID>.peaks. The UI (12, UI-011) reads the cache
// file and picks the level by pixels-per-sample.
//
// Peaks describe the asset as loaded, i.e. at the session rate (IO-031). The header records the
// rate, so a cache made at another rate is stale and gets recomputed (see isCurrentFor).
//
// ── .peaks file format, version 1 ────────────────────────────────────────────────────────────
// All integers and floats are little-endian; floats are IEEE-754 binary32, doubles binary64.
//
//   offset size  field
//   0      8     magic        "DAWPEAKS"
//   8      4     version      uint32 = 1
//   12     4     channels     uint32 (≥ 1)
//   16     8     assetID      uint64
//   24     8     sampleRate   float64, Hz (the asset's rate, not the original file's)
//   32     8     frames       int64, frames per channel in the asset
//   40     4     levelCount   uint32 = 4
//   44     4     reserved     0
//   48     16×levelCount      one level descriptor each, finest first:
//                  +0  uint32 blockSize   (256, 1024, 4096, 16384)
//                  +4  uint32 reserved    0
//                  +8  uint64 blockCount  = ceil(frames / blockSize)
//   then the level data, in descriptor order. Each level is channel-major:
//     for channel c in 0..<channels: blockCount pairs of { float32 min, float32 max }
//   so the pair for (level L, channel c, block b) sits at
//     dataStart(L) + (c × blockCount(L) + b) × 8
//   where dataStart(0) = 48 + 16 × levelCount and dataStart(L+1) = dataStart(L) +
//   channels × blockCount(L) × 8. Block b covers frames [b × blockSize, min((b+1) × blockSize,
//   frames)); the last block may be partial. The file is exactly that long; a reader rejects any
//   other length.
// ─────────────────────────────────────────────────────────────────────────────────────────────

#include "core/Result.h"
#include "io/AudioAsset.h"

#include <array>
#include <cstdint>
#include <filesystem>
#include <vector>

namespace daw {

class PeakMipmap {
public:
    static constexpr uint32_t kFormatVersion = 1;
    static constexpr std::array<uint32_t, 4> kBlockSizes{256, 1024, 4096, 16384};

    struct MinMax {
        float min;
        float max;
        bool operator==(const MinMax&) const = default;
    };

    struct Level {
        uint32_t blockSize = 0;
        int64_t blockCount = 0;
        std::vector<MinMax> peaks; // channel-major: peaks[c * blockCount + b]

        const MinMax* channel(uint32_t c) const { return peaks.data() + c * blockCount; }
    };

    // Non-RT (daw.loader). Every level is exact: the coarse ones are reduced from the 256 level,
    // which works because each block size is a multiple of the previous one.
    static PeakMipmap compute(const AudioAsset& asset);

    static Result<PeakMipmap> read(const std::filesystem::path& file);
    // Writes atomically (temporary file + rename), creating the parent directory if needed.
    Result<void> write(const std::filesystem::path& file) const;

    // Project/Cache/<assetID>.peaks, assetID in decimal.
    static std::filesystem::path cachePath(const std::filesystem::path& cacheDir, uint64_t assetID);

    // True if these peaks were made from an asset with the same identity and shape, so the cache
    // can be reused instead of recomputing.
    bool isCurrentFor(const AudioAsset& asset) const;

    uint64_t assetID() const { return assetID_; }
    double sampleRate() const { return sampleRate_; }
    uint32_t channels() const { return channels_; }
    int64_t frames() const { return frames_; }
    const std::array<Level, kBlockSizes.size()>& levels() const { return levels_; }

    bool operator==(const PeakMipmap&) const;

private:
    uint64_t assetID_ = 0;
    double sampleRate_ = 0;
    uint32_t channels_ = 0;
    int64_t frames_ = 0;
    std::array<Level, kBlockSizes.size()> levels_;
};

} // namespace daw
