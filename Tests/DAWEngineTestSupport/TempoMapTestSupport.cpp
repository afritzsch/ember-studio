// T-007: TempoMap conversions under the Debug RT trap (CONV §5.3). The fixture and property
// tests call TempoMap from Swift directly; this part is C++ because it needs RtScope, and so that
// the compiler checks exerciseConversions as DAW_RT.

#include "TempoMapTestSupport.h"

#include "core/RtTrap.h"

namespace daw::testing {

namespace {

// Every RT entry point, many times, over a map with enough events that the searches recurse.
int64_t exerciseConversions(const TempoMap& map) DAW_RT {
    int64_t sink = 0;
    for (Tick t = -100'000; t < 2'000'000; t += 97) {
        const SamplePos s = map.tickToSample(t);
        sink += s + map.sampleToTick(s + 13) + static_cast<int64_t>(map.bpmAt(t));
        const BBT bbt = map.tickToBBT(t);
        sink += map.bbtToTick(bbt) + bbt.bar;
    }
    return sink;
}

} // namespace

std::optional<TempoMap> makeRtCheckTempoMap() {
    TempoEventList tempos;
    TimeSigEventList sigs;
    for (int i = 0; i < 64; ++i) {
        tempos.push_back({i * 30'011, 60.0 + i * 3.7});
        sigs.push_back({i * 3840 * 7, 3 + i % 5, i % 2 ? 8 : 4});
    }
    return makeTempoMap(tempos, sigs, 44100.0);
}

uint64_t conversionViolations(const TempoMap& map) {
    // DW-019: the scope's own count, so violations other tests provoke on other threads at the
    // same time don't show up here.
    RtScope scope;
    volatile int64_t sink = exerciseConversions(map);
    (void)sink;
    return scope.violations();
}

} // namespace daw::testing
