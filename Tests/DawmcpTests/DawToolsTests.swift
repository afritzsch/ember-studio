import DAWControl
import DAWModel
import Foundation
import MCP
import Testing

@testable import dawmcp

// CTL-021 / CTL-022: the MCP tool layer over an in-process headless dispatcher, as dawmcp runs it.

@MainActor
@Suite("dawmcp tools (CTL-021, CTL-022)")
struct DawToolsTests {
    @Test("CTL-021: one tool per control method, named daw_<method>, with the params' JSON Schema")
    func toolList() throws {
        let tools = DawTools.tools
        #expect(tools.count == ControlMethod.allCases.count)
        #expect(Set(tools.map(\.name)).count == tools.count)
        for name in ["daw_project_new", "daw_command_apply", "daw_command_schema", "daw_render_offline", "daw_audio_analyze",
                     "daw_audio_compare", "daw_engine_telemetry", "daw_ui_snapshot", "daw_ui_state", "daw_ui_perform",
                     "daw_test_fixture", "daw_transport_set_loop", "daw_engine_param_info", "daw_undo", "daw_device_list",
                     "daw_device_set", "daw_device_simulate"]
        {
            #expect(tools.contains { $0.name == name }, "\(name)")
        }
        for (tool, method) in zip(tools, ControlMethod.allCases) {
            #expect(DawTools.methodsByTool[tool.name] == method)
            #expect(tool.description?.hasPrefix(method.summary) == true)
            #expect(JSONValue(mcp: tool.inputSchema) == method.paramsSchema, "\(tool.name)")
        }
        let render = try #require(tools.first { $0.name == "daw_render_offline" })
        #expect(JSONValue(mcp: render.inputSchema)["required"] == ["from", "to", "path"])
        #expect(tools.first { $0.name == "daw_project_get" }?.annotations.readOnlyHint == true)
        #expect(tools.first { $0.name == "daw_command_apply" }?.annotations.readOnlyHint == nil)
    }

    @Test("CTL-021: a call runs the method; a failure is isError with the JSON-RPC error (CTL-003 data)")
    func callsAndErrors() async throws {
        let tools = DawTools(dispatcher: Dispatcher())
        let none = try await tools.failure("daw_project_get")
        #expect(none["code"] == -32002 && none["data"]?["dawError"] == "noProject")
        #expect(try await tools.ok("daw_project_new", ["name": "t"]) == ["projectID": "00000000-0000-0000-0000-000000000001"])
        let bad = try await tools.failure("daw_transport_locate", ["tick": "soon"])
        #expect(bad["code"] == -32602 && bad["data"]?["dawError"] == "invalidParams")
        let unknown = try await tools.failure("daw_nope")
        #expect(unknown["code"] == -32601)
        let schema = try await tools.ok("daw_command_schema", ["type": "AddBus"])
        #expect(schema["commands"]?[0]?["type"] == "AddBus")
    }

    @Test("CTL-005: ui tools say methodNotAvailableInHeadless in headless mode")
    func uiHeadless() async throws {
        let tools = DawTools(dispatcher: Dispatcher())
        for name in ["daw_ui_state", "daw_ui_snapshot", "daw_ui_perform"] {
            let error = try await tools.failure(name, ["accessibilityId": "x", "action": "click"])
            #expect(error["code"] == -32001 && error["data"]?["dawError"] == "methodNotAvailableInHeadless", "\(name)")
        }
    }

    @Test("CTL-022: daw_ui_snapshot returns the PNG as image content plus the path")
    func snapshotImage() async throws {
        let dir = try TempDir()
        let ui = SnapshotUI(directory: dir.url)
        let tools = DawTools(dispatcher: Dispatcher(configuration: .init(mode: .attach, ui: ui)))
        let result = await tools.call("daw_ui_snapshot", arguments: [:])
        #expect(result.isError != true, "\(result.texts)")
        guard case .image(let data, let mimeType, _, _) = try #require(result.content.first) else {
            Issue.record("first item isn't an image: \(result.content)")
            return
        }
        #expect(mimeType == "image/png")
        #expect(Data(base64Encoded: data) == SnapshotUI.png)
        #expect(try result.json == ["pngPath": .string(dir.file("window.png").path)])

