import DAWEngineTestSupport
import Testing

// T-094 (DW-213, 08/10 "Contract delta (T-094)"): hosted plugins' steps, value names and display
// strings in pluginInfoJSON, and the facade's paramDisplay. Checks in
// Tests/DAWEngineTestSupport/PluginInfoChecks.cpp. The VST3 one runs in VST3PluginTests' serialized
// suite, with the other tests that load the test bundles.

extension VST3PluginTests {
    @Test("DW-213: VST3 pluginInfoJSON carries steps, labels (getParamStringByValue) and the display string; paramDisplay names any normalized value")
    func vst3DisplayStrings() { expectPasses(daw.testing.vst3ParamDisplayStrings()) }
}

@Suite("Plugin param display strings (DW-213)")
struct PluginInfoTests {
    @Test("DW-213: AU Boolean/Indexed params get steps and valueStrings labels; display and paramDisplay use the AU's strings")
    func auDisplayStrings() { expectPasses(daw.testing.auParamDisplayStrings()) }
}
