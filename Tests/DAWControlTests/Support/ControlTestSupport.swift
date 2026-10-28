@preconcurrency import AVFoundation
import DAWControl
import DAWModel
import Foundation
import Testing

// Audio files and dispatchers for the DAWControl suites. Projects are built with DAWModel's own
// commands (DW-128: the test-only track, clip and asset commands are gone now that AddTrack,
// AddClip and ImportAsset exist).

// MARK: Files

/// A fresh folder under $TMPDIR, unique per call (CONV §9). Removed when the value is dropped.
final class TempDir: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "dawcontrol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String) -> URL { url.appending(path: name) }
}

enum TestAudio {
    /// Writes float32 WAV/CAF/AIFF (by extension).
    static func write(_ channels: [[Float]], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels.count, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = channels.first?.count ?? 0
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(frames, 1))))
        buffer.frameLength = AVAudioFrameCount(frames)
        for (c, samples) in channels.enumerated() {
            for i in 0..<frames { buffer.floatChannelData![c][i] = samples[i] }
        }
        try file.write(from: buffer)
        // Finalize the header now; the object may otherwise outlive this call in an autorelease pool.
        file.close()
    }

    static func sine(frequency: Double, amplitude: Double, sampleRate: Double, frames: Int, phase: Double = 0) -> [Float] {
        (0..<frames).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / sampleRate + phase)) }
    }
}

// MARK: Dispatchers

@MainActor
enum TestDispatchers {
    /// Headless over FakeEngine; `engines` collects every engine it creates.
    static func fake(
        mode: Dispatcher.Mode = .headless, engineMode: EngineMode? = nil, fixtures: [URL] = [], ui: (any ControlUIProvider)? = nil,
        workingDirectory: URL? = nil
    ) -> (Dispatcher, EngineBox) {
        let box = EngineBox()
        let config = Dispatcher.Configuration(
            mode: mode,
            makeEngine: { rate throws(DAWError) in
                let engine = FakeEngine(mode: engineMode ?? .offline(sampleRate: rate))
                box.engines.append(engine)
                return engine
            },
            workingDirectory: workingDirectory ?? FileManager.default.temporaryDirectory,
            fixtureDirectories: fixtures, jobTimeout: .seconds(5), graphTimeout: .seconds(5), ui: ui)
        return (Dispatcher(configuration: config), box)
    }

    /// Headless over the real offline engine, as `dawctl` runs.
    static func real(workingDirectory: URL) -> Dispatcher {
        Dispatcher(configuration: .init(workingDirectory: workingDirectory))
    }
}

@MainActor
final class EngineBox {
    var engines: [FakeEngine] = []
    var last: FakeEngine { engines.last! }
}

extension Dispatcher {
    /// Calls and expects success.
    func ok(_ method: ControlMethod, _ params: JSONValue? = nil, sourceLocation: SourceLocation = #_sourceLocation) async throws -> JSONValue {
        do {
            return try await call(method, params)
        } catch {
            Issue.record("\(method.rawValue) failed: \(error.rpcError.message)", sourceLocation: sourceLocation)
            throw error
        }
    }

    /// Calls and expects a failure; returns its wire form.
    func failure(_ method: ControlMethod, _ params: JSONValue? = nil, sourceLocation: SourceLocation = #_sourceLocation) async -> RPCError? {
        do {
            let result = try await call(method, params)
            Issue.record("\(method.rawValue) succeeded with \(result.jsonString())", sourceLocation: sourceLocation)
            return nil
        } catch {
            return error.rpcError
        }
    }
}
