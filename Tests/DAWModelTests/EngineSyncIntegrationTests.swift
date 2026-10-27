import Foundation
import Testing

@testable import DAWModel

// MODEL-020/021/022 and DW-072 against the real engine (EngineClient, offline). Only the node kinds
// the engine registers so far are used: clip players, channel strips, bus inputs and the master.

/// A fresh folder under $TMPDIR, unique per call (CONV §9).
private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "enginesync-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A mono 16-bit WAV of a 1 kHz sine at half scale.
private func writeSineWAV(_ url: URL, sampleRate: Int, frames: Int) throws {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frames * 2))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
    append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
    data.append(contentsOf: Array("data".utf8)); append(UInt32(frames * 2))
    for i in 0..<frames {
        append(Int16(16_384 * sin(2 * Double.pi * 1000 * Double(i) / Double(sampleRate))))
    }
    try data.write(to: url)
}

@Suite("EngineSync with EngineClient")
@MainActor
struct EngineSyncIntegrationTests {
    init() { TestCommands.register() }

    @Test("MODEL-020..022, DW-072: a project compiles in the engine, plays its asset after assetLoaded, and faders reach the slots; 0 RT violations")
    func endToEnd() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appending(path: "loop.wav")
        try writeSineWAV(wav, sampleRate: 48_000, frames: 48_000)

        let engine = try EngineClient(.offline(sampleRate: 48_000))
        let store = ProjectStore(project: GraphFixtures.audioTracks())
        let sync = try store.attachEngine(engine)
        let track = store.project.tracks[0]
        let asset = store.project.assets[0].id

        var status = engine.waitForGraph(1, timeout: .seconds(5))
        #expect(status.isPublished(1) && status.lastError == nil, "the built graph compiles: \(String(describing: status.lastError))")
        #expect(engine.getParam(sync.runtime.stripParam(track.id, ParamLayout.Strip.gain)!) == 0.8)

        // DW-072: the player was created before the asset existed; assetLoaded gets it a new instance.
        let job = engine.loadAsset(asset, path: wav.path)
        #expect(await engine.waitForJob(job).state == .succeeded)
        #expect(sync.pollEvents().contains { $0.kind == .assetLoaded && $0.subject == asset })
        await sync.settle()
        status = await engine.graphApplied(2)
        #expect(status.isPublished(2) && status.lastError == nil)
        #expect(sync.appliedGraph?.nodes.first { $0.id == GraphNodeID.source(of: track.id) }?.configVersion == 1)

        let spec = ExportSpec(path: "", blockSize: 512, tailEnabled: false)
        var render = try #require(await engine.waitForJob(engine.renderOffline(from: 0, to: 960, spec: spec)).render)
        #expect(render.rtViolations == 0)
        let loud = try #require(engine.meter(track.id), "the track's strip is metered under the track's ID")
        #expect(loud.peak > 0.1)

        // MODEL-021: a fader move is a slot write, not a new graph.
        try store.edit { $0.tracks[0].strip.gain = 0 }
        #expect(!sync.hasPendingApply && engine.graphStatus().submittedVersion == 2)
        render = try #require(await engine.waitForJob(engine.renderOffline(from: 0, to: 960, spec: spec)).render)
        #expect(render.rtViolations == 0)
        #expect(engine.meter(track.id)?.peak == 0)
        #expect(engine.telemetry().rtViolations == 0)
    }
}
