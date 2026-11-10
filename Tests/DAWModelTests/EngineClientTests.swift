import DAWEngine
import Foundation
import Testing

@testable import DAWModel

// T-014: EngineClient over the real C++ facade, in offline mode (BRIDGE-001..008). Facade
// internals that need C++ (a fake device driver, param-reading test nodes) are in
// Tests/DAWEngineTests/FacadeTests.swift.

/// A graph of just the master (1). No audio node kinds are registered yet (T-013), so this is
/// what offline renders can be built from.
private func masterGraph() -> EngineGraph {
    EngineGraph(nodes: [.init(id: 1, kind: .master)], master: 1)
}

/// Writes a mono 16-bit PCM WAV of a 1 kHz sine at half scale.
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

/// A fresh folder under $TMPDIR, unique per call (CONV §9).
private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "engineclient-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("EngineClient (BRIDGE)")
struct EngineClientTests {
    @Test("BRIDGE-001: the facade is a Swift class reference; created and destroyed repeatedly without leaks")
    func createDestroy() throws {
        var ids: [UInt64] = []
        for _ in 0..<50 {
            let client = try EngineClient(.offline())
            let copy: any EngineProtocol = client  // extra Swift references are balanced
            #expect(EngineClient.isLive(client.instanceID))
            #expect(copy.telemetry().sampleRate == 48_000)
            ids.append(client.instanceID)
        }
        #expect(Set(ids).count == 50)
        #expect(ids.allSatisfy { !EngineClient.isLive($0) })
    }

    @Test("BRIDGE-008: offline mode at the session rate; a bad rate throws; offline has no device")
    func modes() throws {
        let offline = try EngineClient(.offline(sampleRate: 44_100))
        #expect(offline.telemetry().sampleRate == 44_100)
        #expect(offline.mode == .offline(sampleRate: 44_100))
        #expect(throws: DAWError.self) { try EngineClient(.offline(sampleRate: 10)) }

        // Realtime mode would start CoreAudio, which tests never do; the driver seam is covered
        // with a fake driver in DAWEngineTests (FacadeTests).
        #expect(offline.devices().isEmpty)
        #expect(!offline.telemetry().deviceRunning)
        #expect(throws: DAWError.self) { try offline.setDevice(DriverConfig()) }
    }

    @Test("BRIDGE-003: EngineGraph crosses as a GraphDescription built through GraphDescriptionBuilder")
    func buildsDescription() {
        let graph = EngineGraph(
            nodes: [.init(id: 1, kind: .master), .init(id: 2, kind: .audioClipPlayer, configVersion: 3,
                                                       firstParam: 7, numParams: 2, configJSON: "{\"a\":1}")],
            edges: [.init(id: 10, from: 2, to: 1, kind: .sidechain)],
            audioClips: [.init(player: 2, clipID: 20, start: 960, length: 1920, assetID: 5,
                               sourceOffsetSamples: 100, gain: 0.5, fadeIn: 10, fadeOut: 20)],
            notes: [.init(player: 2, start: 0, length: 480, pitch: 60, velocity: 100, channel: 1)],
            tempoEvents: [TempoEvent(tick: 0, bpm: 90), TempoEvent(tick: 3840, bpm: 140)],
            timeSignatures: [TimeSignatureEvent(tick: 0, numerator: 7, denominator: 8)],
            master: 1)
        // Every field survives the trip through daw::GraphDescriptionBuilder and back.
        #expect(EngineClient.roundTrip(graph) == graph)

        // Swift can also use the C++ builder directly.
        var builder = daw.GraphDescriptionBuilder()
        builder.addNode(1, .master, 0, 0, 0, std.string(""))
        builder.addNode(2, .bus, 1, 4, 2, std.string("{}"))
        builder.addEdge(10, 2, 1, .sidechain, 0)
        builder.setTempo(0, 90)
        builder.setTimeSignature(0, 7, 8)
        builder.setMaster(1)
        let desc = builder.description()
        #expect(desc.nodes.size() == 2 && desc.edges.size() == 1 && desc.master == 1)
        #expect(desc.nodes[1].firstParam == 4 && desc.nodes[1].numParams == 2)
        #expect(desc.tempo.tempos[0].bpm == 90 && desc.tempo.timeSigs[0].num == 7)
    }

