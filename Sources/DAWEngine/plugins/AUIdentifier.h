#pragma once
// PLUG-002/010: the `type:subtype:manufacturer` identifier of an Audio Unit, as the scanner writes
// it (PluginCatalog's AudioUnitIdentifier): each field is the four-character code, or `0x` + 8 hex
// digits when the code isn't printable ASCII or contains `:`. Plain C++ (no CoreAudio types), so
// the facade and tests can use it.

#include <cstdint>
#include <string>
#include <string_view>

#include "core/Result.h"

namespace daw {

struct AUComponentID {
    uint32_t type = 0;          // 'aufx', 'aumu', 'aumf', …
    uint32_t subtype = 0;
    uint32_t manufacturer = 0;

    // 'aumu': an instrument (no audio input; MIDI in, audio out).
    bool isInstrument() const { return type == fourCC("aumu"); }

    static constexpr uint32_t fourCC(const char (&s)[5]) {
        return (uint32_t(uint8_t(s[0])) << 24) | (uint32_t(uint8_t(s[1])) << 16) |
               (uint32_t(uint8_t(s[2])) << 8) | uint32_t(uint8_t(s[3]));
    }
    bool operator==(const AUComponentID&) const = default;
};

// invalidArgument unless `identifier` is three valid fields.
Result<AUComponentID> parseAUIdentifier(std::string_view identifier);
// The canonical string for `id` (parseAUIdentifier's inverse).
std::string formatAUIdentifier(const AUComponentID& id);

} // namespace daw
