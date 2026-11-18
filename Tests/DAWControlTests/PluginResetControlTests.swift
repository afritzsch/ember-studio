import DAWControl
import DAWModel
import Foundation
import Testing

// T-097 (DW-242, DW-063): through the control protocol on the real engine, an export starts
// without the tail of what played before. The built-in sampler (a 440 Hz sine) into AUDelay (wet
// only, 0.6 s, 80 % feedback): the first render ends with echoes ringing; the second one, of the
// same range, must be the same file. Before T-097 the hosted delay wasn't reset and the residual
// was about −15 dB. (The source is the built-in sampler, not AUSampler: an AU with 11 parameters
// whose values reach the model mid-test makes Apple's V2 bridge allocate in the render that pushes
// them all, a pre-existing issue recorded in the T-097 report.)

extension PluginControlTests {
    @Test("DW-242: two exports through a hosted delay with a ringing tail are bit-identical; 0 RT violations")
    func t097ExportsResetHostedPlugins() async throws {
        let dir = try TempDir()
        let dispatcher = TestDispatchers.real(workingDirectory: dir.url)
        let sine = dir.file("a440.wav")
        try TestAudio.write([TestAudio.sine(frequency: 440, amplitude: 0.5, sampleRate: 48_000, frames: 48_000)],
                            sampleRate: 48_000, to: sine)
        _ = try await dispatcher.ok(.projectNew, ["name": "reset", "sampleRate": 48_000])
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddTrack", "name": "Keys", "kind": "midi"]])  // 2
        _ = try await dispatcher.ok(.assetImport, ["path": .string(sine.path)])  // asset 3
        _ = try await dispatcher.ok(.commandApply, ["command": [
            "type": "SetInstrument", "trackID": 2, "device": ["format": "builtin", "node": "sampler"],
            "zones": [["assetID": 3, "rootKey": 69, "loopStart": 0, "loopEnd": 48_000]],
        ]])  // slot 4
        let delay: JSONValue = ["format": "au", "identifier": "aufx:dely:appl", "name": "AUDelay", "vendor": "Apple", "version": ""]
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "InsertDevice", "channel": 2, "device": delay,
                                                                "params": [["index": 0, "value": 100], ["index": 1, "value": 0.6], ["index": 2, "value": 80]]]])  // slot 5
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddClip", "trackID": 2, "start": 0, "length": 1920]])  // 6
        _ = try await dispatcher.ok(.commandApply, ["command": ["type": "AddNotes", "clipID": 6, "notes": [["start": 0, "length": 480, "pitch": 69, "velocity": 127]]]])

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
