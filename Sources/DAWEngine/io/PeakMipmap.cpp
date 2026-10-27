#include "io/PeakMipmap.h"

#include <algorithm>
#include <bit>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <system_error>
#include <unistd.h>

namespace daw {

// The format is little-endian, as is every target (D-23: Apple Silicon only). Spelling it out
// lets the serializer copy fields as-is.
static_assert(std::endian::native == std::endian::little, "peak files are little-endian");

namespace {

constexpr char kMagic[8] = {'D', 'A', 'W', 'P', 'E', 'A', 'K', 'S'};
constexpr size_t kHeaderSize = 48;
constexpr size_t kLevelDescriptorSize = 16;

int64_t blockCountFor(int64_t frames, uint32_t blockSize) {
    return (frames + blockSize - 1) / blockSize;
}

template <class T>
void put(std::string& out, T value) {
    char bytes[sizeof(T)];
    std::memcpy(bytes, &value, sizeof(T));
    out.append(bytes, sizeof(T));
}

template <class T>
T get(const std::string& in, size_t offset) {
    T value;
    std::memcpy(&value, in.data() + offset, sizeof(T));
    return value;
}

Error formatError(const std::filesystem::path& file, const char* what) {
    return makeError(ErrorCode::invalidArgument, file.string() + ": not a valid peak file (" + what + ")");
}

} // namespace

PeakMipmap PeakMipmap::compute(const AudioAsset& asset) {
    PeakMipmap mip;
    mip.assetID_ = asset.assetID;
    mip.sampleRate_ = asset.sampleRate;
    mip.channels_ = asset.channels;
    mip.frames_ = asset.frames;

    // Finest level straight from the samples.
    Level& fine = mip.levels_[0];
    fine.blockSize = kBlockSizes[0];
    fine.blockCount = blockCountFor(asset.frames, fine.blockSize);
    fine.peaks.resize(static_cast<size_t>(fine.blockCount) * asset.channels);
    for (uint32_t c = 0; c < asset.channels; ++c) {
        const float* samples = asset.data[c];
        MinMax* out = fine.peaks.data() + c * fine.blockCount;
        for (int64_t b = 0; b < fine.blockCount; ++b) {
            const int64_t begin = b * fine.blockSize;
            const int64_t end = std::min(begin + fine.blockSize, asset.frames);
            const auto [lo, hi] = std::minmax_element(samples + begin, samples + end);
            out[b] = {*lo, *hi};
        }
    }

    // Each coarser level from the one before: block sizes are multiples of each other, so this is
    // exactly the min/max over the same samples.
    for (size_t l = 1; l < kBlockSizes.size(); ++l) {
        const Level& prev = mip.levels_[l - 1];
        Level& level = mip.levels_[l];
        level.blockSize = kBlockSizes[l];
        level.blockCount = blockCountFor(asset.frames, level.blockSize);
        level.peaks.resize(static_cast<size_t>(level.blockCount) * asset.channels);
        const int64_t ratio = level.blockSize / prev.blockSize;
        for (uint32_t c = 0; c < asset.channels; ++c) {
            const MinMax* in = prev.channel(c);
            MinMax* out = level.peaks.data() + c * level.blockCount;
            for (int64_t b = 0; b < level.blockCount; ++b) {
                const int64_t begin = b * ratio;
                const int64_t end = std::min(begin + ratio, prev.blockCount);
                MinMax m = in[begin];
                for (int64_t i = begin + 1; i < end; ++i) {
                    m.min = std::min(m.min, in[i].min);
                    m.max = std::max(m.max, in[i].max);
                }
                out[b] = m;
            }
        }
    }
    return mip;
}

std::filesystem::path PeakMipmap::cachePath(const std::filesystem::path& cacheDir, uint64_t assetID) {
    return cacheDir / (std::to_string(assetID) + ".peaks");
}

bool PeakMipmap::isCurrentFor(const AudioAsset& asset) const {
    return assetID_ == asset.assetID && sampleRate_ == asset.sampleRate &&
           channels_ == asset.channels && frames_ == asset.frames;
}

bool PeakMipmap::operator==(const PeakMipmap& other) const {
    if (assetID_ != other.assetID_ || sampleRate_ != other.sampleRate_ ||
        channels_ != other.channels_ || frames_ != other.frames_)
        return false;
    for (size_t l = 0; l < levels_.size(); ++l) {
        const Level& a = levels_[l];
        const Level& b = other.levels_[l];
        if (a.blockSize != b.blockSize || a.blockCount != b.blockCount || a.peaks != b.peaks)
            return false;
    }
    return true;
}

Result<void> PeakMipmap::write(const std::filesystem::path& file) const {
    std::string out;
    out.append(kMagic, sizeof(kMagic));
    put(out, kFormatVersion);
    put(out, channels_);
    put(out, assetID_);
    put(out, sampleRate_);
    put(out, frames_);
    put(out, static_cast<uint32_t>(levels_.size()));
    put(out, uint32_t{0});
    for (const Level& level : levels_) {
        put(out, level.blockSize);
        put(out, uint32_t{0});
        put(out, static_cast<uint64_t>(level.blockCount));
    }
    for (const Level& level : levels_)
        out.append(reinterpret_cast<const char*>(level.peaks.data()),
                   level.peaks.size() * sizeof(MinMax));

    std::error_code ec;
    std::filesystem::create_directories(file.parent_path(), ec);
    if (ec) return makeError(ErrorCode::io, file.parent_path().string() + ": " + ec.message());

    // Atomic replace, so the UI never reads a half-written cache. The pid keeps concurrent
    // writers (two worktrees' tests, CONV §9) off each other's temporary file.
    std::filesystem::path tmp = file;
    tmp += ".tmp" + std::to_string(::getpid());
    {
        std::ofstream stream(tmp, std::ios::binary | std::ios::trunc);
        stream.write(out.data(), static_cast<std::streamsize>(out.size()));
        stream.close();
        if (!stream) {
            std::filesystem::remove(tmp, ec);
            return makeError(ErrorCode::io, tmp.string() + ": write failed");
        }
    }
    std::filesystem::rename(tmp, file, ec);
    if (ec) {
        std::error_code ignored;
        std::filesystem::remove(tmp, ignored);
        return makeError(ErrorCode::io, file.string() + ": " + ec.message());
    }
    return {};
}

Result<PeakMipmap> PeakMipmap::read(const std::filesystem::path& file) {
    std::ifstream stream(file, std::ios::binary);
    if (!stream) return makeError(ErrorCode::notFound, file.string() + ": cannot open");
    std::string in((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
    if (stream.bad()) return makeError(ErrorCode::io, file.string() + ": read failed");

    if (in.size() < kHeaderSize || std::memcmp(in.data(), kMagic, sizeof(kMagic)) != 0)
        return formatError(file, "bad magic");
    if (get<uint32_t>(in, 8) != kFormatVersion) return formatError(file, "unsupported version");

    PeakMipmap mip;
    mip.channels_ = get<uint32_t>(in, 12);
    mip.assetID_ = get<uint64_t>(in, 16);
    mip.sampleRate_ = get<double>(in, 24);
    mip.frames_ = get<int64_t>(in, 32);
    if (mip.channels_ == 0 || mip.frames_ < 0 || !(mip.sampleRate_ > 0))
        return formatError(file, "bad header");
    if (get<uint32_t>(in, 40) != kBlockSizes.size()) return formatError(file, "bad level count");
    if (in.size() < kHeaderSize + kBlockSizes.size() * kLevelDescriptorSize)
        return formatError(file, "truncated");

    size_t offset = kHeaderSize + kBlockSizes.size() * kLevelDescriptorSize;
    for (size_t l = 0; l < kBlockSizes.size(); ++l) {
        const size_t d = kHeaderSize + l * kLevelDescriptorSize;
        Level& level = mip.levels_[l];
        level.blockSize = get<uint32_t>(in, d);
        level.blockCount = static_cast<int64_t>(get<uint64_t>(in, d + 8));
        if (level.blockSize != kBlockSizes[l] ||
            level.blockCount != blockCountFor(mip.frames_, level.blockSize))
            return formatError(file, "bad level descriptor");
        const size_t count = static_cast<size_t>(level.blockCount) * mip.channels_;
        if (in.size() < offset || (in.size() - offset) / sizeof(MinMax) < count)
            return formatError(file, "truncated");
        level.peaks.resize(count);
        std::memcpy(level.peaks.data(), in.data() + offset, count * sizeof(MinMax));
        offset += count * sizeof(MinMax);
    }
    if (offset != in.size()) return formatError(file, "trailing bytes");
    return mip;
}

} // namespace daw