    @Test("DW-047: applyGraph stamps versions; telemetry reports the one rendering")
    func graphVersions() throws {
        let engine = try EngineClient(.offline())
        #expect(engine.graphStatus() == GraphStatus())
        let v1 = engine.applyGraph(masterGraph())
        let v2 = engine.applyGraph(masterGraph())
        #expect(v1 == 1 && v2 == 2)
        let status = engine.waitForGraph(v2, timeout: .seconds(5))
        #expect(status.completedVersion == 2 && status.publishedVersion == 2 && status.lastError == nil)
        #expect(engine.telemetry().graphVersion == 2)
    }

    @Test("DW-050: a routing cycle is rejected as DAWError.routingCycle with its NodeIDs; the old graph stays")
    func cycleRejected() async throws {
        let engine = try EngineClient(.offline())
        let good = engine.applyGraph(masterGraph())
        engine.waitForGraph(good, timeout: .seconds(5))  // else the cycle supersedes it unbuilt (coalescing)
        let cycle = EngineGraph(
            nodes: [.init(id: 1, kind: .master), .init(id: 2, kind: .bus), .init(id: 3, kind: .bus)],
            edges: [.init(id: 10, from: 2, to: 3), .init(id: 11, from: 3, to: 2), .init(id: 12, from: 3, to: 1)],
            master: 1)
        let bad = engine.applyGraph(cycle)
        let status = await engine.graphApplied(bad)
        #expect(status.publishedVersion == good)
        #expect(status.lastError == .routingCycle(path: [2, 3]))
        let rejected = engine.pollEvents().filter { $0.kind == .graphRejected }
        #expect(rejected == [EngineEvent(kind: .graphRejected, subject: bad, error: .routingCycle(path: [2, 3]))])
    }

    @Test("ENG-020/021, DW-029: params allocate, write without rebuilding, and free once no graph reads them")
    func params() throws {
        let engine = try EngineClient(.offline())
        let first = try engine.allocateParams(3)
        engine.setParam(first + 1, 0.75)
        #expect(engine.getParam(first + 1) == 0.75)
        #expect(engine.getParam(.max) == 0)
        #expect(throws: DAWError.self) { try engine.allocateParams(0) }

        engine.waitForGraph(engine.applyGraph(masterGraph()), timeout: .seconds(5))
        engine.freeParams(first, count: 3)
        #expect(engine.telemetry().paramsPendingFree == 3)  // the current graph may read them
        engine.waitForGraph(engine.applyGraph(masterGraph()), timeout: .seconds(5))
        let t = engine.telemetry()
        #expect(t.paramsPendingFree == 0 && t.paramsAllocated == 0)
        #expect(engine.graphStatus().submittedVersion == 2)  // setParam applied no graph
    }

    @Test("TIME-004/009: transport commands apply and read back in offline mode once a graph exists")
    func transport() throws {
        let engine = try EngineClient(.offline())
        engine.locate(960)
        #expect(engine.transport().tick == 0)  // queued: no graph to render a block with yet
        engine.waitForGraph(engine.applyGraph(masterGraph()), timeout: .seconds(5))
        #expect(engine.transport().tick == 960)
        #expect(engine.transport().sample == 24_000)  // 120 bpm at 48 kHz
        engine.play()
        engine.setLoop(enabled: true, start: 0, end: 3840)
        engine.setRecording(true)
        var t = engine.transport()
        #expect(t.playing && t.loopEnabled && t.loopEnd == 3840 && t.recording)
        engine.stop()
        engine.setRecording(false)
        t = engine.transport()
        #expect(!t.playing && !t.recording)
    }

    @Test("IO-031, DW-041, BRIDGE-002/004: loadAsset decodes and resamples on daw.loader; status and events report it")
    func loadAsset() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appending(path: "sine.wav")
        try writeSineWAV(wav, sampleRate: 44_100, frames: 44_100)

