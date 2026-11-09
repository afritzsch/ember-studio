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
};

} // namespace daw
