@preconcurrency import AVFoundation
import DAWControl
import DAWModel
import Foundation
import MCP
import Testing

@testable import dawmcp

// Helpers for the dawmcp suites. All test targets share one process and one CommandRegistry, so
// the test commands' type strings carry a prefix of their own (see DAWControlTests' support).
// Clips and assets have no DAWModel commands yet (T-030), so the audible scenarios add them with
// these and load the asset by saving and reopening the project (`project.open` loads assets),
// which keeps clear of `ImportAsset` stand-ins other suites register.

enum DawmcpTestCommands {
    /// Idempotent.
    static func register() {
        CommandRegistry.register(DawmcpTestAddAsset.self)
        CommandRegistry.register(DawmcpTestRemoveAsset.self)
        CommandRegistry.register(DawmcpTestAddAudioClip.self)
        CommandRegistry.register(DawmcpTestRemoveClip.self)
    }
}

/// Adds an asset to the document only; the engine loads it when the project is opened.
struct DawmcpTestAddAsset: Command {
    static let type = "DawmcpTestAddAsset"
    var path: String
    var channels: Int
    var sampleRate: Double
    var frames: Int64
    var label: String { "Add Asset" }

    func apply(to project: inout Project) throws(DAWError) -> any Command {
        let id = project.ids.allocate()
        project.assets.append(AssetRef(id: id, path: path, channels: channels, originalSampleRate: sampleRate, frames: frames))
        return DawmcpTestRemoveAsset(assetID: id)
    }
}

struct DawmcpTestRemoveAsset: Command {
    static let type = "DawmcpTestRemoveAsset"
    var assetID: ModelID
    var label: String { "Add Asset" }

    func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let index = project.assets.firstIndex(where: { $0.id == assetID }) else { throw .notFound(kind: "asset", id: assetID) }
        let asset = project.assets.remove(at: index)
        return DawmcpTestAddAsset(path: asset.path, channels: asset.channels, sampleRate: asset.originalSampleRate, frames: asset.frames)
    }
}

struct DawmcpTestAddAudioClip: Command {
    static let type = "DawmcpTestAddAudioClip"
    var trackID: NodeIDValue
    var assetID: ModelID
    var start: Tick
    var length: Tick
    var label: String { "Add Clip" }

    func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard project.assets.contains(where: { $0.id == assetID }) else { throw .notFound(kind: "asset", id: assetID) }
        let id = project.ids.allocate()
        try project.updateTrack(trackID) { $0.clips.append(.audio(AudioClip(id: id, assetID: assetID, start: start, length: length))) }
        return DawmcpTestRemoveClip(trackID: trackID, clipID: id)
    }
}

struct DawmcpTestRemoveClip: Command {
    static let type = "DawmcpTestRemoveClip"
    var trackID: NodeIDValue
    var clipID: ModelID
    var label: String { "Add Clip" }

    func apply(to project: inout Project) throws(DAWError) -> any Command {
        let removed: Clip? = try project.updateTrack(trackID) { track in
            guard let index = track.clips.firstIndex(where: { $0.id == clipID }) else { return nil }
            return track.clips.remove(at: index)
        }
        guard case .audio(let clip) = removed else { throw .notFound(kind: "clip", id: clipID) }
        return DawmcpTestAddAudioClip(trackID: trackID, assetID: clip.assetID, start: clip.start, length: clip.length)
    }
}

/// A fresh folder under $TMPDIR, unique per call (CONV §9). Removed when the value is dropped.
final class TempDir: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "dawmcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String) -> URL { url.appending(path: name) }
}

/// Writes a float32 stereo WAV of a sine.
func writeSine(to url: URL, frequency: Double, amplitude: Double, sampleRate: Double, frames: Int) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    for c in 0..<2 {
        for i in 0..<frames {
            buffer.floatChannelData![c][i] = Float(amplitude * sin(2 * Double.pi * frequency * Double(i) / sampleRate))
        }
    }
    try file.write(from: buffer)
    file.close()
}

extension CallTool.Result {
    /// The text items, in order.
    var texts: [String] {
        content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }
    }

    /// The first text item as JSON.
    var json: JSONValue {
        get throws { try JSONValue(parsing: Data(try #require(texts.first).utf8)) }
    }
}

extension DawTools {
    /// Calls a tool and expects success; returns the result JSON.
    func ok(_ name: String, _ arguments: [String: Value] = [:], sourceLocation: SourceLocation = #_sourceLocation) async throws -> JSONValue {
        let result = await call(name, arguments: arguments)
        #expect(result.isError != true, "\(name): \(result.texts)", sourceLocation: sourceLocation)
        return try result.json
    }

    /// Calls a tool and expects failure; returns the JSON-RPC error object.
    func failure(_ name: String, _ arguments: [String: Value] = [:], sourceLocation: SourceLocation = #_sourceLocation) async throws -> JSONValue {
        let result = await call(name, arguments: arguments)
        #expect(result.isError == true, "\(name) succeeded: \(result.texts)", sourceLocation: sourceLocation)
        return try result.json
    }
}
