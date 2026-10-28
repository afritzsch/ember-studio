import DAWControl
import DAWModel
import Foundation
import Testing

// CTL-002: every v1 method through the headless dispatcher. FakeEngine stands in for the engine
// here; DeterminismTests and DawctlTests run the real one.

private func addTrack(_ name: String) -> JSONValue {
    ["type": "AddTrack", "name": .string(name), "kind": "audio"]
}

@Suite("Dispatcher methods (CTL-002)")
@MainActor
struct DispatcherMethodTests {
    // MARK: project.*

    @Test("CTL-002 project.new: a project at the given rate with a fresh engine; headless IDs are sequential (DW-033)")
    func projectNew() async throws {
        let (dispatcher, box) = TestDispatchers.fake()
        let first = try await dispatcher.ok(.projectNew, ["name": "a"])
        #expect(first["projectID"] == "00000000-0000-0000-0000-000000000001")
        #expect(dispatcher.store?.project.sessionSampleRate == 48_000)
        let second = try await dispatcher.ok(.projectNew, ["name": "b", "sampleRate": 44_100])
        #expect(second["projectID"] == "00000000-0000-0000-0000-000000000002")
        #expect(dispatcher.store?.project.name == "b" && dispatcher.store?.project.sessionSampleRate == 44_100)
        #expect(box.engines.count == 2 && box.last.mode == .offline(sampleRate: 44_100))
        #expect(box.last.appliedGraphs.count == 1, "the new project's graph is applied at once")

        let bad = await dispatcher.failure(.projectNew, ["name": "c", "sampleRate": 0])
        #expect(bad?.dawError == "invalidTempoMap")
        #expect(dispatcher.store?.project.name == "b", "a failed project.new keeps the current project")
    }

    @Test("CTL-002 project.new in attach mode uses random IDs")
    func projectNewAttach() async throws {
        let (dispatcher, _) = TestDispatchers.fake(mode: .attach)
        let id = try await dispatcher.ok(.projectNew, ["name": "a"])["projectID"]?.stringValue
        #expect(id != nil && id != "00000000-0000-0000-0000-000000000001")
    }

    @Test("CTL-002 project.open / project.save are wired to ProjectStore (not implemented until T-031)")
    func openSave() async throws {
        let (dispatcher, _) = TestDispatchers.fake()
        #expect(await dispatcher.failure(.projectSave)?.dawError == "noProject")
        _ = try await dispatcher.ok(.projectNew, ["name": "a"])
        let save = await dispatcher.failure(.projectSave, ["path": "/tmp/x.dawproject"])
        #expect(save?.dawError == "notImplemented")
        let open = await dispatcher.failure(.projectOpen, ["path": "x.dawproject", "recover": true])
        #expect(open?.dawError == "notImplemented")
        #expect(await dispatcher.failure(.projectOpen, [:])?.dawError == "invalidParams")
    }

    @Test("CTL-002 project.get: the project JSON, or a subtree by JSON Pointer")
    func projectGet() async throws {
        let (dispatcher, _) = TestDispatchers.fake()
        #expect(await dispatcher.failure(.projectGet)?.dawError == "noProject")
        _ = try await dispatcher.ok(.projectNew, ["name": "Song"])
        let all = try await dispatcher.ok(.projectGet)
        #expect(all["name"] == "Song" && all["sessionSampleRate"] == 48_000 && all["tracks"] == [])
        #expect(try await dispatcher.ok(.projectGet, ["path": "/master/id"]) == 1)
        #expect(await dispatcher.failure(.projectGet, ["path": "/tracks/3"])?.dawError == "invalidParams")
    }

    // MARK: command.*, undo, redo

