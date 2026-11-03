import Foundation
import Testing

@testable import DAWModel

// DW-096 (T-044): the `midi_tempo` fixture project (Tests/Fixtures/projects/midi_tempo.json)
// through EngineClient, the real offline engine, now that MIDI edges carry data (T-045) and the
// sampler is registered (T-041). Before, only its GraphDescription snapshot was checked
// (GraphDescriptionBuilderTests). Here the engine accepts its graph (a MIDI clip player → sampler
// edge, a MIDI track without an instrument, a tempo and meter change), and with a sampler zone its
// notes sound exactly where the project's tempo map puts them, including after the change.
// 0 RT violations throughout.

/// A fresh folder under $TMPDIR, unique per call (CONV §9).
private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "miditempo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A mono 32-bit float WAV at 48 kHz: 48000 frames of a 1 kHz sine at 0.5, 1000 whole periods, so
/// a zone looping [0, 48000) has no seam. Frame 0 is 0.
private func writeSineWAV(_ url: URL) throws {
    let frames = 48_000
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

/// The left channel of a 32-bit float WAV the engine rendered (the master is stereo; both
/// channels are equal here, every pan is centred).
private func readLeftChannel(_ url: URL) throws -> [Float] {
    let bytes = [UInt8](try Data(contentsOf: url))
    func u32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
    func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
    var channels = 0, bits = 0, offset = 12
    while offset + 8 <= bytes.count {
        let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self), size = u32(offset + 4)
        let body = offset + 8
        if id == "fmt " { (channels, bits) = (u16(body + 2), u16(body + 14)) }
        if id == "data" {
            #expect(channels == 2 && bits == 32)
            guard channels > 0, bits == 32 else { return [] }
            let frames = min(size, bytes.count - body) / (4 * channels)
            return (0..<frames).map { f in Float(bitPattern: UInt32(u32(body + 4 * channels * f))) }
        }
        offset = body + size + (size & 1)
    }
    Issue.record("no data chunk in \(url.lastPathComponent)")
    return []
}

@Suite("midi_tempo through EngineClient (DW-096)")
@MainActor
struct MidiTempoEngineTests {
    init() { TestCommands.register() }

    /// The fixture's IDs: Keys (2) with sampler slot 4 and MIDI clip 5; "No instrument" (3).
    static let keys: NodeIDValue = 2, sampler: NodeIDValue = 4, noInstrument: NodeIDValue = 3
    static let releaseFrames = 9600  // the sampler's default release, 0.2 s (06 "Sampler semantics")

    /// Renders ticks `from..<to` to a WAV in `dir` once the latest graph is published; 0 RT violations.
    static func render(_ engine: EngineClient, _ sync: EngineSync, from: Tick, to: Tick, in dir: URL,
                       name: String) async throws -> [Float] {
        await sync.settle()
        let status = await engine.graphApplied(engine.graphStatus().submittedVersion)
        #expect(status.lastError == nil, "\(String(describing: status.lastError))")
        let path = dir.appending(path: "\(name).wav").path
        let spec = ExportSpec(path: path, blockSize: 512, tailEnabled: false)
        let result = try #require(await engine.waitForJob(engine.renderOffline(from: from, to: to, spec: spec)).render)
        #expect(result.rtViolations == 0)
        return try readLeftChannel(URL(filePath: path))
    }

    @Test("DW-096: midi_tempo compiles in the real engine and renders across its tempo and meter change with 0 RT violations; its zoneless sampler is silent")
    func asCommitted() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = try EngineClient(.offline(sampleRate: 48_000))
        let store = ProjectStore(project: try GraphFixtures.midiTempo())
        let sync = try store.attachEngine(engine)

