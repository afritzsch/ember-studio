import DAWControl
import DAWModel
import Foundation
import Testing

// T-088 (DW-149, CTL-024): the insert-chain commands are drivable through the control protocol
// (`command.schema`, `command.apply`, `undo`), the master included, on the real engine.

@Suite("Insert chains through the control protocol (DW-149)")
@MainActor
struct InsertChainControlTests {
    @Test("CTL-024, MODEL-005: command.schema lists InsertDevice, RemoveDevice, RestoreDevice and MoveDevice")
    func schemaListsInsertCommands() async throws {
        let (dispatcher, _) = TestDispatchers.fake()
        let all = try await dispatcher.ok(.commandSchema)["commands"]?.arrayValue ?? []
        let types = Set(all.compactMap { $0["type"]?.stringValue })
        #expect(types.isSuperset(of: ["InsertDevice", "RemoveDevice", "RestoreDevice", "MoveDevice"]))
        let insert = try await dispatcher.ok(.commandSchema, ["type": "InsertDevice"])["commands"]?[0]?["schema"]
        #expect(insert?["required"] == ["type", "channel", "device"])
    }

    @Test("MODEL-005: a master gain insert placed with command.apply silences the render; undo brings the signal back; 0 RT violations")
    func masterInsertRender() async throws {
        let dir = try TempDir()
        let sine = (0..<48_000).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
        try TestAudio.write([sine], sampleRate: 48_000, to: dir.file("sine.wav"))
        let dispatcher = TestDispatchers.real(workingDirectory: dir.url)
        _ = try await dispatcher.ok(.projectNew, ["name": "inserts"])
        _ = try await dispatcher.ok(.assetImport, ["path": "sine.wav"])
        let asset = try await dispatcher.ok(.projectGet, ["path": "/assets/0/id"])
        let master = try await dispatcher.ok(.projectGet, ["path": "/master/id"])
        let track = try #require(try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "Src", "kind": "audio"]])["createdIDs"]?[0])
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddClip", "trackID": track, "start": 0, "assetID": asset]])
        let eq = try await dispatcher.ok(.commandApply, ["command": [
            "type": "InsertDevice", "channel": track, "device": ["format": "builtin", "node": "eq"]]])
        #expect(eq["label"] == "Insert Device" && eq["createdIDs"]?.arrayValue?.count == 1)
        let gain = try await dispatcher.ok(.commandApply, ["command": [
            "type": "InsertDevice", "channel": master, "index": 0, "device": ["format": "builtin", "node": "gain"],
            "params": [["index": 0, "value": 0]]]])
        let slot = try #require(gain["createdIDs"]?[0])
        #expect(try await dispatcher.ok(.projectGet, ["path": "/master/inserts/0/id"]) == slot)

        func peak(_ name: String) async throws -> Float {
            let render = try await dispatcher.ok(.renderOffline, ["from": 0, "to": 1920, "path": .string(name), "tail": false])
            #expect(render["rtViolations"] == 0)
            let audio = try AudioData(contentsOf: dir.file(name))
            return audio.channels.map { $0.map(abs).max() ?? 0 }.max() ?? 0
        }
        #expect(try await peak("silent.wav") == 0, "the master insert at level 0 is in the master's path")
        #expect(try await dispatcher.ok(.undo)["label"] == "Insert Device")
        #expect(try await peak("audible.wav") > 0.1)
        let failure = await dispatcher.failure(.commandApply, ["command": ["type": "InsertDevice", "channel": master,
                                                                           "device": ["format": "builtin", "node": "sampler"]]])
        #expect(failure?.dawError == "invalidArgument")
    }
}
