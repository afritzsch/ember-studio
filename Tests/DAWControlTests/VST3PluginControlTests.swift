import DAWControl
import DAWModel
import Foundation
import Testing

// T-062: a hosted VST3 plugin through the control protocol on the real engine, with the real bundles
// built by scripts/build-test-vst3.sh (the same code path dawctl runs). PLUG-016 is proved on a
// real save/open: a project without any param slots renders with the gain from the saved state.

private enum TestVST3 {
    static var root: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func effect() -> String {
        root.appending(path: ".build/test-plugins/EmberTest.vst3").path + "#E4B3E71A000000000000000000000001"
    }

    static func synth() -> String {
        root.appending(path: ".build/test-plugins/EmberTest.vst3").path + "#E4B3E71A000000000000000000000002"
    }

    static func again() -> String {
        root.appending(path: ".build/test-plugins/again.vst3").path + "#84E8DE5F92554F5396FAE4133C935A18"
    }

    static func build() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [root.appending(path: "scripts/build-test-vst3.sh").path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "scripts/build-test-vst3.sh failed")
    }

    static func device(_ identifier: String, name: String) -> JSONValue {
        ["format": "vst3", "identifier": .string(identifier), "name": .string(name), "vendor": "Ember", "version": "1.0"]
    }
}

@Suite("VST3 hosting through the control protocol (PLUG-011, 015, 016)", .serialized)
@MainActor
struct VST3PluginControlTests {
    /// A track with one VST3 insert at slot id `slot`, playing `assetID` once from tick 0.
    private func addEffectTrack(_ dispatcher: Dispatcher, identifier: String, slot: Int, params: [(Int, Double)],
                                assetID: Int64, trackID: Int64 = 10) async throws {
        let paramList: JSONValue = .array(params.map { ["index": .int(Int64($0.0)), "value": .double($0.1)] })
        let track: JSONValue = [
            "id": .int(trackID), "name": "Fx", "kind": "audio", "color": ["red": 0.5, "green": 0.5, "blue": 0.5],
            "clips": [], "takeFolders": [],
            "inserts": [["id": .int(Int64(slot)), "kind": TestVST3.device(identifier, name: "Fx"), "params": paramList, "bypass": false]],
            "strip": ["gain": 1, "pan": 0, "mute": false, "solo": false, "phaseInvert": false],
            "sends": [], "output": ["kind": "master"], "armed": false, "monitoring": "auto", "automation": [],
        ]
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "RestoreTrack", "index": 0, "track": track]])
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddClip", "trackID": .int(trackID), "start": 0, "assetID": .int(assetID)]])
    }

    @Test("PLUG-011/015: an instrument VST3 renders notes, reports its params, saves its state; 0 RT violations")
    func synthInstrument() async throws {
        try TestVST3.build()
        let dir = try TempDir()
        let dispatcher = TestDispatchers.real(workingDirectory: dir.url)
        _ = try await dispatcher.ok(.projectNew, ["name": "vst3"])
        let track = try #require(try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "Keys", "kind": "midi"]])["createdIDs"]?[0])
        let clip = try #require(try await dispatcher.ok(.commandApply, ["command": ["type": "AddClip", "trackID": track, "start": 0, "length": 1920]])["createdIDs"]?[0])
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddNotes", "clipID": clip, "notes": [["start": 960, "length": 480, "pitch": 69, "velocity": 127]]]])
        let device = TestVST3.device(TestVST3.synth(), name: "Ember Synth")
        let slot = try #require(try await dispatcher.ok(.commandApply, ["command": ["type": "SetInstrument", "trackID": track, "device": device]])["createdIDs"]?[0]?.int64Value)

        let render = try await dispatcher.ok(.renderOffline, ["from": 0, "to": 1920, "path": "vst3.wav", "tail": false])
        #expect(render["rtViolations"] == 0)
        let audio = try AudioData(contentsOf: dir.file("vst3.wav"))
        // The synth writes velocity at the note-on's frame: 960 ticks = 24000 frames at 120 bpm. Two
        // centre-panned strips (track, master) make it × 0.5.
        let left = try #require(audio.channels.first)
        #expect(abs(left[24000] - 0.5) < 1e-3)
        #expect(left[0] == 0)
        #expect(left[24001] == 0)

        let info = try await dispatcher.ok(.enginePluginInfo, ["slot": .int(slot)])
        #expect(info["identifier"] == .string(TestVST3.synth()))
        #expect(info["loaded"] == true)
        #expect(info["error"] == nil)
        #expect(info["instrument"] == true)
        #expect(info["params"]?.arrayValue?.count == 3)

        _ = try await dispatcher.ok(.projectSave, ["path": "vst3.dawproject"])
        let bytes = try Data(contentsOf: dir.file("vst3.dawproject/Plugins/\(slot).state"))
        #expect(bytes.starts(with: Data("EVS3".utf8)))

        let telemetry = try await dispatcher.ok(.engineTelemetry)
        #expect(telemetry["rtViolations"] == 0)
    }

    @Test("PLUG-016: state round-trips through a real project save and open")
    func stateRoundTripSaveOpen() async throws {
        try TestVST3.build()
        let dir = try TempDir()
        let assets = TestVST3.root.appending(path: "Tests/GoldenTests/fixtures/assets/click_48k.wav").path

        // Project A: gain 0.25 pushed from a param slot. Its state is saved to disk.
        let a = TestDispatchers.real(workingDirectory: dir.url)
        _ = try await a.ok(.projectNew, ["name": "a"])
        let assetA = try #require(try await a.ok(.assetImport, ["path": .string(assets)])["assetID"]?.int64Value)
        try await addEffectTrack(a, identifier: TestVST3.effect(), slot: 11, params: [(0, 0.25)], assetID: assetA)
        _ = try await a.ok(.renderOffline, ["from": 0, "to": 96, "path": "a.wav", "tail": false])
        _ = try await a.ok(.projectSave, ["path": "a.dawproject"])
        let saved = try Data(contentsOf: dir.file("a.dawproject/Plugins/11.state"))
        #expect(saved.starts(with: Data("EVS3".utf8)))

        // Project B: the same plugin and slot, with no param slot at all, so the gain can only come
        // from the state written into its Plugins folder.
        let b = TestDispatchers.real(workingDirectory: dir.url)
        _ = try await b.ok(.projectNew, ["name": "b"])
        let assetB = try #require(try await b.ok(.assetImport, ["path": .string(assets)])["assetID"]?.int64Value)
        try await addEffectTrack(b, identifier: TestVST3.effect(), slot: 11, params: [], assetID: assetB)
        _ = try await b.ok(.projectSave, ["path": "b.dawproject"])
        try saved.write(to: dir.file("b.dawproject/Plugins/11.state"))

        // Opening B applies the saved state; the render proves it reached the audio path.
        let c = TestDispatchers.real(workingDirectory: dir.url)
        _ = try await c.ok(.projectOpen, ["path": "b.dawproject"])
        let render = try await c.ok(.renderOffline, ["from": 0, "to": 96, "path": "c.wav", "tail": false])
        #expect(render["rtViolations"] == 0)
        let audio = try AudioData(contentsOf: dir.file("c.wav"))
        let left = try #require(audio.channels.first)
        #expect(abs(left[0] - 0.125) < 1e-5, "click × saved gain 0.25 × centre pans 0.5, got \(left[0])")

        let info = try await c.ok(.enginePluginInfo, ["slot": 11])
        #expect(info["loaded"] == true)
        let params = try #require(info["params"]?.arrayValue)
        #expect(abs((params[0]["value"]?.doubleValue ?? -1) - 0.25) < 1e-6)
    }

    @Test("PLUG-011: a missing plugin loads as absent with an error and doesn't reject the graph")
    func missingPlugin() async throws {
        let dir = try TempDir()
        let dispatcher = TestDispatchers.real(workingDirectory: dir.url)
        _ = try await dispatcher.ok(.projectNew, ["name": "m"])
        let track = try #require(try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "K", "kind": "midi"]])["createdIDs"]?[0])
        let device = TestVST3.device("/nonexistent/Missing.vst3#84E8DE5F92554F5396FAE4133C935A18", name: "Gone")
        let slot = try #require(try await dispatcher.ok(.commandApply, ["command": ["type": "SetInstrument", "trackID": track, "device": device]])["createdIDs"]?[0]?.int64Value)
        let render = try await dispatcher.ok(.renderOffline, ["from": 0, "to": 96, "path": "m.wav", "tail": false])
        #expect(render["rtViolations"] == 0)
        let info = try await dispatcher.ok(.enginePluginInfo, ["slot": .int(slot)])
        #expect(info["loaded"] == false)
        #expect(info["error"] != nil)
    }
}