    @Test("CTL-002 command.apply: performs a Command from its JSON and reports the IDs it created")
    func commandApply() async throws {
        let (dispatcher, box) = TestDispatchers.fake()
        _ = try await dispatcher.ok(.projectNew, ["name": "a"])
        let added = try await dispatcher.ok(.commandApply, ["command": addTrack("Drums")])
        #expect(added == ["ok": true, "createdIDs": [2], "label": "Add Track"])
        #expect(box.last.appliedGraphs.count == 2, "a structural change is applied synchronously in headless mode")

        let renamed = try await dispatcher.ok(.commandApply, ["command": ["type": "RenameTrack", "trackID": 2, "name": "Kick"]])
        #expect(renamed["createdIDs"] == [] && renamed["label"] == "Rename Track")
        #expect(dispatcher.store?.project.tracks.map(\.name) == ["Kick"])

        #expect(await dispatcher.failure(.commandApply, ["command": ["type": "Nope"]])?.dawError == "unknownCommandType")
        #expect(await dispatcher.failure(.commandApply, ["command": ["type": "RenameTrack"]])?.dawError == "malformedCommand")
        #expect(await dispatcher.failure(.commandApply, ["command": ["type": "RenameTrack", "trackID": 77, "name": "x"]])?.dawError == "notFound")
        #expect(await dispatcher.failure(.commandApply, [:])?.dawError == "invalidParams")
    }

    @Test("CTL-002 command.batch atomic: one undo entry, all or nothing")
    func batchAtomic() async throws {
        let (dispatcher, _) = TestDispatchers.fake()
        _ = try await dispatcher.ok(.projectNew, ["name": "a"])
        let result = try await dispatcher.ok(.commandBatch, ["atomic": true, "commands": [addTrack("A"), addTrack("B")]])
        #expect(result["results"]?[0]?["createdIDs"] == [2] && result["results"]?[1]?["createdIDs"] == [3])
        #expect(dispatcher.store?.project.tracks.map(\.id) == [2, 3], "the dry run and the real apply allocate the same IDs")
        #expect(try await dispatcher.ok(.undo) == ["label": "Batch"])
        #expect(dispatcher.store?.project.tracks.isEmpty == true)

        let failed = await dispatcher.failure(.commandBatch, [
            "atomic": true, "commands": [addTrack("C"), ["type": "RenameTrack", "trackID": 99, "name": "x"]],
        ])
        #expect(failed?.dawError == "notFound" && failed?.data?["index"] == 1)
        #expect(dispatcher.store?.project.tracks.isEmpty == true, "nothing applied")
        #expect(await dispatcher.failure(.commandBatch, ["atomic": true, "commands": [addTrack("D"), ["type": "?"]]])?.data?["index"] == 1)
    }

    @Test("CTL-002 command.batch non-atomic: one undo entry each, stopping at the first failure")
    func batchSequential() async throws {
        let (dispatcher, _) = TestDispatchers.fake()
        _ = try await dispatcher.ok(.projectNew, ["name": "a"])
        let failed = await dispatcher.failure(.commandBatch, [
            "commands": [addTrack("A"), ["type": "RenameTrack", "trackID": 99, "name": "x"], addTrack("B")],
        ])
        #expect(failed?.data?["index"] == 1)
        #expect(failed?.data?["results"]?[0]?["createdIDs"] == [2])
        #expect(dispatcher.store?.project.tracks.map(\.name) == ["A"], "the one before the failure stays applied")

        let ok = try await dispatcher.ok(.commandBatch, ["atomic": false, "commands": [addTrack("C"), addTrack("D")]])
        #expect(ok["ok"] == true && ok["results"]?.arrayValue?.count == 2)
        _ = try await dispatcher.ok(.undo)
        #expect(dispatcher.store?.project.tracks.map(\.name) == ["A", "C"])
    }

