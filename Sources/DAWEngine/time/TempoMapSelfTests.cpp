// T-007: TempoMap conversions under the Debug RT trap (CONV §5.3). Run from
// Tests/DAWEngineTests/TempoMapTests.swift; see core/SelfTest.h for the harness. The fixture
// and property tests call TempoMap from Swift directly (test-only module map); this one has to
// be C++ because it needs RtScope.

#include "../core/RtTrap.h"
#include "../core/SelfTest.h"
#include "TempoMap.h"

#if DAW_RT_TRAP

using namespace daw;

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

}  // namespace

DAW_SELFTEST(tempomap_conversions_rt_safe) {
    DAW_CHECK(RtTrap::install());

    TempoEventList tempos;
    TimeSigEventList sigs;
    for (int i = 0; i < 64; ++i) {
        tempos.push_back({i * 30'011, 60.0 + i * 3.7});
        sigs.push_back({i * 3840 * 7, 3 + i % 5, i % 2 ? 8 : 4});
    }
    Result<TempoMap> map = TempoMap::make(tempos, sigs, 44100.0);
    DAW_CHECK(map.ok());
    if (!map) return;

    // The violation counters are process-wide, and RtTrapTests provoke violations on purpose
    // while other suites run. Count the delta instead of resetting (which would break those
    // tests), and retry: a real violation here is deterministic and fails every attempt.
    uint64_t violations = 0;
    for (int attempt = 0; attempt < 3; ++attempt) {
        const uint64_t before = RtTrap::violationCount();
        volatile int64_t sink;
        {
            RtScope scope;
            sink = exerciseConversions(*map);
        }
        (void)sink;
        violations = RtTrap::violationCount() - before;
        if (violations == 0) break;
    }
    DAW_CHECK(violations == 0);
}

#endif  // DAW_RT_TRAP
