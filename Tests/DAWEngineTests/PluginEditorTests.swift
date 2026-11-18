import DAWEngineTestSupport
import Testing

// T-063: plugin editors (10 PLUG-017, DW-208) and plugin-side parameter edits (PLUG-015 second half,
// DW-204), engine side. The checks are Objective-C++ (Tests/DAWEngineTestSupport/PluginEditorChecks.mm).
// Editors are main-thread objects, so the view tests run on the main actor; the AU editor's view
// controller arrives on the main queue, so that test awaits it (the main queue runs meanwhile).
// The VST3 ones are in VST3PluginTests' serialized suite: EmberTest's knobs act on its newest
// controller and editor in the process, which those tests create too.

extension VST3PluginTests {
    @Test("DW-204: VST3 beginEdit/performEdit/endEdit become pluginParamEdited events; the controller keeps the editor's value until the model echoes it; 0 RT violations")
    func vst3Edits() { expectPasses(daw.testing.vst3PluginEditsBecomeEvents()) }

    @MainActor
    @Test("PLUG-017, DW-208: a VST3 IPlugView in a container NSView; resizeView and outside resizes; stale after a rate change; closed by destroyPluginView and the facade's end")
    func vst3Editor() { expectPasses(daw.testing.vst3EditorView()) }
}

@Suite("AU editors and plugin-side edits (PLUG-017, DW-204)", .serialized)
struct PluginEditorTests {
    @Test("DW-204: AU Touch/Value/Release become begin/value/end edits; gestures and holds defer the model's push; echoes aren't edits; 0 RT violations")
    func auEdits() { expectPasses(daw.testing.auPluginEditsBecomeEvents()) }

    @Test("DW-276: an AU edit observer follows a parameter tree the V2 bridge replaces later (KVO); the editor's Touch is still heard")
    func auEditsFollowTreeSwap() { expectPasses(daw.testing.auEditsFollowTreeSwap()) }

    @MainActor
    @Test("PLUG-017: an AU editor (requestViewController, else the generic view) arrives on the main queue with a size; destroyPluginView closes it")
    func auEditor() async throws {
        #expect(daw.testing.auEditorBegin())
        let deadline = ContinuousClock.now + .seconds(10)
        while !String(daw.testing.auEditorJSON()).contains("\"ready\":true"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        expectPasses(daw.testing.auEditorFinish())
    }
}
