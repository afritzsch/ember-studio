import Foundation
import Testing

@testable import DAWModel

// IO-034 / UI-011 (T-033, autobuild decision): the read-only peaks query the arrange canvas draws
// waveforms from. The facade computes the mipmap when the asset loads; `peaks` copies one level.

@Suite("Engine peaks query (IO-034, UI-011)")
struct EnginePeaksTests {
    /// A stereo 32-bit float WAV, 48 kHz: left a ramp from -1 to 1, right silent.
    private func writeRampWAV(_ url: URL, frames: Int) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frames * 8))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(3)); append(UInt16(2))
        append(UInt32(48_000)); append(UInt32(384_000)); append(UInt16(8)); append(UInt16(32))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(frames * 8))
        for i in 0..<frames {
            append(Float(-1 + 2 * Double(i) / Double(frames - 1)).bitPattern)
            append(Float(0).bitPattern)
        }
        try data.write(to: url)
    }

    @Test("UI-011: EngineClient.peaks returns each mipmap level of a loaded asset, nil before it loads or for a bad level")
    func engineClientPeaks() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "peaks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appending(path: "ramp.wav")
        let frames = 48_000
        try writeRampWAV(wav, frames: frames)

        let engine = try EngineClient(.offline(sampleRate: 48_000))
        #expect(engine.peaks(7, level: 0) == nil, "nothing loaded yet")
        let status = await engine.waitForJob(engine.loadAsset(7, path: wav.path))
        #expect(status.state == .succeeded)

        for (level, blockSize) in PeakLevel.blockSizes.enumerated() {
            let peaks = try #require(engine.peaks(7, level: level))
            let blocks = (frames + blockSize - 1) / blockSize
            #expect(peaks.assetID == 7 && peaks.channels == 2 && peaks.frames == Int64(frames) && peaks.sampleRate == 48_000)
            #expect(peaks.blockSize == blockSize && peaks.blockCount == blocks && peaks.minMax.count == 2 * blocks * 2)
            // The ramp rises, so each block's min is its first sample and its max its last.
            let first = peaks.peak(channel: 0, block: 0)
            #expect(abs(first.min - -1) < 1e-6)
            #expect(abs(first.max - Float(-1 + 2 * Double(blockSize - 1) / Double(frames - 1))) < 1e-5)
            #expect(abs(peaks.peak(channel: 0, block: blocks - 1).max - 1) < 1e-6)
            #expect(peaks.peak(channel: 1, block: blocks / 2) == (0, 0), "the right channel is silent")
        }
        #expect(engine.peaks(7, level: 4) == nil && engine.peaks(7, level: -1) == nil)
        #expect(engine.peaks(8, level: 0) == nil, "another asset")
    }

    @Test("UI-011: FakeEngine reports made-up peaks for loaded assets only")
    func fakeEnginePeaks() throws {
        let engine = FakeEngine()
        #expect(engine.peaks(3, level: 0) == nil)
        _ = engine.loadAsset(3, path: "/x.wav")
        let peaks = try #require(engine.peaks(3, level: 1))
        #expect(peaks.blockSize == 1024 && peaks.channels == 2 && peaks.blockCount == (48_000 + 1023) / 1024)
        #expect(peaks.minMax.count == peaks.channels * peaks.blockCount * 2)
    }
}
