#include "PluginInfoChecks.h"

#include <cstdlib>
#include <filesystem>
#include <string>

#include "daw/EngineFacade.h"
#include "daw/GraphDescription.h"
#include "plugins/AUPluginConfig.h"
#include "plugins/VST3PluginConfig.h"

namespace daw::testing {

namespace {

constexpr const char* kAgainUID = "84E8DE5F92554F5396FAE4133C935A18";

std::filesystem::path repoRoot() {
    return std::filesystem::path(__FILE__).parent_path().parent_path().parent_path();
}

bool ensureTestPlugins() {
    static const bool built = [] {
        const std::string command = "\"" + (repoRoot() / "scripts/build-test-vst3.sh").string() + "\"";
        return std::system(command.c_str()) == 0;
    }();
    return built;
}

struct FacadeRef {
    EngineFacade* facade;
    FacadeRef() {
        DriverConfigPOD config;
        config.sampleRate = 48000;
        facade = EngineFacade::create(EngineMode::offline, config);
    }
    ~FacadeRef() {
        if (facade) releaseFacade(facade);
    }
    EngineFacade* operator->() const { return facade; }
};

// A master with plugin slots on it, in a chain: slot ids and their (kind, config).
bool publishChain(EngineFacade& f, std::initializer_list<std::pair<NodeID, std::pair<NodeKind, std::string>>> slots) {
    GraphDescriptionBuilder g;
    g.addNode(1, NodeKind::master, 0, 0, 0, "");
    uint64_t edge = 1;
    for (const auto& [id, node] : slots) {
        g.addNode(id, node.first, 0, 0, 0, node.second);
        g.addEdge(edge++, id, 1, EdgeKind::audio, 0);
    }
    g.setTempo(0, 120.0);
    g.setTimeSignature(0, 4, 4);
    g.setMaster(1);
    const uint64_t version = f.applyGraph(g.description());
    const GraphStatusPOD s = f.waitForGraph(version, 20000);
    return s.publishedVersion >= version && s.lastError.ok();
}

// The `{"index":n,…}` object of params[n] in pluginInfoJSON (rows hold no nested objects).
std::string paramRow(const std::string& json, int index) {
    const auto at = json.find("{\"index\":" + std::to_string(index) + ",");
    if (at == std::string::npos) return {};
    const auto end = json.find('}', at);
    return end == std::string::npos ? std::string() : json.substr(at, end - at + 1);
}

bool has(const std::string& text, const std::string& fragment) { return text.find(fragment) != std::string::npos; }

} // namespace

CheckResult vst3ParamDisplayStrings() {
    CheckResult checks;
    DAW_CHECK(ensureTestPlugins());
    FacadeRef f;
    DAW_CHECK(f.facade != nullptr);
    if (!f.facade) return checks;
    const std::string again = (repoRoot() / ".build/test-plugins/again.vst3").string() + "#" + kAgainUID;
    DAW_CHECK(publishChain(*f.facade, {{20, {NodeKind::vst3Plugin, VST3PluginConfig::makeJSON(again, {})}}}));

    const std::string info = f->pluginInfoJSON(20);
    DAW_CHECK(has(info, "\"loaded\":true"));
    // again: 0 gain (GainParameter, dB strings), 1 VU meter (read-only), 2 bypass (a toggle).
    const std::string gain = paramRow(info, 0), meter = paramRow(info, 1), bypass = paramRow(info, 2);
    DAW_CHECK(has(gain, "\"name\":\"Gain\"") && has(gain, "\"unit\":\"dB\""));
    DAW_CHECK(has(gain, "\"steps\":0") && !has(gain, "\"labels\""));
    DAW_CHECK(has(gain, "\"display\":\"0.00\""));  // the default, 1.0
    DAW_CHECK(has(meter, "\"steps\":0"));
    DAW_CHECK(has(bypass, "\"name\":\"Bypass\"") && has(bypass, "\"steps\":1"));
    DAW_CHECK(has(bypass, "\"labels\":[\"Off\",\"On\"]") && has(bypass, "\"display\":\"Off\""));

    // Values stay normalized (DECISIONS "T-094 plugin info"); the plugin names any of them.
    DAW_CHECK(has(gain, "\"min\":0,\"max\":1"));
    DAW_CHECK(f->paramDisplay(20, 0, 0.5f) == "-6.02");
    DAW_CHECK(f->paramDisplay(20, 0, 0.0f) == "-oo");
    DAW_CHECK(f->paramDisplay(20, 0, 2.0f) == "0.00");  // clamped to 1
    DAW_CHECK(f->paramDisplay(20, 2, 1.0f) == "On");
    DAW_CHECK(f->paramDisplay(20, 3, 0.5f).empty());   // no such param
    DAW_CHECK(f->paramDisplay(21, 0, 0.5f).empty());   // no such slot
    // Asking doesn't change the plugin.
    DAW_CHECK(has(paramRow(f->pluginInfoJSON(20), 0), "\"display\":\"0.00\""));
    return checks;
}

CheckResult auParamDisplayStrings() {
    CheckResult checks;
    FacadeRef f;
    DAW_CHECK(f.facade != nullptr);
    if (!f.facade) return checks;
    DAW_CHECK(publishChain(*f.facade, {{30, {NodeKind::auPlugin, AUPluginConfig::makeJSON("aufx:nbeq:appl", {})}},
                                       {40, {NodeKind::auPlugin, AUPluginConfig::makeJSON("aufx:dely:appl", {})}}}));

    // AUNBandEQ: 0 global gain (dB), 1 band 1 bypass (Boolean), 2 band 1 filter type (Indexed, 11
    // valueStrings).
    const std::string eq = f->pluginInfoJSON(30);
    DAW_CHECK(has(eq, "\"loaded\":true"));
    const std::string global = paramRow(eq, 0), bypass = paramRow(eq, 1), type = paramRow(eq, 2);
    DAW_CHECK(has(global, "\"steps\":0") && has(global, "\"unit\":\"dB\"") && !has(global, "\"display\""));
    DAW_CHECK(has(bypass, "\"steps\":1") && !has(bypass, "\"labels\""));  // Off/On is the host's
    DAW_CHECK(has(type, "\"name\":\"Type\"") && has(type, "\"steps\":10"));
    DAW_CHECK(has(type, "\"labels\":[\"Parametric\",\"Butterworth Low Pass\""));
    DAW_CHECK(has(type, "\"Resonant High Shelf\"]"));
    DAW_CHECK(has(type, "\"display\":\""));
    DAW_CHECK(f->paramDisplay(30, 2, 7.0f) == "Low Shelf");
    DAW_CHECK(f->paramDisplay(30, 2, 6.6f) == "Low Shelf");  // the nearest step
    DAW_CHECK(f->paramDisplay(30, 2, 0.0f) == "Parametric");
    DAW_CHECK(f->paramDisplay(30, 0, 3.0f).empty());       // no strings: the host formats it

    // AUDelay: no strings; unit names as the AU gives them (Secs, %, Hz).
    const std::string delay = f->pluginInfoJSON(40);
    DAW_CHECK(has(delay, "\"loaded\":true") && !has(delay, "\"display\""));
    DAW_CHECK(has(paramRow(delay, 1), "\"unit\":\"Secs\"") && has(paramRow(delay, 3), "\"unit\":\"Hz\""));
    DAW_CHECK(has(paramRow(delay, 1), "\"steps\":0"));
    DAW_CHECK(f->paramDisplay(40, 1, 0.5f).empty());
    return checks;
}

} // namespace daw::testing