        let engine = try EngineClient(.offline(sampleRate: 48_000))
        let job = engine.loadAsset(7, path: wav.path)
        #expect(job != 0)
        let status = await engine.waitForJob(job)
        #expect(status.state == .succeeded && status.kind == .loadAsset && status.progress == 1)
        let asset = try #require(status.asset)
        #expect(asset.assetID == 7 && asset.channels == 1 && asset.resampled)
        #expect(asset.fileSampleRate == 44_100 && asset.fileFrames == 44_100)
        #expect(asset.sampleRate == 48_000 && abs(asset.frames - 48_000) <= 1)
        #expect(engine.telemetry().assetsLoaded == 1)

        let missing = engine.loadAsset(8, path: dir.appending(path: "nope.wav").path)
        let failed = await engine.waitForJob(missing)
        #expect(failed.state == .failed)
        if case .engine(.notFound, _)? = failed.error {} else { Issue.record("DW-076: expected .engine(.notFound), got \(String(describing: failed.error))") }
        #expect(engine.loadAsset(9, path: "") == 0)

        let events = engine.pollEvents()
        #expect(events.contains(EngineEvent(kind: .assetLoaded, subject: 7, job: job)))
        #expect(events.contains { $0.kind == .assetLoadFailed && $0.subject == 8 && $0.error != nil })
        #expect(events.filter { $0.kind == .jobFinished }.count == 2)
        #expect(engine.pollEvents().isEmpty)
    }

    @Test("IO-010..013, DW-056/057/064: renderOffline renders the applied graph to a file on a job thread, 0 RT violations")
    func renderOffline() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = try EngineClient(.offline())

        let noGraph = await engine.waitForJob(engine.renderOffline(from: 0, to: 3840, spec: ExportSpec(path: "")))
        #expect(noGraph.state == .failed)

        engine.applyGraph(masterGraph())  // the export waits for it to build
        engine.setRecording(true)
        let path = dir.appending(path: "out.wav").path
        let spec = ExportSpec(path: path, sampleFormat: .int24, blockSize: 256, tailEnabled: false)
        let status = await engine.waitForJob(engine.renderOffline(from: 0, to: 3840, spec: spec))
        #expect(status.state == .succeeded && status.error == nil)
        let render = try #require(status.render)
        #expect(render.framesWritten == 96_000 && render.durationSeconds == 2)
        #expect(render.rtViolations == 0)  // IO-013
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(!engine.transport().recording)  // DW-064
        #expect(engine.telemetry().rtViolations == 0)

        var tooBig = spec
        tooBig.blockSize = 8192
        let rejected = engine.pollJob(engine.renderOffline(from: 0, to: 3840, spec: tooBig))
        #expect(rejected.state == .failed)  // DW-056: above the graph's maxBlock
    }

    @Test("BRIDGE-005/006, DW-017: telemetry, meters, plugin stubs and param info cross as Swift values")
    func observability() throws {
        let engine = try EngineClient(.offline())
        engine.waitForGraph(engine.applyGraph(masterGraph()), timeout: .seconds(5))
        let t = engine.telemetry()
        #expect(t.rtViolations == 0 && t.graphVersion == 1 && t.sampleRate == 48_000 && !t.deviceRunning)
        #expect(engine.nodeLatencies().isEmpty)
        #expect(engine.meter(1) == nil)
        // DW-160 (T-026): sends (GainNode) and the metronome publish their slots; kinds without
        // published ParamInfo still give an empty list.
        #expect(ParamCatalog.parseDefaults(engine.paramInfoJSON(.gain)) == [1, 0])
        // DSP-041, DW-141 (T-070): the sampler and EQ publish their tables through the registry; a
        // sampler's slots start at the defaults it runs at without them, so no project changes sound.
        #expect(ParamCatalog.parseDefaults(engine.paramInfoJSON(.sampler)) == [0.002, 0.3, 1, 0.2, 1])
        #expect(ParamCatalog.parseDefaults(engine.paramInfoJSON(.eq)).count == 22)
        #expect(engine.paramInfoJSON(.audioClipPlayer) == "[]")  // no params (reverb publishes since T-073)
        // T-061 (PLUG-012/016): an AU is instantiated and parked for the slot; its state crosses as
        // Data (a binary plist), and a state it refuses is reported as an event.
        let job = engine.instantiatePlugin(slot: 5, .audioUnit(AUDescriptor(identifier: "aufx:dely:appl", name: "Delay")))
        #expect(engine.pollJob(job).state == .succeeded)
        let state = engine.pluginState(slot: 5)
        #expect(state.starts(with: Data("bplist".utf8)))
        engine.setPluginState(slot: 5, Data([1, 2, 3]))
        #expect(engine.pluginState(slot: 5) == state)
        #expect(engine.pollEvents().contains { $0.kind == .pluginCrashed && $0.subject == 5 })
        let vst3 = engine.instantiatePlugin(slot: 6, .vst3(VST3Descriptor(identifier: "/x.vst3#00", name: "X")))
        #expect(engine.pollJob(vst3).state == .failed)
        engine.armInput(track: 2, inputChannelPair: 0, armed: true)
    }
}

