#include "automation/AutomationPlayer.h"

#include <utility>

namespace daw {

AutomationPlayer::AutomationPlayer(uint64_t laneID, ParamID target, std::vector<AutomationPoint> points,
                                   ParamMapping mapping)
    : laneID_(laneID), target_(target), points_(std::move(points)), mapping_(mapping) {}

uint32_t AutomationPlayer::seek(Tick tick) DAW_RT {
    const auto n = static_cast<uint32_t>(points_.size());
    if (n == 0 || tick < points_[0].tick) return 0;
    const auto covers = [&](uint32_t i) DAW_RT {
        return points_[i].tick <= tick && (i + 1 == n || tick < points_[i + 1].tick);
    };
    // Playback moves forward a block at a time: the cached segment or the next one.
    if (cursor_ < n && covers(cursor_)) return cursor_;
    if (cursor_ + 1 < n && covers(cursor_ + 1)) return cursor_ + 1;
    // CONV-RT-04: a binary search, bounded by log2(n) steps. Invariant: points_[lo].tick <= tick.
    ++searches_;
    uint32_t lo = 0, hi = n;
    while (hi - lo > 1) {
        const uint32_t mid = lo + (hi - lo) / 2;
        if (points_[mid].tick <= tick) lo = mid;
        else hi = mid;
    }
    return lo;
}

float AutomationPlayer::normalizedAt(Tick tick) DAW_RT {
    const auto n = static_cast<uint32_t>(points_.size());
    if (n == 0) return 0.0f;
    cursor_ = seek(tick);
    const AutomationPoint& a = points_[cursor_];
    if (cursor_ + 1 == n || tick < a.tick) return interpolate(a, a, tick);  // before the first or after the last
    return interpolate(a, points_[cursor_ + 1], tick);
}

} // namespace daw