    @Test("CTL-002 undo / redo: report the label, null when there is nothing to do")
    func undoRedo() async throws {
        let (dispatcher, _) = TestDispatchers.fake()
        _ = try await dispatcher.ok(.projectNew, ["name": "a"])
        #expect(try await dispatcher.ok(.undo) == ["label": nil])
        _ = try await dispatcher.ok(.commandApply, ["command": addTrack("A")])
        #expect(try await dispatcher.ok(.undo) == ["label": "Add Track"])
        #expect(dispatcher.store?.project.tracks.isEmpty == true)
        #expect(try await dispatcher.ok(.redo) == ["label": "Add Track"])
        #expect(dispatcher.store?.project.tracks.count == 1)
        #expect(try await dispatcher.ok(.redo) == ["label": nil])
    }

    // MARK: transport.*

    @Test("CTL-002 transport.play/stop/locate/setLoop/record drive the engine and return its transport")
    func transport() async throws {
        let (dispatcher, box) = TestDispatchers.fake()
        #expect(await dispatcher.failure(.transportPlay)?.dawError == "noProject")
        _ = try await dispatcher.ok(.projectNew, ["name": "a"])
        #expect(try await dispatcher.ok(.transportLocate, ["tick": 1920])["tick"] == 1920)
        #expect(try await dispatcher.ok(.transportPlay)["playing"] == true)
        let loop = try await dispatcher.ok(.transportSetLoop, ["enabled": true, "start": 0, "end": 3840])
        #expect(loop["loopEnabled"] == true && loop["loopEnd"] == 3840)
        #expect(try await dispatcher.ok(.transportRecord, ["enabled": true])["recording"] == true)
        #expect(try await dispatcher.ok(.transportStop)["playing"] == false)
        #expect(box.last.calls.contains(.locate(1920)))

        #expect(await dispatcher.failure(.transportSetLoop, ["enabled": true, "start": 960, "end": 960])?.dawError == "invalidArgument")
        #expect(await dispatcher.failure(.transportLocate, ["tick": -1])?.dawError == "invalidArgument")
        #expect(await dispatcher.failure(.transportLocate, ["tick": "x"])?.dawError == "invalidParams")
    }

    @Test("DW-123: transport.setLoop performs SetLoop, so the project's loop follows; clearing sets it to null")
    func setLoopFollowsProject() async throws {
        let (dispatcher, box) = TestDispatchers.fake()
        _ = try await dispatcher.ok(.projectNew, ["name": "a"])
        _ = try await dispatcher.ok(.transportSetLoop, ["enabled": true, "start": 960, "end": 4800])
        #expect(try await dispatcher.ok(.projectGet, ["path": "/loop"]) == ["start": 960, "end": 4800, "isEnabled": true])
        #expect(dispatcher.store?.undoLabel == "Set Loop")
        _ = try await dispatcher.ok(.transportSetLoop, ["enabled": false, "start": 960, "end": 4800])
        #expect(try await dispatcher.ok(.projectGet, ["path": "/loop/isEnabled"]) == false)
        let cleared = try await dispatcher.ok(.transportSetLoop, ["enabled": false])
        #expect(cleared["loopEnabled"] == false)
        #expect(dispatcher.store?.project.loop == nil)
        _ = try await dispatcher.ok(.undo)
        #expect(dispatcher.store?.project.loop == LoopRange(start: 960, end: 4800, isEnabled: false))

        // SetLoop's own checks apply (MODEL-005: at least 4096 samples), and a refused loop never
        // reaches the engine.
        let calls = box.last.calls.count
        #expect(await dispatcher.failure(.transportSetLoop, ["enabled": true, "start": 0, "end": 10])?.dawError == "invalidArgument")
        #expect(await dispatcher.failure(.transportSetLoop, ["enabled": true])?.dawError == "invalidParams")
        #expect(box.last.calls.count == calls)
    }

