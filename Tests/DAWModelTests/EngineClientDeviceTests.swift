import DAWEngine
import Foundation
import Testing

@testable import DAWModel

// T-051: the device side of EngineClient over the real facade, on the fake device driver
// (DriverConfig.driver = .fake, DW-089), so no CoreAudio device is touched: deviceChanged events
// with their DeviceChange (IO-021), the session-rate change (IO-021 (5), DW-079), device telemetry
// (IO-023). The facade internals are tested in Tests/DAWEngineTests/FacadeDeviceTests.swift.

private func fakeEngine(sampleRate: Double = 0) throws -> EngineClient {
    try EngineClient(.realtime(DriverConfig(sampleRate: sampleRate, driver: .fake)))
}

private func deviceChanges(_ engine: some EngineProtocol) -> [EngineEvent] {
    engine.pollEvents().filter { $0.kind == .deviceChanged }
}

@Suite("EngineClient devices (IO-021..023, T-051)")
struct EngineClientDeviceTests {
    @Test("DW-089: a realtime engine on the fake devices lists them and runs Fake Device A at 48 kHz")
    func fakeDevices() throws {
        let engine = try fakeEngine()
        let devices = engine.devices()
        #expect(devices.map(\.name) == ["Fake Device A", "Fake Device B"])
        #expect(devices.map(\.id) == [1, 2] && devices[0].isDefaultOutput)
        let t = engine.telemetry()
        #expect(t.deviceRunning && t.outputDeviceID == 1 && t.sampleRate == 48_000)
        #expect(t.rtViolations == 0)
    }

    @Test("IO-021: a lost device becomes a deviceChanged event with its DeviceChange; the session follows the fallback")
    func lossEvent() throws {
        let engine = try fakeEngine()
        let version = engine.applyGraph(EngineGraph(nodes: [.init(id: 1, kind: .master)], master: 1))
        #expect(engine.waitForGraph(version, timeout: .seconds(5)).publishedVersion == version)

        try engine.simulateDeviceEvent(DeviceEvent(.deviceLost))
        let events = deviceChanges(engine)
        #expect(events.count == 1)
        #expect(events.first?.error == nil)
        #expect(events.first?.device == DeviceChange(reason: .deviceLost, previousDeviceID: 1, deviceID: 2,
                                                     previousSampleRate: 48_000, sampleRate: 44_100))
        let t = engine.telemetry()
        #expect(t.outputDeviceID == 2 && t.sampleRate == 44_100)
        #expect(t.graphVersion == version + 1)  // rebuilt at 44.1 kHz

        // Nothing left to fall back to: the event carries the error, nothing runs.
        try engine.simulateDeviceEvent(DeviceEvent(.deviceLost, deviceID: 2))
        let lost = deviceChanges(engine)
        #expect(lost.first?.device?.deviceID == 0 && lost.first?.device?.reason == .deviceLost)
        #expect(lost.first?.error != nil)
        #expect(!engine.telemetry().deviceRunning && engine.telemetry().outputDeviceID == 0)
        try engine.simulateDeviceEvent(DeviceEvent(.deviceRestored, deviceID: 1))
        #expect(deviceChanges(engine).first?.device?.reason == .deviceAvailable)
        #expect(engine.telemetry().outputDeviceID == 1)
        #expect(engine.telemetry().rtViolations == 0)
    }

    @Test("IO-023: a simulated processor overload shows in telemetry and as an overload event")
    func overload() throws {
        let engine = try fakeEngine()
        try engine.simulateDeviceEvent(DeviceEvent(.processorOverload))
        let t = engine.telemetry()
        #expect(t.processorOverloads == 1 && t.xruns == t.processorOverloads + t.renderOverruns)
        #expect(engine.pollEvents().contains { $0.kind == .overload && $0.count == t.xruns })
    }

    @Test("DW-079: setDevice with another rate changes the session rate; rate 0 keeps it; bad requests throw")
    func setDeviceRate() throws {
        let engine = try fakeEngine()
        try engine.setDevice(DriverConfig(sampleRate: 96_000, driver: .fake))
        #expect(engine.telemetry().sampleRate == 96_000 && engine.telemetry().deviceRunning)
        try engine.setDevice(DriverConfig(sampleRate: 0, driver: .fake))
        #expect(engine.telemetry().sampleRate == 96_000)
        #expect(throws: DAWError.self) { try engine.setDevice(DriverConfig(sampleRate: 22_050, driver: .fake)) }
        #expect(throws: DAWError.self) { try engine.setDevice(DriverConfig(sampleRate: 0, driver: .coreAudio)) }
        #expect(throws: DAWError.self) {
            try engine.simulateDeviceEvent(DeviceEvent(.sampleRateChanged, deviceID: 2, sampleRate: 96_000))
        }
        #expect(engine.telemetry().deviceRunning)
    }

    @Test("DW-089: only the fake driver simulates device events")
    func simulateUnsupported() throws {
        let offline = try EngineClient(.offline())
        #expect(throws: DAWError.self) { try offline.simulateDeviceEvent(DeviceEvent(.deviceLost)) }
        let t = offline.telemetry()
        #expect(t.outputDeviceID == 0 && t.processorOverloads == 0 && t.renderOverruns == 0)
    }

    @Test("T-051: FakeEngine records simulateDeviceEvent and refuses it; posted device changes reach the model")
    func fakeEngineDevices() {
        let fake = FakeEngine()
        let event = DeviceEvent(.sampleRateChanged, deviceID: 1, sampleRate: 44_100)
        #expect(throws: DAWError.self) { try fake.simulateDeviceEvent(event) }
        #expect(fake.calls.contains(.simulateDeviceEvent(event)))
        let change = DeviceChange(reason: .defaultOutputChanged, previousDeviceID: 1, deviceID: 3,
                                  previousSampleRate: 48_000, sampleRate: 48_000)
        fake.post(EngineEvent(kind: .deviceChanged, device: change))
        #expect(fake.pollEvents().first?.device == change)
    }

    @Test("T-051: DriverConfig and EngineEvent round-trip through JSON; JSON without `driver` means CoreAudio")
    func codable() throws {
        let config = DriverConfig(outputDevice: 2, sampleRate: 44_100, driver: .fake)
        let decoded = try JSONDecoder().decode(DriverConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
        let old = Data(#"{"outputDevice":0,"inputDevice":0,"sampleRate":0,"bufferFrames":256,"outputChannels":2,"inputChannels":2}"#.utf8)
        #expect(try JSONDecoder().decode(DriverConfig.self, from: old).driver == .coreAudio)

        let event = EngineEvent(kind: .deviceChanged, error: .engine(code: .notFound, detail: "gone"),
                                device: DeviceChange(reason: .deviceLost, previousDeviceID: 1))
        #expect(try JSONDecoder().decode(EngineEvent.self, from: JSONEncoder().encode(event)) == event)
        // Without a DeviceChange the JSON is what it was before T-051 (no `device` key).
        let plain = try JSONEncoder().encode(EngineEvent(kind: .overload, count: 3))
        #expect(!String(decoding: plain, as: UTF8.self).contains("device"))
    }
}
