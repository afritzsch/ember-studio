#pragma once
// PLUG-010/016 (T-061, autobuild DECISIONS phase 5): what a NodeKind::auPlugin node is made from,
// carried in its NodeDesc::configJSON (05 Interfaces: "kind-specific, non-RT"):
//   {"identifier": "aufx:dely:appl", "state": "<base64>"}
// `identifier` (required) is the AU's type:subtype:manufacturer (AUIdentifier.h). `state` is the
// plugin state as getPluginState returns it (AU `fullState` as a binary plist, PLUG-016), base64;
// left out or "" for none (the plugin starts at its defaults). Unknown keys are ignored; anything
// else malformed is invalidArgument. DAWModel writes it from a `.au` DeviceSlot (MODEL-020) with
// sorted keys, so equal slots give equal strings.

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "core/Result.h"
#include "plugins/AUIdentifier.h"

namespace daw {

struct AUPluginConfig {
    std::string identifier;       // canonical form (formatAUIdentifier)
    AUComponentID component;
    std::vector<uint8_t> state;   // empty: none

    // Non-RT.
    static Result<AUPluginConfig> parse(std::string_view configJSON);
    // Non-RT. The configJSON for `identifier` (and `state`, when not empty), keys sorted.
    static std::string makeJSON(std::string_view identifier, const std::vector<uint8_t>& state = {});
};

} // namespace daw