    @Test("CTL-002 transport.wait: needs a live engine; returns at the tick or times out with the position")
    func transportWait() async throws {
        let (offline, _) = TestDispatchers.fake()
        _ = try await offline.ok(.projectNew, ["name": "a"])
        #expect(await offline.failure(.transportWait, ["timeoutMs": 10])?.dawError == "invalidArgument")

        let (live, _) = TestDispatchers.fake(engineMode: .realtime(DriverConfig(sampleRate: 48_000)))
        _ = try await live.ok(.projectNew, ["name": "a"])
        _ = try await live.ok(.transportLocate, ["tick": 2000])
        #expect(try await live.ok(.transportWait, ["untilTick": 1000, "timeoutMs": 1000])["tick"] == 2000)
        #expect(try await live.ok(.transportWait, ["timeoutMs": 1000])["playing"] == false, "without untilTick: until stopped")
        _ = try await live.ok(.transportPlay)
        let timeout = await live.failure(.transportWait, ["untilTick": 1_000_000, "timeoutMs": 20])
        #expect(timeout?.code == -32003 && timeout?.data?["transport"]?["tick"] == 2000)
    }

    // MARK: asset.import, render.offline

    @Test("CTL-002 asset.import: loads the file in the engine, then performs ImportAsset with the loaded info")
    func assetImport() async throws {
        let dir = try TempDir()
        try TestAudio.write([[0, 0.5, 0]], sampleRate: 48_000, to: dir.file("a.wav"))
        let (dispatcher, box) = TestDispatchers.fake(workingDirectory: dir.url)
        _ = try await dispatcher.ok(.projectNew, ["name": "a"])
        let result = try await dispatcher.ok(.assetImport, ["path": "a.wav"])
        #expect(result["assetID"] == 2 && result["channels"] == 2 && result["resampled"] == false)
        let asset = try #require(dispatcher.store?.project.assets.first)
        #expect(asset.id == 2 && asset.path == dir.file("a.wav").standardizedFileURL.path)
        #expect(box.last.calls.contains(.loadAsset(2, path: asset.path)))
        let events = try await dispatcher.ok(.engineEvents)["events"]?.arrayValue ?? []
        #expect(events.contains { $0["event"]?["kind"] == "assetLoaded" && $0["event"]?["subject"] == 2 })
        #expect(try await dispatcher.ok(.undo) == ["label": "Import Asset"])

        #expect(await dispatcher.failure(.assetImport, ["path": "missing.wav"])?.dawError == "invalidArgument")
        box.last.failLoads(of: dir.file("a.wav").standardizedFileURL.path)
        #expect(await dispatcher.failure(.assetImport, ["path": "a.wav"])?.dawError == "engine")
        #expect(dispatcher.store?.project.assets.isEmpty == true, "a failed load leaves the project untouched")
    }

    @Test("CTL-002 render.offline: applies pending changes first (DW-095), resolves the path, reports the job")
    func renderOffline() async throws {
        let dir = try TempDir()
        let (dispatcher, box) = TestDispatchers.fake(workingDirectory: dir.url)
        #expect(await dispatcher.failure(.renderOffline, ["from": 0, "to": 960, "path": "x.wav"])?.dawError == "noProject")
        _ = try await dispatcher.ok(.projectNew, ["name": "a"])
        let result = try await dispatcher.ok(.renderOffline, ["from": 0, "to": 960, "path": "out/x.wav", "format": "caf", "tail": false])
        let path = dir.file("out/x.wav").standardizedFileURL.path
        #expect(result["path"] == .string(path) && result["rtViolations"] == 0)
        #expect(box.last.calls.last == .renderOffline(from: 0, to: 960, path: path))
        #expect(FileManager.default.fileExists(atPath: dir.file("out").path), "the folder is created")
        #expect(await dispatcher.failure(.renderOffline, ["from": 960, "to": 960, "path": "x.wav"])?.dawError == "invalidArgument")
        #expect(await dispatcher.failure(.renderOffline, ["from": 0, "to": 960, "path": "x.wav", "format": "mp3"])?.dawError == "invalidParams")
    }

    // MARK: audio.*

