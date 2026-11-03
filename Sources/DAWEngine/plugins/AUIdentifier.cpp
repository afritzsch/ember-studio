#include "plugins/AUIdentifier.h"

#include <optional>

namespace daw {

namespace {

std::optional<uint32_t> parseCode(std::string_view field) {
    if (field.size() == 10 && field.substr(0, 2) == "0x") {
        uint32_t value = 0;
        for (char c : field.substr(2)) {
            uint32_t digit = 0;
            if (c >= '0' && c <= '9') digit = uint32_t(c - '0');
            else if (c >= 'a' && c <= 'f') digit = uint32_t(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') digit = uint32_t(c - 'A' + 10);
            else return std::nullopt;
            value = value << 4 | digit;
        }
        return value;
    }
    if (field.size() != 4) return std::nullopt;
    uint32_t value = 0;
    for (char c : field) value = value << 8 | uint32_t(uint8_t(c));
    return value;
}

std::string formatCode(uint32_t code) {
    std::string s;
    bool printable = true;
    for (int shift = 24; shift >= 0; shift -= 8) {
        const char c = char((code >> shift) & 0xFF);
        printable = printable && c >= 0x20 && c <= 0x7E && c != ':';
        s += c;
    }
    if (printable) return s;
    static constexpr char kHex[] = "0123456789ABCDEF";
    std::string hex = "0x";
    for (int shift = 28; shift >= 0; shift -= 4) hex += kHex[(code >> shift) & 0xF];
    return hex;
}

} // namespace

Result<AUComponentID> parseAUIdentifier(std::string_view identifier) {
    const auto first = identifier.find(':');
    const auto second = first == std::string_view::npos ? first : identifier.find(':', first + 1);
    // A 4-character field may itself hold ':' only in its hex form, so exactly two separators.
    if (second == std::string_view::npos || identifier.find(':', second + 1) != std::string_view::npos)
        return makeError(ErrorCode::invalidArgument,
                         "AU identifier \"" + std::string(identifier) + "\" is not type:subtype:manufacturer");
    const auto type = parseCode(identifier.substr(0, first));
    const auto subtype = parseCode(identifier.substr(first + 1, second - first - 1));
    const auto manufacturer = parseCode(identifier.substr(second + 1));
    if (!type || !subtype || !manufacturer)
        return makeError(ErrorCode::invalidArgument,
                         "AU identifier \"" + std::string(identifier) + "\" has a field that isn't a four-character code");
    return AUComponentID{*type, *subtype, *manufacturer};
}

std::string formatAUIdentifier(const AUComponentID& id) {
    return formatCode(id.type) + ":" + formatCode(id.subtype) + ":" + formatCode(id.manufacturer);
}

} // namespace daw
