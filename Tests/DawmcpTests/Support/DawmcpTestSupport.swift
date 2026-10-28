@preconcurrency import AVFoundation
import DAWControl
import DAWModel
import Foundation
import MCP
import Testing

@testable import dawmcp

// Helpers for the dawmcp suites.

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
