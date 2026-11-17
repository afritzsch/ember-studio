#pragma once
// 06 Interfaces (contract): one row of a processor's parameter table, exported as JSON for the
// model and UI. `index` is the param's offset from the node's NodeDesc::firstParam.
//
// Each processor declares its table as a constexpr array next to its node type and publishes it
// through its NodeKindInfo (DSP-041, NodeRegistry::paramInfo).

#include <cstdint>

namespace daw {

struct ParamInfo {
    uint32_t index;
    const char* id;
    const char* name;
    float min, max, def;
    enum class Curve { linear, log, db } curve;
    const char* unit;
    bool automatable;
    // Contract delta (T-065, DW-196), accepted (autobuild): discrete params. `steps` is the number
    // of steps between `min` and `max` (VST3's stepCount): 0 = continuous, 1 = a switch (min/max),
    // n = n + 1 values `min + k·(max − min)/n`. `valueLabels`, when set, holds `steps + 1` display
    // names in value order (the delay's note values); null shows the numbers (or Off/On for a
    // switch). Both default, so existing tables compile unchanged.
    uint32_t steps = 0;
    const char* const* valueLabels = nullptr;
};

} // namespace daw
