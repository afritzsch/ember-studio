import DAWControl
import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// UI-040 (audio preferences), DW-183 (session-rate UI + re-conversion progress) and UI-004 (device
// toasts) for T-055. The device tests run the real engine on the fake device driver (DW-089:
// "Fake Device A" 44.1–96 kHz, "Fake Device B" 44.1 kHz only), so setDevice, the DW-130 rate
// follow and IO-021 device events are the engine's own.

/// An app whose engines are realtime on the fake devices (what attach mode runs).
@MainActor
private func fakeDeviceApp() -> AppModel {
    AppModel(engine: .fake)
}

@MainActor
private func perform(_ window: ProjectWindowModel, _ id: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let control = try window.control(id, sourceLocation: sourceLocation)
    #expect(control.isEnabled, "\(id) is disabled", sourceLocation: sourceLocation)
    control.action()
}

@MainActor
@Suite("Audio preferences (UI-040, DW-183)", .serialized)
struct AudioPreferencesTests {
    @Test("UI-040: prefs.audio opens the panel, which lists the devices, rates, buffer sizes and input channels as controls")
    func panelControls() async throws {
        let app = fakeDeviceApp()
        let window = app.newProject()
        let prefs = window.audioPrefs
        #expect(try window.control("prefs.audio").isOn == false)
        #expect(!window.controls.contains { $0.id == "prefs.audio.buffer.256" }, "closed: only the toggle")

        try perform(window, "prefs.audio")
        #expect(prefs.isOpen && prefs.driver == .fake)
        #expect(prefs.devices.map(\.name) == ["Fake Device A", "Fake Device B"])
        let ids = Set(window.controls.map(\.id))
        for id in ["prefs.audio.close", "prefs.audio.refresh", "prefs.audio.output.default", "prefs.audio.output.1",
                   "prefs.audio.output.2", "prefs.audio.input.default", "prefs.audio.input.1", "prefs.audio.input.2",
                   "prefs.audio.sampleRate.44100", "prefs.audio.sampleRate.48000", "prefs.audio.sampleRate.88200",
                   "prefs.audio.sampleRate.96000", "prefs.audio.buffer.32", "prefs.audio.buffer.2048",
                   "prefs.audio.inputChannels.1", "prefs.audio.inputChannels.2"] {
            #expect(ids.contains(id), "\(id)")
        }
        // What the engine was created with: the default output, 256 frames, 2 inputs, 48 kHz.
        #expect(try window.control("prefs.audio.output.default").isOn == true)
        #expect(try window.control("prefs.audio.buffer.256").isOn == true)
        #expect(try window.control("prefs.audio.inputChannels.2").isOn == true)
        #expect(try window.control("prefs.audio.sampleRate.48000").isOn == true)

        // IO-005: the latency readout (and the running device) come from telemetry once the window
        // has polled it.
        app.pump()
        #expect(prefs.outputTitle == "System Default (Fake Device A)")
        #expect(prefs.telemetry.deviceRunning)
        #expect(prefs.latency.totalSamples == prefs.latency.deviceSamples + prefs.latency.graphSamples)
        #expect(prefs.latencyText.hasPrefix("Output "))

        try perform(window, "prefs.audio.close")
        #expect(!prefs.isOpen)
        #expect(!window.controls.contains { $0.id == "prefs.audio.output.1" })
        await app.quit()
    }

    @Test("UI-040: buffer size, input channels and input device go to the engine through setDevice and stay chosen")
    func bufferAndInput() async throws {
        let app = fakeDeviceApp()
        let window = app.newProject()
        let prefs = window.audioPrefs
        prefs.isOpen = true

        try perform(window, "prefs.audio.buffer.512")
        #expect(prefs.config?.bufferFrames == 512 && prefs.lastError == nil)
        #expect(try window.control("prefs.audio.buffer.512").isOn == true)
        #expect(try window.control("prefs.audio.buffer.256").isOn == false)
        try perform(window, "prefs.audio.inputChannels.1")
        #expect(prefs.config?.inputChannels == 1 && prefs.config?.bufferFrames == 512, "one change keeps the others")
        try perform(window, "prefs.audio.input.2")
        #expect(prefs.config?.inputDevice == 2 && prefs.inputTitle == "Fake Device B")
        app.pump()
        #expect(prefs.telemetry.deviceRunning && prefs.telemetry.outputDeviceID == 1)
        #expect(prefs.telemetry.rtViolations == 0)
        #expect(window.toasts.toasts.isEmpty, "\(window.toasts.toasts.map(\.title))")
        await app.quit()
    }

