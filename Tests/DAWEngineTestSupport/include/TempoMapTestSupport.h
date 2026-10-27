#pragma once
// Helpers for Tests/DAWEngineTests/TempoMapTests.swift, which calls daw::TempoMap directly.

#include <cstdint>
#include <optional>

#include "time/TempoMap.h"

namespace daw::testing {

// Swift can't call daw::Result's ref-qualified value() overloads, so tests unwrap it here.
inline std::optional<TempoMap> makeTempoMap(const TempoEventList& tempos,
                                            const TimeSigEventList& sigs, double sampleRate) {
    Result<TempoMap> result = TempoMap::make(tempos, sigs, sampleRate);
    if (!result) return std::nullopt;
    return std::move(result).value();
}

// A map with 64 tempo and 64 signature changes, so conversions take every search path.
std::optional<TempoMap> makeRtCheckTempoMap();

// TIME-001/002, CONV §5.3: runs every conversion many times inside an RtScope and returns the
// violations that scope counted. Always 0 when the RT trap is compiled out (Release).
uint64_t conversionViolations(const TempoMap& map);

} // namespace daw::testing
