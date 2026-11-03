import AVFoundation
import DAWControl
import Foundation
import Testing

// T-061 (PLUG-010): the AU hosting golden. A system AU can change with macOS, so there is no
// stored reference (docs/autobuild/DECISIONS.md "T-061 golden"): `fixtures/plugins/` is outside
// the folder the reference check lists. The fixture runs through the golden harness (0 RT
// violations, its analysis @expects), then nulls against the same AU rendered by AVAudioEngine.

@Suite("Golden, AU hosting (PLUG-010)")
@MainActor
struct AUGoldenTests {
    static let name = "au_sampler_note"
    static let frames = 48000
    static let slice: AVAudioFrameCount = 480
    /// The note-off: 960 ticks at 120 BPM.
    static let noteOffFrame = 24000
    static let toleranceDb = -90.0

    @Test("PLUG-010: AUSampler as a track instrument meets its analysis and nulls against AVAudioEngine's render at <= -90 dBFS")
    func auSamplerNullsAgainstAVAudioEngine() async throws {
        let url = GoldenHarness.fixturesDirectory.appending(path: "plugins/\(Self.name).jsonl")
        let fixture = try GoldenFixture(name: Self.name, contentsOf: url)
        let run = await GoldenHarness.run(fixture, reference: nil)
        defer { if run.failures.isEmpty { try? FileManager.default.removeItem(at: run.workDirectory) } }
        #expect(run.failures.isEmpty, "\(run.failures)")
        let golden = try #require(run.golden)

        let ours = try AudioData(contentsOf: golden)
        let reference = try Self.renderWithAVAudioEngine()
        #expect(ours.channels.count == 2 && ours.frameCount == Self.frames)
        guard ours.channels.count == 2, ours.frameCount == Self.frames else { return }
        var maxDiff: Float = 0
        var peak: Float = 0
        for c in 0..<2 {
            for n in 0..<Self.frames {
                maxDiff = max(maxDiff, abs(ours.channels[c][n] - reference[c][n]))
                peak = max(peak, abs(reference[c][n]))
            }
        }
        let residualDb = maxDiff > 0 ? 20 * log10(Double(maxDiff)) : -240
        #expect(peak > 0.01, "the reference sounds")
        #expect(residualDb <= Self.toleranceDb, "null residual \(residualDb) dBFS")
    }

    /// AUSampler in AVAudioEngine's offline manual rendering, in the fixture's 480-frame blocks:
    /// note-on before the first slice, note-off before the slice at 24000. Times 0.5, the track and
    /// master strips' centre pans (√½ each, MIX-005).
    static func renderWithAVAudioEngine() throws -> [[Float]] {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let engine = AVAudioEngine()
        let sampler = AVAudioUnitSampler()
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: slice)
        try engine.start()
        defer { engine.stop() }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: slice))
        var out = [[Float]](repeating: [Float](repeating: 0, count: frames), count: 2)
        for start in stride(from: 0, to: frames, by: Int(slice)) {
            if start == 0 { sampler.startNote(69, withVelocity: 100, onChannel: 0) }
            if start == noteOffFrame { sampler.stopNote(69, onChannel: 0) }
            let status = try engine.renderOffline(slice, to: buffer)
            #expect(status == .success)
            let data = try #require(buffer.floatChannelData)
            for c in 0..<2 {
                for f in 0..<Int(slice) { out[c][start + f] = 0.5 * data[c][f] }
            }
        }
        return out
    }
}