    @Test("UI-040, DW-079/DW-130: an output device that can't run the session rate changes it, and the project follows")
    func outputDeviceChangesRate() async throws {
        let app = fakeDeviceApp()
        let window = app.newProject()
        let prefs = window.audioPrefs
        prefs.isOpen = true
        #expect(window.project.sessionSampleRate == 48_000)

        try perform(window, "prefs.audio.output.2")  // Fake Device B: 44.1 kHz only
        #expect(prefs.config?.outputDevice == 2 && prefs.outputTitle == "Fake Device B")
        app.pump()
        #expect(prefs.telemetry.outputDeviceID == 2 && prefs.telemetry.sampleRate == 44_100)
        #expect(window.project.sessionSampleRate == 44_100, "the document follows the engine (DW-130)")
        #expect(try window.control("prefs.audio.sampleRate.44100").isOn == true)
        #expect(prefs.reload == nil, "nothing to convert: the pass is over")

        // DW-183: a rate the device can't run is refused before the document changes.
        try perform(window, "prefs.audio.sampleRate.96000")
        #expect(window.project.sessionSampleRate == 44_100)
        #expect(window.toasts.toasts.last?.title == "Set Sample Rate failed" && window.toasts.toasts.last?.severity == .error)

        // Back on A (it runs 44.1 kHz too, so the rate stays), then a rate it can run.
        try perform(window, "prefs.audio.output.1")
        app.pump()
        #expect(window.project.sessionSampleRate == 44_100 && prefs.telemetry.outputDeviceID == 1)
        try perform(window, "prefs.audio.sampleRate.96000")
        app.pump()
        #expect(window.project.sessionSampleRate == 96_000 && prefs.telemetry.sampleRate == 96_000)
        #expect(window.store.undoLabel == nil, "SetSessionSampleRate stays out of undo history")
        #expect(prefs.telemetry.rtViolations == 0)
        await app.quit()
    }

    @Test("UI-004, IO-021: a lost device toasts with an Audio Settings action, and a device chosen by name becomes the system default")
    func deviceLostToast() async throws {
        let app = fakeDeviceApp()
        let window = app.newProject()
        let prefs = window.audioPrefs
        prefs.isOpen = true
        try perform(window, "prefs.audio.output.1")
        prefs.isOpen = false
        app.pump()

        try window.engine?.simulateDeviceEvent(DeviceEvent(.deviceLost, deviceID: 1))
        app.pump()
        let toast = try #require(window.toasts.toasts.last { $0.kind == .deviceChanged })
        #expect(toast.title == "Audio device lost" && toast.severity == .warning)
        #expect(toast.message.contains("Fake Device A went away") && toast.message.contains("Now using Fake Device B"))
        #expect(toast.message.contains("Session rate is now 44.1 kHz"))
        #expect(toast.action?.label == "Audio Settings…" && toast.expiresAt != nil, "a warning still expires")
        #expect(prefs.config?.outputDevice == 0, "follows the system default now, like the engine (IO-021)")
        #expect(window.project.sessionSampleRate == 44_100)

        try perform(window, "toast.\(toast.id).action")
        #expect(prefs.isOpen && prefs.devices.map(\.id) == [2], "A is gone from the list")
        #expect(prefs.deviceName(1) == "Fake Device A", "but still has its name")
        #expect(!window.toasts.toasts.contains { $0.id == toast.id })
        await app.quit()
    }

    @Test("UI-040: an offline engine has no device to set; the sample rate still changes the project (DW-183)")
    func offlineEngine() throws {
        let (window, engine) = try makeWindow()
        let prefs = window.audioPrefs
        prefs.isOpen = true
        #expect(prefs.config == nil && prefs.driver == nil && prefs.outputTitle == "None (offline)")
        #expect(try window.control("prefs.audio.output.default").isEnabled == false)
        #expect(try window.control("prefs.audio.buffer.256").isEnabled == false)
        #expect(prefs.inputChannelChoices.isEmpty)
        #expect(prefs.latencyText == "No device running")
        try perform(window, "prefs.audio.sampleRate.88200")
        #expect(window.project.sessionSampleRate == 88_200)
        #expect(engine.calls.contains(.setSessionSampleRate(88_200)))
        // Choosing the rate in force does nothing.
        let calls = engine.calls.count
        try perform(window, "prefs.audio.sampleRate.88200")
        #expect(engine.calls.count == calls)
    }

