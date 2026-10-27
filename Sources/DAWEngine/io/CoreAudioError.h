#pragma once
// OSStatus → daw::Error for the io/ code that calls AudioToolbox (CONV §4). Includes no Apple
// headers itself (OSStatus is a 32-bit int), so engine headers can stay framework-free.

#include "core/Result.h"

#include <cctype>
#include <cstdint>
#include <string>

namespace daw {

// "<what> (OSStatus 'fmt?')" for four-character codes, "<what> (OSStatus -50)" otherwise.
inline Error coreAudioError(int32_t status, ErrorCode code, std::string what) {
    const auto u = static_cast<uint32_t>(status);
    const char chars[4] = {static_cast<char>(u >> 24), static_cast<char>(u >> 16),
                           static_cast<char>(u >> 8), static_cast<char>(u)};
    bool printable = true;
    for (char ch : chars) printable = printable && std::isprint(static_cast<unsigned char>(ch));
    what += printable ? " (OSStatus '" + std::string(chars, 4) + "')"
                      : " (OSStatus " + std::to_string(status) + ")";
    return makeError(code, std::move(what));
}

} // namespace daw