    @Test("CTL-002 audio.analyze / audio.compare read files relative to the working directory")
    func audioMethods() async throws {
        let dir = try TempDir()
        let sine = TestAudio.sine(frequency: 1000, amplitude: 0.5, sampleRate: 48_000, frames: 48_000)
        try TestAudio.write([sine], sampleRate: 48_000, to: dir.file("s.wav"))
        try TestAudio.write([sine.map { $0 * 0.5 }], sampleRate: 48_000, to: dir.file("half.wav"))
        let (dispatcher, _) = TestDispatchers.fake(workingDirectory: dir.url)
        let analysis = try await dispatcher.ok(.audioAnalyze, ["path": "s.wav", "bands": 8, "fftSize": 1024])
        #expect(abs((analysis["peakDb"]?[0]?.doubleValue ?? 0) + 6.02) < 0.01)
        #expect(analysis["spectrum"]?.arrayValue?.count == 8)
        let compare = try await dispatcher.ok(.audioCompare, ["a": "s.wav", "b": "half.wav", "toleranceDb": -100])
        #expect(compare["pass"] == false && abs((compare["nullResidualDb"]?.doubleValue ?? 0) + 12.04) < 0.01)
        #expect(await dispatcher.failure(.audioAnalyze, ["path": "nope.wav"])?.dawError == "engine")
        #expect(await dispatcher.failure(.audioAnalyze, ["path": "s.wav", "fftSize": 1000])?.dawError == "invalidArgument")
    }

    // MARK: engine.*

    @Test("CTL-002 engine.telemetry: TelemetryPOD fields, per-node latency, graph status and rtViolations")
    func telemetry() async throws {
        let (dispatcher, _) = TestDispatchers.fake()
        _ = try await dispatcher.ok(.projectNew, ["name": "a"])
        let telemetry = try await dispatcher.ok(.engineTelemetry)
        #expect(telemetry["rtViolations"] == 0 && telemetry["engineRtViolations"] == 0 && telemetry["renderRtViolations"] == 0)
        #expect(telemetry["sampleRate"] == 48_000 && telemetry["nodeLatencies"] == [])
        #expect(telemetry["graph"]?["publishedVersion"] == 1)
    }

    @Test("CTL-002 engine.events: drained events with a cursor")
    func events() async throws {
        let (dispatcher, box) = TestDispatchers.fake()
        _ = try await dispatcher.ok(.projectNew, ["name": "a"])
        box.last.post(EngineEvent(kind: .overload, count: 3))
        box.last.post(EngineEvent(kind: .deviceChanged))
        let all = try await dispatcher.ok(.engineEvents)
        #expect(all["events"]?.arrayValue?.map { $0["event"]?["kind"] } == ["overload", "deviceChanged"])
        #expect(all["events"]?[0]?["event"]?["count"] == 3)
        let next = try #require(all["next"]?.int64Value)
        #expect(try await dispatcher.ok(.engineEvents, ["since": .int(next)]) == ["events": [], "next": .int(next)])
        box.last.post(EngineEvent(kind: .pluginCrashed, subject: 9))
        let later = try await dispatcher.ok(.engineEvents, ["since": .int(next)])
        #expect(later["events"]?.arrayValue?.map { $0["seq"] } == [.int(next + 1)])
    }

    @Test("CTL-002 engine.paramInfo: the engine's ParamInfo list for a node kind")
    func paramInfo() async throws {
        let (dispatcher, _) = TestDispatchers.fake()
        _ = try await dispatcher.ok(.projectNew, ["name": "a"])
        #expect(try await dispatcher.ok(.engineParamInfo, ["kind": "channelStrip"]) == [])
        #expect(await dispatcher.failure(.engineParamInfo, ["kind": "kazoo"])?.dawError == "invalidParams")
    }

    // MARK: ui.* (CTL-005)

