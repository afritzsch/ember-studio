#pragma once
// Swift can't call daw::Result's ref-qualified value() overloads, so tests unwrap it here.

#include <optional>

#include "../../../Sources/DAWEngine/time/TempoMap.h"

namespace daw::testing {

inline std::optional<TempoMap> makeTempoMap(const TempoEventList& tempos,
                                            const TimeSigEventList& sigs, double sampleRate) {
    Result<TempoMap> result = TempoMap::make(tempos, sigs, sampleRate);
    if (!result) return std::nullopt;
    return std::move(result).value();
}

}  // namespace daw::testing