    @Test("DW-183, IO-033: assetsReloaded progress shows while the pass runs; finished clears it and toasts")
    func reloadProgress() throws {
        let clock = TestClock()
        let (window, engine) = try makeWindow(clock: clock)
        let prefs = window.audioPrefs
        func deliver(_ phase: AssetsReload.Phase, done: UInt32, total: UInt32 = 2, failed: UInt32 = 0, error: DAWError? = nil) {
            engine.post(EngineEvent(kind: .assetsReloaded, subject: phase == .progress ? 7 : 0, count: UInt64(done), error: error,
                                    reload: AssetsReload(phase: phase, previousSampleRate: 48_000, sampleRate: 44_100, done: done,
                                                         total: total, failed: failed, assetID: phase == .progress ? 7 : 0)))
            window.engineEventsArrived(engine.pollEvents())
        }
        deliver(.started, done: 0)
        #expect(prefs.reload?.phase == .started && prefs.reloadText == "Converting audio to 44.1 kHz: 0 of 2")
        deliver(.progress, done: 1)
        #expect(prefs.reload?.fraction == 0.5 && prefs.reloadText == "Converting audio to 44.1 kHz: 1 of 2")
        #expect(window.toasts.toasts.isEmpty, "progress doesn't toast")
        deliver(.finished, done: 2)
        #expect(prefs.reload == nil && prefs.reloadText == nil)
        #expect(window.toasts.toasts.last?.title == "Audio converted to 44.1 kHz" && window.toasts.toasts.last?.severity == .info)

        // A superseded pass: the new started replaces the old one without a finished.
        deliver(.started, done: 0)
        deliver(.progress, done: 1)
        deliver(.started, done: 0, total: 3)
        #expect(prefs.reload?.total == 3 && prefs.reload?.done == 0)
        deliver(.finished, done: 3, total: 3, failed: 1, error: .engine(code: .io, detail: "1 asset didn't load"))
        #expect(prefs.reload == nil)
        let failed = try #require(window.toasts.toasts.last)
        #expect(failed.title == "Audio not reloaded" && failed.message.hasPrefix("1 of 3 audio files didn't convert"))

        // ui.state carries it.
        deliver(.started, done: 0)
        let state = UIStateDumper.dump(window, isMain: true)["audioPreferences"]
        #expect(state?["reload"]?["phase"] == "started" && state?["reload"]?["total"] == 2)
        #expect(state?["sampleRate"]?.doubleValue == 48_000 && state?["driver"] == .null)
    }

    @Test("UI-040: the window's project is replaced: progress and the applied config are dropped")
    func replaceStore() throws {
        let (window, engine) = try makeWindow()
        engine.post(EngineEvent(kind: .assetsReloaded, reload: AssetsReload(phase: .started, previousSampleRate: 48_000,
                                                                            sampleRate: 96_000, total: 1)))
        window.engineEventsArrived(engine.pollEvents())
        #expect(window.audioPrefs.reload != nil)
        let store = ProjectStore(project: Project(name: "Other"))
        store.autosavePolicy = nil
        window.replace(store: store)
        #expect(window.audioPrefs.reload == nil && window.audioPrefs.lastError == nil)
    }

    @Test("UI-052, UI-050: ui.perform drives the audio settings by id and ui.state reports them")
    func attachMode() async throws {
        let app = fakeDeviceApp()
        let window = app.newProject()
        let d = app.dispatcher
        #expect(try await d.call(.uiPerform, ["accessibilityId": "prefs.audio", "action": "on"])["isOn"] == true)
        #expect(try await d.call(.uiPerform, ["accessibilityId": "prefs.audio.buffer.128", "action": "click"])["isOn"] == true)
        _ = try await d.call(.uiPerform, ["accessibilityId": "prefs.audio.output.2", "action": "on"])
        app.pump()
        let state = try await d.call(.uiState)
        let prefs = try #require(state["windows"]?[0]?["audioPreferences"])
        #expect(prefs["open"] == true && prefs["driver"] == "fake")
        #expect(prefs["devices"]?.arrayValue?.count == 2 && prefs["devices"]?[1]?["name"] == "Fake Device B")
        #expect(prefs["outputDevice"] == 2 && prefs["runningDeviceID"] == 2 && prefs["deviceRunning"] == true)
        #expect(prefs["bufferFrames"] == 128 && prefs["inputChannels"] == 2)
        #expect(prefs["sampleRate"]?.doubleValue == 44_100 && prefs["engineSampleRate"]?.doubleValue == 44_100)
        #expect(prefs["latency"]?["totalSamples"] != nil && prefs["reload"] == .null && prefs["error"] == .null)
        #expect(window.project.sessionSampleRate == 44_100)
        await app.quit()
    }

    @Test("UI-002, UI-040: ⌘, toggles the audio settings")
    func shortcut() throws {
        let (window, _) = try makeWindow()
        #expect(window.handleKey(KeyChord(",", .command)))
        #expect(window.audioPrefs.isOpen)
        #expect(window.handleKey(KeyChord(",", .command)))
        #expect(!window.audioPrefs.isOpen)
    }
}
