import DAWControl
import DAWModel
import Darwin
import Foundation
import Testing

// DW-204 (T-063, PLUG-015 second half), end to end on the real engine through the control protocol
// (what dawctl runs): EmberTest's controller edits its Gain the way its editor's knob does
// (beginEdit / performEdit / endEdit, through `ember_test_edit`), the dispatcher's event poll hands
// that to the model, and the document gets ONE undoable "Set Parameter"; the model's value comes back
// as a slot push (the render hears it) without a second entry.
// In VST3PluginControlTests' serialized suite: EmberTest's knobs act on its newest controller.

private enum EditTestVST3 {
    static var root: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static var effect: String {
        root.appending(path: ".build/test-plugins/EmberTest.vst3").path + "#E4B3E71A000000000000000000000001"
    }

    static func build() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [root.appending(path: "scripts/build-test-vst3.sh").path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "scripts/build-test-vst3.sh failed")
    }

    typealias Edit = @convention(c) (UInt32, Double, Int32) -> Int32

    /// `ember_test_edit` from the image the engine loaded (dyld keeps one copy per path).
    static func edit() throws -> Edit {
        let path = root.appending(path: ".build/test-plugins/EmberTest.vst3/Contents/MacOS/EmberTest").path
        let image = try #require(dlopen(path, RTLD_NOW))
        let symbol = try #require(dlsym(image, "ember_test_edit"))
        return unsafeBitCast(symbol, to: Edit.self)
    }
}

extension VST3PluginControlTests {
    @Test("DW-204: a VST3 editor's gesture becomes one undoable SetParam; DeviceSlot.params, the render and engine.pluginInfo follow; no echo entry; 0 RT violations")
    func pluginEditorGestureIsOneUndo() async throws {
        try EditTestVST3.build()
        let dir = try TempDir()
        let d = TestDispatchers.real(workingDirectory: dir.url)
        _ = try await d.ok(.projectNew, ["name": "edits"])
        let click = EditTestVST3.root.appending(path: "Tests/GoldenTests/fixtures/assets/click_48k.wav").path
        let asset = try #require(try await d.ok(.assetImport, ["path": .string(click)])["assetID"]?.int64Value)
        let track = try #require(try await d.ok(.commandApply, ["command": ["type": "AddTrack", "name": "Fx", "kind": "audio"]])["createdIDs"]?[0])
        _ = try await d.ok(.commandApply, ["command": ["type": "AddClip", "trackID": track, "start": 0, "assetID": .int(asset)]])
        let device: JSONValue = ["format": "vst3", "identifier": .string(EditTestVST3.effect), "name": "Fx", "vendor": "Ember", "version": "1.0"]
        let slot = try #require(try await d.ok(.commandApply, ["command": ["type": "InsertDevice", "channel": track, "device": device]])["createdIDs"]?[0]?.int64Value)
        _ = try await d.ok(.renderOffline, ["from": 0, "to": 96, "path": "a.wav", "tail": false])

        // The editor's knob: touch, three steps, release (Gain is ParamID 0, index 0).
        let edit = try EditTestVST3.edit()
        #expect(edit(0, 0, 0) == 0)
        for value in [0.6, 0.4, 0.25] { #expect(edit(0, value, 1) == 0) }
        #expect(edit(0, 0, 2) == 0)

        // Any request drains the engine's events first (DW-095).
        let project = try await d.ok(.projectGet)
        let inserts = try #require(project["project"]?["tracks"]?[0]?["inserts"]?.arrayValue ?? project["tracks"]?[0]?["inserts"]?.arrayValue)
        let params = try #require(inserts.first { $0["id"]?.int64Value == slot }?["params"]?.arrayValue)
        #expect(params.count == 1 && params[0]["index"] == 0 && abs((params[0]["value"]?.doubleValue ?? -1) - 0.25) < 1e-6)

        // The model's value reaches the audio path; its echo makes no second entry.
        let render = try await d.ok(.renderOffline, ["from": 0, "to": 96, "path": "b.wav", "tail": false])
        #expect(render["rtViolations"] == 0)
        let left = try #require(try AudioData(contentsOf: dir.file("b.wav")).channels.first)
        #expect(abs(left[0] - 0.125) < 1e-5, "click × gain 0.25 × centre pans 0.5, got \(left[0])")
        let info = try await d.ok(.enginePluginInfo, ["slot": .int(slot)])
        #expect(abs((info["params"]?[0]?["value"]?.doubleValue ?? -1) - 0.25) < 1e-6)

        let undo = try await d.ok(.undo)
        #expect(undo["label"] == "Set Parameter")
        let undone = try await d.ok(.projectGet)
        let undoneInserts = undone["project"]?["tracks"]?[0]?["inserts"]?.arrayValue ?? undone["tracks"]?[0]?["inserts"]?.arrayValue ?? []
        #expect(undoneInserts.first { $0["id"]?.int64Value == slot }?["params"]?.arrayValue?.isEmpty == true)
        // The entry before it is the insert itself: one gesture, one entry.
        #expect(try await d.ok(.undo)["label"] == "Insert Device")
    }
}
