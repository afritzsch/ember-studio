#include "plugins/VST3PluginConfig.h"

#include <cctype>

#include "plugins/AUPluginConfig.h"

namespace daw {

Result<VST3PluginID> parseVST3Identifier(std::string_view identifier) {
    const auto hash = identifier.rfind('#');
    if (hash == std::string_view::npos || hash == 0)
        return makeError(ErrorCode::invalidArgument, "VST3 identifier needs the form path#classUID");
    const std::string_view uid = identifier.substr(hash + 1);
    if (uid.size() != 32) return makeError(ErrorCode::invalidArgument, "VST3 class UID must be 32 hex digits");
    VST3PluginID id;
    id.path = std::string(identifier.substr(0, hash));
    id.classUID.reserve(32);
    for (char c : uid) {
        if (!std::isxdigit(static_cast<unsigned char>(c)))
            return makeError(ErrorCode::invalidArgument, "VST3 class UID must be 32 hex digits");
        id.classUID.push_back(static_cast<char>(std::toupper(static_cast<unsigned char>(c))));
    }
    return id;
}

Result<VST3PluginConfig> VST3PluginConfig::parse(std::string_view configJSON) {
    // The JSON shape (identifier + base64 state) is the AU config's; only the identifier differs.
    auto fields = parsePluginConfigFields(configJSON);
    if (!fields) {
        Error e = fields.error();
        e.message = "VST3 config: " + e.message;
        return e;
    }
    auto plugin = parseVST3Identifier(fields->identifier);
    if (!plugin) {
        Error e = plugin.error();
        e.message = "VST3 config: " + e.message;
        return e;
    }
    VST3PluginConfig config;
    config.plugin = std::move(plugin).value();
    config.identifier = config.plugin.identifier();
    config.state = std::move(fields->state);
    return config;
}

std::string VST3PluginConfig::makeJSON(std::string_view identifier, const std::vector<uint8_t>& state) {
    return AUPluginConfig::makeJSON(identifier, state);  // the same JSON shape
}

} // namespace daw
