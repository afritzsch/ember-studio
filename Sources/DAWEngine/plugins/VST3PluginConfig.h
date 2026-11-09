#pragma once
// PLUG-011/016 (T-062, autobuild DECISIONS phase 6 "T-062 contract"): what a NodeKind::vst3Plugin
// node is made from, carried in NodeDesc::configJSON like an AU's (AUPluginConfig.h):
//   {"identifier": "/path/to/Plugin.vst3#84E8DE5F92554F5396FAE4133C935A18", "state": "<base64>"}
// `identifier` (required) is the bundle path and the audio-processor class ID (10 Interfaces),
// the scanner's format: 32 hex digits, canonically uppercase. `state` (optional) is the blob
// getPluginState returns (VST3Instance.h: the component and controller state in one container),
// base64; left out or "" for none. Unknown keys are ignored; anything else malformed is
// invalidArgument. DAWModel writes it from a `.vst3` DeviceSlot with sorted keys.

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "core/Result.h"

namespace daw {

// A VST3 plugin's bundle and class. Equal identifiers are the same plugin.
struct VST3PluginID {
    std::string path;      // the bundle (.vst3)
    std::string classUID;  // 32 uppercase hex digits

    std::string identifier() const { return path + "#" + classUID; }
    bool operator==(const VST3PluginID&) const = default;
};

// "path#classUID": the path is everything before the last '#'.
Result<VST3PluginID> parseVST3Identifier(std::string_view identifier);

struct VST3PluginConfig {
    std::string identifier;       // canonical (VST3PluginID::identifier)
    VST3PluginID plugin;
    std::vector<uint8_t> state;   // empty: none

    // Non-RT.
    static Result<VST3PluginConfig> parse(std::string_view configJSON);
    static std::string makeJSON(std::string_view identifier, const std::vector<uint8_t>& state = {});
};

} // namespace daw