        let status = engine.waitForGraph(1, timeout: .seconds(5))
        #expect(status.isPublished(1) && status.lastError == nil, "\(String(describing: status.lastError))")
        let graph = try #require(sync.appliedGraph)
        let player = GraphNodeID.source(of: Self.keys)
        #expect(graph.nodes.contains { $0.id == player && $0.kind == .midiClipPlayer })
        #expect(graph.nodes.contains { $0.id == Self.sampler && $0.kind == .sampler })
        #expect(graph.edges.contains { $0.from == player && $0.to == Self.sampler && $0.kind == .midi })
        #expect(!graph.nodes.contains { $0.id == GraphNodeID.source(of: Self.noInstrument) },
                "a MIDI track without an instrument has no player")

        // Ticks 0..9600: the notes (3840..5760 at 120 bpm), the change to 90 bpm and 3/4 at 7680.
        let map = store.project.tempoMap
        let left = try await Self.render(engine, sync, from: 0, to: 9600, in: dir, name: "as_committed")
        #expect(left.count == Int(map.tickToSample(9600)))
        #expect(left.count == 256_000)  // 192000 frames at 120 bpm + 1920 ticks at 90 bpm
        #expect(left.allSatisfy { $0 == 0 }, "a sampler without zones is silent (DSP-020)")
        #expect(engine.telemetry().rtViolations == 0)
    }

    @Test("DW-096, DSP-003, DSP-021: with a zone, midi_tempo's notes sound where its tempo map puts them, before and after the tempo change; 0 RT violations")
    func withZone() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appending(path: "sine.wav")
        try writeSineWAV(wav)
        let engine = try EngineClient(.offline(sampleRate: 48_000))
        let store = ProjectStore(project: try GraphFixtures.midiTempo())
        let sync = try store.attachEngine(engine)

        // asset.import (13): load under the next ID, then ImportAsset; then the zone (DW-140),
        // rooted at C4 (60) and looping the whole sine.
        let id = store.project.ids.next
        let loaded = try #require(await engine.waitForJob(engine.loadAsset(id, path: wav.path)).asset)
        try store.perform(ImportAsset(asset: AssetRef(id: id, path: wav.path, channels: Int(loaded.channels),
                                                      originalSampleRate: loaded.fileSampleRate, frames: loaded.fileFrames)))
        try store.perform(SetSamplerZones(slotID: Self.sampler, zones: [SamplerZone(assetID: id, rootKey: 60, loopStart: 0,
                                                                                     loopEnd: 48_000)]))
        _ = sync.pollEvents()
        let map = store.project.tempoMap
        func frame(_ tick: Int64) -> Int { Int(map.tickToSample(Tick(tick))) }

        // As committed, the Keys clip (tick 3840, 1920 long) plays C4 [3840, 4320) ch 0, E4
        // [4320, 4800) ch 1 (velocity 80), G4 [5520, 5760) (cut at the clip end); C5 at 5840 is
        // after the clip end and never plays. All at 120 bpm (25 frames per tick).
        var left = try await Self.render(engine, sync, from: 0, to: 9600, in: dir, name: "zone")
        #expect([3840, 4320, 4800, 5520, 5760].map(frame) as [Int] == [96000, 108000, 120000, 138000, 144000] as [Int])
        #expect(left.count == 256_000)
        guard left.count == 256_000 else { return }
        // Silent up to the first note-on; the sine's frame 0 is 0, so the first sound is one later.
        #expect(left.firstIndex { $0 != 0 } == frame(3840) + 1)
        // E4 on MIDI channel 1 sounds (the sampler plays every channel) at 2^(4/12) × 1 kHz: once
        // C4's release is over, 2300 frames hold ~60.4 periods of 1259.9 Hz (C4 would give 47.9).
        let e4 = (frame(4320) + Self.releaseFrames + 100)..<frame(4800)
        #expect(e4.count == 2300)
        let crossings = e4.dropFirst().filter { left[$0 - 1] < 0 && left[$0] >= 0 }.count
        #expect((60...61).contains(crossings), "\(crossings) rising zero crossings")
        // E4's release ends before G4 starts: silence in between; G4 ends at the clip end
        // (tick 5760, not its own end at 6000), and after its release nothing sounds (C5 is cut).
        #expect(left[(frame(4800) + Self.releaseFrames)..<frame(5520)].allSatisfy { $0 == 0 })
        #expect(left[frame(5520) + 1] != 0)
        #expect(left[(frame(5520) + 100)..<frame(5760)].contains { abs($0) > 0.1 })
        #expect(left[(frame(5760) + Self.releaseFrames)...].allSatisfy { $0 == 0 })
        #expect(left[(frame(5760) + Self.releaseFrames - 200)..<(frame(5760) + Self.releaseFrames)].contains { $0 != 0 })

        // Moved across the change to 90 bpm at 7680: C4 [7200, 7680) at 120 bpm, E4 [7680, 8160)
        // and G4 [8880, 9120) at 90 bpm (33⅓ frames per tick). The player places them with the
        // project's map: at a constant 120 bpm G4 would start at frame 222000.
        try store.perform(MoveClip(clipID: 5, start: 7200))
        left = try await Self.render(engine, sync, from: 0, to: 9600, in: dir, name: "moved")
        #expect([7200, 7680, 8160, 8880, 9120].map(frame) as [Int] == [180000, 192000, 208000, 232000, 240000] as [Int])
        #expect(TempoMap().tickToSample(8880) == 222_000)
        guard left.count == 256_000 else { return }
        #expect(left.firstIndex { $0 != 0 } == frame(7200) + 1)
        #expect(left[(frame(8160) + Self.releaseFrames)..<frame(8880)].allSatisfy { $0 == 0 })
        #expect(left[(frame(8160) + Self.releaseFrames - 200)..<(frame(8160) + Self.releaseFrames)].contains { $0 != 0 })
        #expect(left[frame(8880) + 1] != 0, "G4 starts on its tick's frame after the tempo change")
        #expect(left[(frame(9120) + Self.releaseFrames)...].allSatisfy { $0 == 0 })
        #expect(engine.telemetry().rtViolations == 0)
    }
}
