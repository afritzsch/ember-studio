@preconcurrency import AVFoundation
import DAWControl
import DAWModel
import Foundation
import Testing

// Test commands, audio files and dispatchers for the DAWControl suites. The model's command
// catalogue is still small (T-022/T-030 add the rest), so tracks and clips come from test-only
// commands. All test targets share one process and one CommandRegistry, so every type string here
// is prefixed to stay clear of DAWModelTests' commands.

enum ControlTestCommands {
    /// Idempotent, so every suite can call it.
    static func register() {
        CommandRegistry.register(ControlTestAddAudioTrack.self)
        CommandRegistry.register(ControlTestRemoveTrack.self)
        CommandRegistry.register(ControlTestAddAudioClip.self)
        CommandRegistry.register(ControlTestSetTrack.self)
        CommandRegistry.register(ControlTestInsertTrack.self)
        CommandRegistry.register(ControlTestRemoveAsset.self)
        // asset.import performs `ImportAsset` (Dispatcher.importAssetCommandType), which DAWModel
        // doesn't define yet. Once it does, its own type is used and has to accept this shape.
        if CommandRegistry.commandType(named: Dispatcher.importAssetCommandType) == nil {
            CommandRegistry.register(ControlTestImportAsset.self)
        }
    }
}

struct ControlTestAddAudioTrack: Command {
    static let type = "ControlTestAddAudioTrack"
    var name: String
    var label: String { "Add Track" }

    func apply(to project: inout Project) throws(DAWError) -> any Command {
        let id = project.ids.allocate()
        project.tracks.append(Track(id: id, name: name, kind: .audio))
        return ControlTestRemoveTrack(trackID: id)
    }
}

struct ControlTestRemoveTrack: Command {
    static let type = "ControlTestRemoveTrack"
    var trackID: NodeIDValue
    var label: String { "Remove Track" }

    func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let index = project.trackIndex(trackID) else { throw .notFound(kind: "track", id: trackID) }
        let track = project.tracks.remove(at: index)
        return ControlTestInsertTrack(track: track, index: index)
    }
}

struct ControlTestInsertTrack: Command {
    static let type = "ControlTestInsertTrack"
    var track: Track
    var index: Int
    var label: String { "Remove Track" }

    func apply(to project: inout Project) throws(DAWError) -> any Command {
        project.ids.reserve(track.id)
        project.tracks.insert(track, at: min(index, project.tracks.count))
        return ControlTestRemoveTrack(trackID: track.id)
    }
}

struct ControlTestAddAudioClip: Command {
    static let type = "ControlTestAddAudioClip"
    var trackID: NodeIDValue
    var assetID: ModelID
    var start: Tick
    var length: Tick
    var label: String { "Add Clip" }

    func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard project.assets.contains(where: { $0.id == assetID }) else { throw .notFound(kind: "asset", id: assetID) }
        let id = project.ids.allocate()
        let old = try project.updateTrack(trackID) { track in
            defer { track.clips.append(.audio(AudioClip(id: id, assetID: assetID, start: start, length: length))) }
            return track
        }
        return ControlTestSetTrack(track: old)
    }
}

/// Replaces the track with the same ID (an inverse that restores a whole track).
struct ControlTestSetTrack: Command {
    static let type = "ControlTestSetTrack"
    var track: Track
    var label: String { "Edit Track" }

    func apply(to project: inout Project) throws(DAWError) -> any Command {
        let old = try project.updateTrack(track.id) { current in
            defer { current = track }
            return current
        }
        return ControlTestSetTrack(track: old)
    }
}

/// The shape `asset.import` sends: `{"type": "ImportAsset", "asset": AssetRef}`.
struct ControlTestImportAsset: Command {
    static let type = Dispatcher.importAssetCommandType
    var asset: AssetRef
    var label: String { "Import Asset" }

    func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard !project.assets.contains(where: { $0.id == asset.id }) else {
            throw .invalidArgument("asset \(asset.id) exists")
        }
        project.ids.reserve(asset.id)
        project.assets.append(asset)
        return ControlTestRemoveAsset(assetID: asset.id)
    }
}

struct ControlTestRemoveAsset: Command {
    static let type = "ControlTestRemoveAsset"
    var assetID: ModelID
    var label: String { "Import Asset" }

    func apply(to project: inout Project) throws(DAWError) -> any Command {
        guard let index = project.assets.firstIndex(where: { $0.id == assetID }) else {
            throw .notFound(kind: "asset", id: assetID)
        }
        return ControlTestImportAsset(asset: project.assets.remove(at: index))
    }
}

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
