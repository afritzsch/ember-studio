import DAWControl
import DAWModel
import Foundation
import Testing

// CTL-004 against the real offline engine (EngineClient), as dawctl runs it.

@Suite("Headless determinism (CTL-004)")
@MainActor
struct DeterminismTests {
    init() { ControlTestCommands.register() }

    /// Builds a project with a resampled asset on a track (IDs: master 1, asset 2, track 3,
    /// clip 4), renders it, and returns the responses by method.
    private func run(in dir: TempDir, output: String) async throws -> [String: JSONValue] {
        let script = try ControlScript(parsing: """
            project.new {"name": "det", "sampleRate": 48000}
            asset.import {"path": "tone.wav"}
            command.apply {"command": {"type": "ControlTestAddAudioTrack", "name": "Tone"}}
            command.apply {"command": {"type": "ControlTestAddAudioClip", "trackID": 3, "assetID": 2, "start": 0, "length": 7680}}
            render.offline {"from": 0, "to": 7680, "path": "\(output)", "tail": false}
            project.get
            engine.telemetry
            """)
        let dispatcher = TestDispatchers.real(workingDirectory: dir.url)
        var results: [String: JSONValue] = [:]
        for line in script.lines {
            let response = try #require(await dispatcher.handle(line.request))
            #expect(response.error == nil, "line \(line.number): \(response.error?.message ?? "")")
            results[line.request.method] = response.result
        }
        return results
    }

    @Test("CTL-004: the same requests give identical project JSON and bit-identical renders; 0 RT violations")
    func sameRequestsSameResult() async throws {
        let dir = try TempDir()
        // 44.1 kHz into a 48 kHz session: the load resamples (D-27), which must be deterministic too.
        try TestAudio.write([TestAudio.sine(frequency: 440, amplitude: 0.5, sampleRate: 44_100, frames: 44_100)],
                            sampleRate: 44_100, to: dir.file("tone.wav"))

        let first = try await run(in: dir, output: "out/first.wav")
        let second = try await run(in: dir, output: "out/second.wav")

        #expect(first["project.new"] == ["projectID": "00000000-0000-0000-0000-000000000001"])
        #expect(first["asset.import"]?["resampled"] == true)
        let project = try #require(first["project.get"])
        #expect(project.jsonString() == second["project.get"]?.jsonString(), "identical project JSON")
        #expect(project["tracks"]?[0]?["clips"]?[0]?["id"] == 4)

        let a = try Data(contentsOf: dir.file("out/first.wav"))
        let b = try Data(contentsOf: dir.file("out/second.wav"))
        #expect(a == b, "bit-identical renders")
        #expect(first["render.offline"]?["frames"] == 192_000, "7680 ticks = 8 beats = 4 s at 120 bpm, no tail")

        // Not just two silent files: the clip is heard.
        let analysis = try AudioAnalysis.analyze(AudioData(contentsOf: dir.file("out/first.wav")))
        #expect(analysis.peakDb.allSatisfy { $0 > -20 }, "\(analysis.peakDb)")
        #expect(abs(analysis.spectrumPeakHz - 440) < 2)
        #expect(analysis.firstNonSilentSample < 10)

        #if DEBUG  // the RT trap exists only in Debug (BUILD-005)
        for run in [first, second] {
            #expect(run["render.offline"]?["rtViolations"] == 0)
            #expect(run["engine.telemetry"]?["rtViolations"] == 0)
        }
        #endif
    }
}
