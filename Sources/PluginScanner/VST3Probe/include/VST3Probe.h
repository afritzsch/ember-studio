#pragma once
// PLUG-003: VST3 module probe for the PluginScanner helper. Swift sees only these plain types;
// the SDK headers stay inside VST3Probe.cpp.

#include <cstdint>
#include <string>
#include <vector>

namespace daw::scan {

/// One `kVstAudioEffectClass` class of a module.
struct VST3ClassProbe {
    std::string classUID;  // 32 hex digits (VST3::UID::toString)
    std::string name, vendor, version, subCategories;
    bool isInstrument = false;
    bool hasSidechain = false;  // an audio input bus of type kAux
    uint32_t numParams = 0;
    bool ok = false;     // false: the class could not be instantiated; see error
    std::string error;
};

struct VST3ModuleProbe {
    bool loaded = false;  // false: the module itself failed to load; see error
    std::string error;
    std::string factoryVendor;
    std::vector<VST3ClassProbe> classes;
};

/// Loads the bundle at `bundlePath`, instantiates every audio effect class once to read its
/// buses and parameter count, then unloads it. May crash or hang if the plugin does; that is why
/// it only runs inside the scanner process (PLUG-001).
VST3ModuleProbe probeVST3Module(const std::string& bundlePath);

}  // namespace daw::scan
