import Foundation
import Testing

@testable import DAWModel

// T-030 against the real engine: an asset imported the way asset.import does it (load under
// project.ids.next, then ImportAsset), a clip added with AddClip, and edits that must not change
// the sound (split, trim back and forth, move away and back) rendering bit-identically. 0 RT
// violations throughout.

@Suite("Clip commands and the engine")
@MainActor
struct ClipEngineTests {
    init() { TestCommands.register() }

    /// A mono 32-bit float WAV of a 1 kHz sine at half scale, 48 kHz.
    private func writeSineWAV(_ url: URL, frames: Int) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frames * 4))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(3)); append(UInt16(1))
        append(UInt32(48_000)); append(UInt32(192_000)); append(UInt16(4)); append(UInt16(32))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(frames * 4))
        for i in 0..<frames { append(Float(0.5 * sin(2 * Double.pi * 1000 * Double(i) / 48_000)).bitPattern) }
        try data.write(to: url)
    }

    @Test("MODEL-005, DW-105, DW-072: import + AddClip render; split, trim and move edits that keep the audio in place render bit-identically")
    func editsKeepTheSound() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "clips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appending(path: "sine.wav")
        try writeSineWAV(wav, frames: 48_000)

        let engine = try EngineClient(.offline(sampleRate: 48_000))
        let store = ProjectStore(project: Project(name: "clips"))
        let sync = try store.attachEngine(engine)
        try store.perform(AddTrack(name: "Src", kind: .audio))
        let track = store.project.tracks[0].id

        // asset.import (13): load under the next ID, then perform ImportAsset with what loaded.
        let id = store.project.ids.next
        let loaded = try #require(await engine.waitForJob(engine.loadAsset(id, path: wav.path)).asset)
        try store.perform(ImportAsset(asset: AssetRef(id: id, path: wav.path, channels: Int(loaded.channels),
                                                      originalSampleRate: loaded.fileSampleRate, frames: loaded.fileFrames)))
        try store.perform(AddClip(trackID: track, start: 0, assetID: id))
        let clip = store.project.tracks[0].clips[0].id
        #expect(store.project.tracks[0].clips[0].length == 1920, "the whole second at 120 bpm")
        _ = sync.pollEvents()

        var renders = 0
        func render() async throws -> Data {
            await sync.settle()
            let status = await engine.graphApplied(engine.graphStatus().submittedVersion)
            #expect(status.lastError == nil)
            renders += 1
            let path = dir.appending(path: "r\(renders).wav").path
            let spec = ExportSpec(path: path, blockSize: 256, tailEnabled: false)
            let result = try #require(await engine.waitForJob(engine.renderOffline(from: 0, to: 2400, spec: spec)).render)
            #expect(result.rtViolations == 0)
            return try Data(contentsOf: URL(filePath: path))
        }
        let reference = try await render()
        #expect(try #require(engine.meter(track)).peak > 0.3, "the clip plays")

        try store.perform(SplitClip(clipID: clip, at: 777))
        #expect(store.project.tracks[0].clips.count == 2)
        #expect(try await render() == reference, "a split clip sounds like the whole clip")

        let right = store.project.tracks[0].clips[1].id
        try store.perform(ResizeClip(clipID: right, start: 1500, length: 420))
        try store.perform(ResizeClip(clipID: right, start: 777, length: 1143))
        #expect(try await render() == reference, "trimming the start in and back out restores the audio")

        try store.perform(MoveClip(clipID: clip, start: 3000))
        let moved = try await render()
        #expect(moved != reference)
        try store.perform(MoveClip(clipID: clip, start: 0))
        #expect(try await render() == reference, "moving away and back")

        while store.canUndo { store.undo() }
        #expect(store.project.assets.isEmpty && store.project.tracks.isEmpty)
        await sync.settle()
        #expect(engine.telemetry().rtViolations == 0)
    }
}