    @Test("CTL-005: attach-only methods return methodNotAvailableInHeadless in headless mode", arguments: [
        ControlMethod.uiState, .uiSnapshot, .uiPerform,
    ])
    func attachOnlyInHeadless(method: ControlMethod) async throws {
        let (dispatcher, _) = TestDispatchers.fake()
        let error = await dispatcher.failure(method, ["accessibilityId": "x", "action": "click"])
        #expect(error?.code == -32001 && error?.dawError == "methodNotAvailableInHeadless")
        #expect(ControlMethod.allCases.filter(\.isAttachOnly) == [.uiState, .uiSnapshot, .uiPerform])
    }

    @Test("CTL-005: in attach mode ui.* go to the app's UI provider")
    func uiProvider() async throws {
        let ui = FakeUI()
        let (dispatcher, _) = TestDispatchers.fake(mode: .attach, ui: ui)
        #expect(try await dispatcher.ok(.uiState) == ["windows": 1])
        #expect(try await dispatcher.ok(.uiSnapshot, ["path": "/tmp/a.png"]) == ["pngPath": "/tmp/a.png"])
        _ = try await dispatcher.ok(.uiPerform, ["accessibilityId": "play", "action": "click"])
        #expect(ui.performed == ["play:click"])
    }

    // MARK: test.fixture

    @Test("CTL-002 test.fixture: runs a fixture script's project-building requests, skipping renders and analysis")
    func fixture() async throws {
        let dir = try TempDir()
        try """
            # a fixture as T-019 writes them
            project.new {"name": "fx"}
            command.apply {"command": {"type": "AddTrack", "name": "T", "kind": "audio"}}
            render.offline {"from": 0, "to": 960, "path": "fx.wav"}
            audio.analyze {"path": "fx.wav"}
            """.write(to: dir.file("simple.jsonl"), atomically: true, encoding: .utf8)
        try "project.new {\"name\": \"bad\"}\nundo\ncommand.apply {\"command\": {\"type\": \"Nope\"}}\n"
            .write(to: dir.file("broken.jsonl"), atomically: true, encoding: .utf8)
        let (dispatcher, box) = TestDispatchers.fake(fixtures: [dir.file("missing-dir"), dir.url])

        let result = try await dispatcher.ok(.testFixture, ["name": "simple"])
        #expect(result["requests"] == 2 && result["skipped"] == 2)
        #expect(dispatcher.store?.project.name == "fx" && dispatcher.store?.project.tracks.count == 1)
        #expect(!box.last.calls.contains { if case .renderOffline = $0 { true } else { false } })

        let broken = await dispatcher.failure(.testFixture, ["name": "broken"])
        #expect(broken?.dawError == "unknownCommandType" && broken?.data?["line"] == 3)
        #expect(await dispatcher.failure(.testFixture, ["name": "nope"])?.dawError == "invalidParams")
        #expect(await dispatcher.failure(.testFixture, ["name": "../simple"])?.dawError == "invalidParams")
    }

    @Test("CTL-002: every v1 method is dispatched (none falls through to methodNotFound)")
    func everyMethodRoutes() async throws {
        let (dispatcher, _) = TestDispatchers.fake()
        for method in ControlMethod.allCases {
            let error = await dispatcherError(dispatcher, method)
            #expect(error?.dawError != "methodNotFound", "\(method.rawValue)")
        }
    }

    private func dispatcherError(_ dispatcher: Dispatcher, _ method: ControlMethod) async -> RPCError? {
        do {
            _ = try await dispatcher.call(method, [:])
            return nil
        } catch {
            return error.rpcError
        }
    }
}

@MainActor
final class FakeUI: ControlUIProvider {
    var performed: [String] = []

    func uiState() async throws -> JSONValue { ["windows": 1] }
    func uiSnapshot(_ params: UISnapshotParams) async throws -> JSONValue { ["pngPath": .string(params.path ?? "")] }

    func uiPerform(_ params: UIPerformParams) async throws -> JSONValue {
        performed.append("\(params.accessibilityId):\(params.action)")
        return [:]
    }
}
