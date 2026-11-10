import DAWControl
import Foundation
import Testing

// T-062 (PLUG-011): the VST3 hosting golden. The SDK's `again` sample (built from Vendor/vst3sdk by
// scripts/build-test-vst3.sh) is a known gain, so the expected output is computed, not stored
// (docs/autobuild/DECISIONS.md "T-062 test plugin"): no entry in references/, and the fixture is
// generated here because the identifier holds a machine-specific absolute path. The render goes
// through the real graph and the golden harness's offline render (0 RT violations).

@Suite("Golden, VST3 hosting (PLUG-011)")
@MainActor
struct VST3GoldenTests {
    static let name = "vst3_again_gain"
    static let frames = 48000

    nonisolated static var repoRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The fixture: "Again" plays assets/click_48k.wav (1.0 at frame 0, then silence) through the
    /// `again` insert with gain 0.25 (normalized; slot 0). Centre pans on the track and master
    /// give × 0.5 on each side, so frame 0 is exactly 0.125 (-18.062 dBFS), the rest silence.
    static func fixtureText(pluginIdentifier: String) -> String {
        let device = #"{"format": "vst3", "identifier": "\#(pluginIdentifier)", "name": "AGain VST3", "vendor": "Steinberg", "version": ""}"#
        return #"""
        # @expect {"field": "frames", "value": 48000}
        # @expect {"field": "peakDb", "value": -18.062, "tolerance": 0.001, "range": {"start": 0, "end": 1}}
        # @expect {"field": "peakDb", "value": -240, "tolerance": 0.001, "range": {"start": 1, "end": 48000}}
        project.new {"name": "vst3_again_gain", "sampleRate": 48000}
        command.apply {"command": {"type": "RestoreTrack", "index": 0, "track": {"id": 2, "name": "Again", "kind": "audio", "color": {"red": 0.5, "green": 0.5, "blue": 0.5}, "clips": [], "takeFolders": [], "inserts": [{"id": 3, "kind": \#(device), "params": [{"index": 0, "value": 0.25}], "bypass": false}], "strip": {"gain": 1, "pan": 0, "mute": false, "solo": false, "phaseInvert": false}, "sends": [], "output": {"kind": "master"}, "armed": false, "monitoring": "auto", "automation": []}}}
        asset.import {"path": "assets/click_48k.wav"}
        command.apply {"command": {"type": "AddClip", "trackID": 2, "start": 0, "assetID": 4}}
        render.offline {"from": 0, "to": 1920, "path": "vst3_again_gain.wav", "tail": false, "blockSize": 480}
        """#
    }

    @Test("PLUG-011: the SDK again sample through the real graph, offline: exactly input x gain x centre pans; 0 RT violations")
    func againAnalyticGolden() async throws {
        try buildTestPlugins()
        let path = Self.repoRoot.appending(path: ".build/test-plugins/again.vst3").path
        let text = Self.fixtureText(pluginIdentifier: "\(path)#84E8DE5F92554F5396FAE4133C935A18")
        let fixture = try GoldenFixture(name: Self.name, text: text)
        let run = await GoldenHarness.run(fixture, reference: nil)
        defer { if run.failures.isEmpty { try? FileManager.default.removeItem(at: run.workDirectory) } }
        #expect(run.failures.isEmpty, "\(run.failures)")
        let audio = try AudioData(contentsOf: try #require(run.golden))
        #expect(audio.channels.count == 2 && audio.frameCount == Self.frames)
        for channel in audio.channels {
            #expect(abs(channel[0] - 0.125) < 1e-6)
            #expect(channel.dropFirst().allSatisfy { abs($0) < 1e-6 })
        }
    }
}

/// scripts/build-test-vst3.sh: builds the bundles when they are missing or stale. Failing here
/// (not skipping) on purpose: the plugins are in-repo sources.
func buildTestPlugins() throws {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/bash")
    process.arguments = [VST3GoldenTests.repoRoot.appending(path: "scripts/build-test-vst3.sh").path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "scripts/build-test-vst3.sh failed")
}
