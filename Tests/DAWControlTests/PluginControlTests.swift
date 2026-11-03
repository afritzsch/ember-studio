import DAWControl
import DAWModel
import Foundation
import Testing

// T-061: a hosted AU through the control protocol, on the real engine. `engine.pluginInfo` reads
// the slot's AU (PLUG-010/015); `project.save` captures its state (PLUG-016, MODEL-043) through
// the plugin state provider the dispatcher installs.

@Suite("AU hosting through the control protocol (PLUG-010, 015, 016)")
@MainActor
struct PluginControlTests {
    @Test("PLUG-010/015: engine.pluginInfo on the fake engine answers loaded: false")
    func pluginInfoFake() async throws {
        let (dispatcher, _) = TestDispatchers.fake()
        _ = try await dispatcher.ok(.projectNew, ["name": "a"])
        #expect(try await dispatcher.ok(.enginePluginInfo, ["slot": 7]) == ["slot": 7, "loaded": false])
        #expect(await dispatcher.failure(.enginePluginInfo, [:])?.dawError == "invalidParams")
    }

    @Test("PLUG-010/015/016: AUSampler as an instrument renders notes, reports its params, saves its state; 0 RT violations")
    func auSamplerInstrument() async throws {
        let dir = try TempDir()
        let dispatcher = TestDispatchers.real(workingDirectory: dir.url)
        _ = try await dispatcher.ok(.projectNew, ["name": "au"])
        let track = try #require(try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "Keys", "kind": "midi"]])["createdIDs"]?[0])
        let clip = try #require(try await dispatcher.ok(.commandApply, ["command": ["type": "AddClip", "trackID": track, "start": 0, "length": 1920]])["createdIDs"]?[0])
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddNotes", "clipID": clip, "notes": [["start": 0, "length": 960, "pitch": 69, "velocity": 127]]]])
        let device: JSONValue = ["format": "au", "identifier": "aumu:samp:appl", "name": "AUSampler", "vendor": "Apple", "version": ""]
        let slot = try #require(try await dispatcher.ok(.commandApply, ["command": ["type": "SetInstrument", "trackID": track, "device": device]])["createdIDs"]?[0]?.int64Value)

        let render = try await dispatcher.ok(.renderOffline, ["from": 0, "to": 1920, "path": "au.wav", "tail": false])
        #expect(render["rtViolations"] == 0)
        let audio = try AudioData(contentsOf: dir.file("au.wav"))
        let peak = audio.channels.first.map { $0.map(abs).max() ?? 0 } ?? 0
        #expect(peak > 0.01, "AUSampler's default patch sounds the note")

        let info = try await dispatcher.ok(.enginePluginInfo, ["slot": .int(slot)])
        #expect(info["identifier"] == "aumu:samp:appl")
        #expect(info["loaded"] == true)
        #expect(info["error"] == nil)
        #expect(info["params"]?.arrayValue != nil)

        // MODEL-043: the save writes the AU's live state to Plugins/<slot>.state; the project in
        // memory doesn't change.
        _ = try await dispatcher.ok(.projectSave, ["path": "au.dawproject"])
        let bytes = try Data(contentsOf: dir.file("au.dawproject/Plugins/\(slot).state"))
        #expect(bytes.starts(with: Data("bplist".utf8)))
        #expect(dispatcher.store?.project.tracks.contains { $0.instrument?.pluginState != nil } == false)

        let telemetry = try await dispatcher.ok(.engineTelemetry)
        #expect(telemetry["rtViolations"] == 0)
    }
}