        ui.writes = false
        let missing = try await tools.failure("daw_ui_snapshot")
        #expect(missing["data"]?["dawError"] == "internalError")
    }

    @Test("DW-114: a routing scenario through the tools: buses, sends, cycle rejection, render + analyze, 0 RT violations")
    func routingScenario() async throws {
        DawmcpTestCommands.register()
        let dir = try TempDir()
        let tools = DawTools(dispatcher: Dispatcher(configuration: .init(workingDirectory: dir.url)))
        // A −6 dB 1 kHz sine, one second at the session rate.
        try writeSine(to: dir.file("sine.wav"), frequency: 1000, amplitude: 0.5, sampleRate: 48_000, frames: 48_000)

        _ = try await tools.ok("daw_project_new", ["name": "routing"])
        // The asset loads as asset.import does it (engine first, under the next ID), since
        // ImportAsset doesn't exist yet (T-030).
        let dispatcher = tools.dispatcher
        let assetID = try #require(dispatcher.store).project.ids.next
        let engine = try #require(dispatcher.engine)
        let load = await engine.waitForJob(engine.loadAsset(assetID, path: dir.file("sine.wav").path))
        try #require(load.state == .succeeded, "\(load)")
        let built = try await tools.ok("daw_command_batch", ["atomic": true, "commands": [
            ["type": "DawmcpTestAddAsset", "path": .string(dir.file("sine.wav").path), "channels": 2, "sampleRate": 48_000,
             "frames": 48_000],
            ["type": "AddTrack", "name": "Gtr", "kind": "audio"],
            ["type": "AddBus", "name": "A"],
            ["type": "AddBus", "name": "B"],
        ]])
        let ids = (built["results"]?.arrayValue ?? []).compactMap { $0["createdIDs"]?[0]?.int64Value }
        try #require(ids == [Int64(assetID), Int64(assetID) + 1, Int64(assetID) + 2, Int64(assetID) + 3])
        let (asset, track, busA, busB) = (Value.int(Int(ids[0])), Value.int(Int(ids[1])), Value.int(Int(ids[2])), Value.int(Int(ids[3])))
        _ = try await tools.ok("daw_command_apply", ["command": [
            "type": "DawmcpTestAddAudioClip", "trackID": track, "assetID": asset, "start": 0, "length": 1920,
        ]])

        // Track → bus A → master.
        _ = try await tools.ok("daw_command_apply", ["command": [
            "type": "SetTrackOutput", "channelID": track, "output": ["kind": "bus", "id": busA],
        ]])
        let direct = try await renderPeak(tools, "direct.wav")
        // Plus a post-fader send at half level into bus B → master: the same signal, half as loud, adds
        // coherently (both bus strips are identical), so +3.52 dB.
        _ = try await tools.ok("daw_command_apply", ["command": [
            "type": "AddSend", "channelID": track, "busID": busB, "level": 0.5,
        ]])
        let withSend = try await renderPeak(tools, "send.wav")
        #expect(abs(withSend - direct - 20 * log10(1.5)) < 0.01, "direct \(direct) dB, with send \(withSend) dB")
        // Muting bus A leaves only the send path: −6.02 dB.
        _ = try await tools.ok("daw_command_apply", ["command": [
            "type": "SetParam", "target": ["kind": "strip", "channel": busA, "param": "mute"], "value": 1,
        ]])
        let sendOnly = try await renderPeak(tools, "sendonly.wav")
        #expect(abs(sendOnly - direct - 20 * log10(0.5)) < 0.01, "direct \(direct) dB, send only \(sendOnly) dB")

        // CTL-003: B → A would close A → B → A; the error names the cycle in model IDs.
        _ = try await tools.ok("daw_command_apply", ["command": [
            "type": "SetTrackOutput", "channelID": busA, "output": ["kind": "bus", "id": busB],
        ]])
        let cycle = try await tools.failure("daw_command_apply", ["command": ["type": "AddSend", "channelID": busB, "busID": busA]])
        #expect(cycle["code"] == -32000 && cycle["data"]?["dawError"] == "routingCycle")
        #expect(cycle["data"]?["path"] == [.int(ids[3]), .int(ids[2]), .int(ids[3])])

        let telemetry = try await tools.ok("daw_engine_telemetry")
        #expect(telemetry["rtViolations"] == 0)
        #expect(telemetry["renderRtViolations"] == 0)
    }

    @Test("DW-115: a scripted device loss through the tools: deviceChanged in engine.events, telemetry outputDeviceID, 0 RT violations")
    func deviceLoss() async throws {
        let tools = DawTools(dispatcher: Dispatcher())
        _ = try await tools.ok("daw_project_new", ["name": "dev", "engine": ["mode": "realtime", "driver": "fake"]])
        #expect(try await tools.ok("daw_engine_telemetry")["outputDeviceID"] == 1)
        let lost = try await tools.ok("daw_device_simulate", ["kind": "deviceLost"])
        #expect(lost["outputDeviceID"] == 2)
        let events = try await tools.ok("daw_engine_events")
        let change = try #require(events["events"]?.arrayValue?.first { $0["event"]?["kind"] == "deviceChanged" })
        #expect(change["event"]?["device"]?["reason"] == "deviceLost")
        #expect(change["event"]?["device"]?["previousDeviceID"] == 1 && change["event"]?["device"]?["deviceID"] == 2)
        let telemetry = try await tools.ok("daw_engine_telemetry")
        #expect(telemetry["outputDeviceID"] == 2 && telemetry["deviceRunning"] == true)
        #expect(telemetry["rtViolations"] == 0)
    }

    /// Renders the first second and returns its peak (dBFS), skipping the first block's ramps.
    private func renderPeak(_ tools: DawTools, _ name: String) async throws -> Double {
        let render = try await tools.ok("daw_render_offline", ["from": 0, "to": 1920, "path": .string(name), "tail": false])
        #expect(render["rtViolations"] == 0)
        let analysis = try await tools.ok("daw_audio_analyze", ["path": .string(name), "range": ["start": 4800, "end": 43_200]])
        let peaks = (analysis["peakDb"]?.arrayValue ?? []).compactMap(\.doubleValue)
        #expect(peaks.count == 2 && peaks[0] > -40, "\(name): \(peaks)")
        return peaks.max() ?? -240
    }
}

@MainActor
final class SnapshotUI: ControlUIProvider {
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    let directory: URL
    var writes = true

    init(directory: URL) { self.directory = directory }

    func uiState() async throws -> JSONValue { [:] }
    func uiPerform(_ params: UIPerformParams) async throws -> JSONValue { [:] }

    func uiSnapshot(_ params: UISnapshotParams) async throws -> JSONValue {
        let url = directory.appending(path: params.path ?? "window.png")
        if writes { try Self.png.write(to: url) } else { try? FileManager.default.removeItem(at: url) }
        return ["pngPath": .string(url.path)]
    }
}
