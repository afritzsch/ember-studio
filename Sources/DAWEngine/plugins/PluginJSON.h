#pragma once
// JSON text helpers shared by the plugin hosts' info output (non-RT).

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <string_view>
#include <vector>

namespace daw {

inline std::string pluginJSONString(std::string_view s) {
    std::string out = "\"";
    for (unsigned char c : s) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char buf[8];
                std::snprintf(buf, sizeof buf, "\\u%04x", c);
                out += buf;
            } else {
                out += static_cast<char>(c);
            }
        }
    }
    return out + "\"";
}

inline std::string pluginJSONNumber(double v) {
    if (!std::isfinite(v)) return "null";
    char buf[32];
    std::snprintf(buf, sizeof buf, "%.9g", v);
    return buf;
}

// DW-213 (T-094): the discrete-value and display fields of one pluginInfoJSON param row, with
// a leading comma: `"steps": n` always, `"labels": [...]` when there are steps + 1 of them (06
// ParamInfo's steps/valueLabels shape), `"display"` (the plugin's string for `value`) when known.
inline std::string pluginJSONParamExtras(uint32_t steps, const std::vector<std::string>& labels,
                                         const std::string& display) {
    std::string out = ",\"steps\":" + std::to_string(steps);
    if (steps > 0 && labels.size() == steps + 1) {
        out += ",\"labels\":[";
        for (std::size_t k = 0; k < labels.size(); ++k) {
            if (k) out += ",";
            out += pluginJSONString(labels[k]);
        }
        out += "]";
    }
    if (!display.empty()) out += ",\"display\":" + pluginJSONString(display);
    return out;
}

} // namespace daw
