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

// MARK: Child processes

/// Waits for a child process to exit by polling `isRunning`, as `AttachedApp.terminate` does.
/// Use this, not `Process.waitUntilExit()`, in tests. An async test can launch the child on one
/// cooperative thread and wait from another after an `await`. `waitUntilExit()` then spins the
/// waiting thread's run loop for an exit event that never comes there, and blocks forever (a 4 h
/// hang in AttachTests even though the child had exited and been reaped). On timeout this records
/// an issue, SIGKILLs the child, polls a little longer, and returns false. Read
/// `terminationStatus` only after a true result: reading it while the child runs raises.
@discardableResult
func waitForExit(_ process: Process, timeout: Duration = .seconds(10),
                 sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while process.isRunning {
        guard clock.now < deadline else {
            Issue.record("pid \(process.processIdentifier) still running after \(timeout); SIGKILL", sourceLocation: sourceLocation)
            kill(process.processIdentifier, SIGKILL)
            let killed = clock.now + .seconds(5)
            while process.isRunning && clock.now < killed { usleep(10_000) }
            return false
        }
        usleep(10_000)
    }
    return true
}