@Suite("FakeEngine (BRIDGE-007)")
struct FakeEngineTests {
    @Test("BRIDGE-007: the model drives the engine through EngineProtocol; FakeEngine records it")
    func recordsCalls() throws {
        let fake = FakeEngine()
        let engine: any EngineProtocol = fake
        let fader = try engine.allocateParams(2)
        let version = engine.applyGraph(masterGraph())
        fake.clearCalls()
        // MODEL-021's acceptance in miniature: a param change writes the slot, no graph.
        engine.setParam(fader, 0.5)
        #expect(fake.calls == [.setParam(fader, 0.5)])
        #expect(engine.getParam(fader) == 0.5)
        #expect(engine.graphStatus().publishedVersion == version)
        #expect(fake.appliedGraphs == [masterGraph()])
    }

    @Test("FakeEngine mirrors the engine's graph rejection, asset events and jobs")
    func mirrorsEngine() async {
        let fake = FakeEngine()
        fake.rejectNextGraph(with: .routingCycle(path: [2, 3]))
        let bad = fake.applyGraph(masterGraph())
        #expect(fake.graphStatus().lastError == .routingCycle(path: [2, 3]))
        #expect(fake.graphStatus().publishedVersion == 0)
        #expect(fake.pollEvents() == [EngineEvent(kind: .graphRejected, subject: bad, error: .routingCycle(path: [2, 3]))])

        fake.failLoads(of: "/missing.wav")
        let ok = fake.loadAsset(4, path: "/a.wav")
        let failed = fake.loadAsset(5, path: "/missing.wav")
        #expect(await fake.waitForJob(ok).asset?.assetID == 4)
        #expect(fake.pollJob(failed).state == .failed)
        let kinds = fake.pollEvents().map(\.kind)
        #expect(kinds == [.jobFinished, .assetLoaded, .jobFinished, .assetLoadFailed])

        fake.play()
        fake.locate(960)
        #expect(fake.transport().playing && fake.transport().tick == 960)
    }

    @Test("DW-076: engine I/O, out-of-memory, not-found and internal errors map to DAWError.engine")
    func errorMapping() {
        func facadeError(_ code: daw.FacadeErrorCode, _ message: String = "m") -> daw.FacadeError {
            var e = daw.FacadeError()
            e.code = code
            e.message = std.string(message)
            return e
        }
        #expect(EngineClient.error(facadeError(.none)) == nil)
        #expect(EngineClient.error(facadeError(.io, "cannot open x")) == .engine(code: .io, detail: "cannot open x"))
        #expect(EngineClient.error(facadeError(.outOfMemory)) == .engine(code: .outOfMemory, detail: "m"))
        #expect(EngineClient.error(facadeError(.notFound)) == .engine(code: .notFound, detail: "m"))
        #expect(EngineClient.error(facadeError(.internal)) == .engine(code: .internal, detail: "m"))
        #expect(EngineClient.error(facadeError(.invalidArgument)) == .invalidArgument("m"))
        #expect(DAWError.engine(code: .io, detail: "x").code == "engine")
    }
}
