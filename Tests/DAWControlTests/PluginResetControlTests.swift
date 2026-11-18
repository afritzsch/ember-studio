import DAWControl
import DAWModel
import Foundation
import Testing

// T-097 (DW-242, DW-063): through the control protocol on the real engine, an export starts
// without the tail of what played before. AUSampler into AUDelay (wet only, 0.6 s, 80 % feedback):
// the first render ends with echoes ringing; the second one, of the same range, must be the same
// file. Before T-097 the hosted delay wasn't reset and the residual was about −15 dB.

extension PluginControlTests {
    @Test("DW-242: two exports through a hosted delay with a ringing tail are bit-identical; 0 RT violations")
    func t097ExportsResetHostedPlugins() async throws {
        let dir = try TempDir()
        let dispatcher = TestDispatchers.real(workingDirectory: dir.url)
        _ = try await dispatcher.ok(.projectNew, ["name": "reset"])
        let track = try #require(try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "Keys", "kind": "midi"]])["createdIDs"]?[0])
        let clip = try #require(try await dispatcher.ok(.commandApply, ["command": ["type": "AddClip", "trackID": track, "start": 0, "length": 1920]])["createdIDs"]?[0])
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddNotes", "clipID": clip, "notes": [["start": 0, "length": 480, "pitch": 69, "velocity": 127]]]])
        let sampler: JSONValue = ["format": "au", "identifier": "aumu:samp:appl", "name": "AUSampler", "vendor": "Apple", "version": ""]
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "SetInstrument", "trackID": track, "device": sampler]])
        let delay: JSONValue = ["format": "au", "identifier": "aufx:dely:appl", "name": "AUDelay", "vendor": "Apple", "version": ""]
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "InsertDevice", "channel": track, "device": delay,
                                                                "params": [["index": 0, "value": 100], ["index": 1, "value": 0.6], ["index": 2, "value": 80]]]])

        for name in ["a.wav", "b.wav"] {
            let render = try await dispatcher.ok(.renderOffline, ["from": 0, "to": 1920, "path": .string(name), "tail": false])
            #expect(render["rtViolations"] == 0)
        }
        let a = try AudioData(contentsOf: dir.file("a.wav"))
        let b = try AudioData(contentsOf: dir.file("b.wav"))
        #expect(a.channels.count == b.channels.count)
        #expect((a.channels.first.map { $0.map(abs).max() ?? 0 } ?? 0) > 0.01, "the echoes sound")
        #expect(a.channels == b.channels)
    }
}
