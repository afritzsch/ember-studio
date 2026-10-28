import DAWControl
import DAWModel
import Foundation
import Testing

// DW-115 (T-051 deltas, IO-021): device.* through the headless dispatcher on a realtime engine with
// the fake driver (two made-up devices, paced in real time).

@MainActor
@Suite("device.* (DW-115)")
struct DeviceMethodTests {
    @Test("DW-115: project.new {engine: realtime} runs the fake devices; device.list shows them and the running one")
    func list() async throws {
        let dispatcher = Dispatcher()
        _ = try await dispatcher.ok(.projectNew, ["name": "dev", "engine": ["mode": "realtime"]])
        guard case .realtime(let config) = try #require(dispatcher.engine).mode else {
            Issue.record("not a realtime engine")
            return
        }
        #expect(config.driver == .fake && config.sampleRate == 48_000)
        let list = try await dispatcher.ok(.deviceList).decode(DeviceListResult.self)
        #expect(list.driver == .fake)
        #expect(list.devices.map(\.name) == ["Fake Device A", "Fake Device B"])
        #expect(list.outputDeviceID == 1)
    }

    @Test("DW-115 / IO-021: a simulated device loss falls back to the default, reports deviceChanged and moves telemetry; 0 RT violations")
    func scriptedLoss() async throws {
        let dispatcher = Dispatcher()
        _ = try await dispatcher.ok(.projectNew, ["name": "dev", "engine": ["mode": "realtime"]])
        let lost = try await dispatcher.ok(.deviceSimulate, ["kind": "deviceLost"]).decode(DeviceStateResult.self)
        // Fake Device B runs only 44.1 kHz, so the fallback changes the session rate (IO-021 (5)).
        #expect(lost.outputDeviceID == 2 && lost.deviceRunning && lost.sampleRate == 44_100)
        let change = try #require(lost.events.first { $0.event.kind == .deviceChanged }?.event.device)
        #expect(change == DeviceChange(reason: .deviceLost, previousDeviceID: 1, deviceID: 2,
                                       previousSampleRate: 48_000, sampleRate: 44_100))
        // The same event is kept for engine.events.
        let events = try await dispatcher.ok(.engineEvents).decode(EngineEventsResult.self)
        #expect(events.events.map(\.event) == lost.events.map(\.event))
        let telemetry = try await dispatcher.ok(.engineTelemetry)
        #expect(telemetry["outputDeviceID"] == 2)
        #expect(telemetry["rtViolations"] == 0)

        // A is gone until it comes back; then device.set returns to it at the old rate (DW-079).
        #expect(await dispatcher.failure(.deviceSet, ["outputDevice": 1])?.data?["dawError"] == "engine")
        _ = try await dispatcher.ok(.deviceSimulate, ["kind": "deviceRestored", "deviceID": 1])
        let back = try await dispatcher.ok(.deviceSet, ["outputDevice": 1, "sampleRate": 48_000]).decode(DeviceStateResult.self)
        #expect(back.outputDeviceID == 1 && back.sampleRate == 48_000)
        #expect(try await dispatcher.ok(.engineTelemetry)["rtViolations"] == 0)
    }

    @Test("DW-115: an offline engine has no device to set or simulate")
    func offline() async throws {
        let dispatcher = Dispatcher()
        #expect(await dispatcher.failure(.deviceList)?.code == -32002)
        _ = try await dispatcher.ok(.projectNew, ["name": "off"])
        #expect(try await dispatcher.ok(.deviceList)["driver"] == nil)
        #expect(await dispatcher.failure(.deviceSet, ["outputDevice": 1])?.data?["dawError"] == "invalidArgument")
        #expect(await dispatcher.failure(.deviceSimulate, ["kind": "deviceLost"])?.data?["dawError"] == "notImplemented")
        #expect(await dispatcher.failure(.deviceSimulate, ["kind": "explode"])?.code == -32602)
    }
}
