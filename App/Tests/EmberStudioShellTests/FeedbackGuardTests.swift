import DAWControl
import DAWModel
import Foundation
import Testing

@testable import EmberStudioShell

// DW-230 (T-090, docs/autobuild/DECISIONS.md "T-090 feedback guard"): `auto` monitoring stays the
// default, and a track that monitors the built-in microphone through the built-in speakers gets a
// warning toast with a "Monitoring Off" action, also in `ui.state`. Made-up devices on a realtime
// FakeEngine stand in for the hardware.

private let mic = AudioDeviceInfo(id: 10, name: "MacBook Pro Microphone", inputChannels: 1, outputChannels: 0,
                                  nominalSampleRate: 48_000, isDefaultOutput: false, isBuiltIn: true, isDefaultInput: true)
private let speakers = AudioDeviceInfo(id: 20, name: "MacBook Pro Speakers", inputChannels: 0, outputChannels: 2,
                                       nominalSampleRate: 48_000, isDefaultOutput: true, isBuiltIn: true)
private let interface = AudioDeviceInfo(id: 30, name: "USB Interface", inputChannels: 2, outputChannels: 2,
                                        nominalSampleRate: 48_000, isDefaultOutput: false)

/// A window on a realtime FakeEngine running `devices`, with the device `running` as output.
@MainActor
private func liveWindow(devices: [AudioDeviceInfo] = [mic, speakers, interface], running: UInt32 = 20,
                        tracks: [String] = ["Vox"], clock: TestClock = TestClock())
    throws -> (ProjectWindowModel, FakeEngine)
{
    let engine = FakeEngine(mode: .realtime(DriverConfig(sampleRate: 48_000, bufferFrames: 256, driver: .coreAudio)))
    engine.setDevices(devices)
    engine.setRunningDevice(running)
    let store = ProjectStore(project: Project(name: "Feedback"))
    store.autosavePolicy = nil
    try store.attachEngine(engine, debounce: .zero)
    for name in tracks { try store.perform(AddTrack(name: name, kind: .audio)) }
    let window = ProjectWindowModel(id: 1, store: store, toasts: ToastCenter(now: { clock.now }))
    window.pollTransport()
    return (window, engine)
}

@MainActor
@Suite("Monitoring feedback guard (DW-230)")
struct FeedbackGuardTests {
    @Test("DW-230: arming a track (auto monitoring) on the built-in mic and speakers warns, with a Monitoring Off action")
    func armWarns() throws {
        let (window, _) = try liveWindow()
        let track = window.project.tracks[0].id
        #expect(window.project.tracks[0].monitoring == .auto, "auto stays the default")
        #expect(window.feedbackGuard.risk == nil && window.toasts.toasts.isEmpty, "not armed: no input reaches the output")

        try window.control("track.\(track).arm").action()
        window.pollTransport()
        let risk = try #require(window.feedbackGuard.risk)
        #expect(risk.tracks == [track] && risk.input.id == mic.id && risk.output.id == speakers.id)
        let toast = try #require(window.toasts.toasts.last)
        #expect(toast.kind == .feedbackRisk && toast.severity == .warning && toast.title == "Feedback risk")
        #expect(toast.message.contains("Vox") && toast.message.contains("MacBook Pro Microphone")
            && toast.message.contains("MacBook Pro Speakers"))
        #expect(toast.action?.label == "Monitoring Off" && toast.expiresAt == nil, "it stays until acted on")

        // ui.state shows it.
        let state = UIStateDumper.dump(window, isMain: true)["feedbackWarning"]
        #expect(state?["tracks"]?[0]?["id"] == .int(Int64(track)) && state?["tracks"]?[0]?["monitoring"] == "auto")
        #expect(state?["input"]?["id"] == 10 && state?["output"]?["name"] == "MacBook Pro Speakers")
        #expect(state?["toast"] == .int(Int64(toast.id)))

        // Polling again doesn't post again.
        window.pollTransport()
        #expect(window.toasts.toasts.filter { $0.kind == .feedbackRisk }.count == 1)

        // The action turns that track's monitoring off through SetMonitoring (no undo entry).
        let undo = window.store.undoLabel
        try window.control("toast.\(toast.id).action").action()
        #expect(window.project.tracks[0].monitoring == .off && window.project.tracks[0].armed, "still armed")
        #expect(window.store.undoLabel == undo)
        #expect(window.feedbackGuard.risk == nil && !window.toasts.toasts.contains { $0.kind == .feedbackRisk })
        #expect(UIStateDumper.dump(window, isMain: true)["feedbackWarning"] == .null)
    }

    @Test("DW-230: monitoring `on` warns without an arm; `off` and MIDI tracks don't; the warning goes when the risk does")
    func monitoringModes() throws {
        let (window, _) = try liveWindow(tracks: ["Vox", "Keys"])
        let vox = window.project.tracks[0].id
        window.perform(SetMonitoring(trackID: vox, mode: .on))
        window.pollTransport()
        #expect(window.feedbackGuard.risk?.tracks == [vox])
        let first = try #require(window.feedbackGuard.toastID)

        // A second track joins: one toast, naming both.
        let keys = window.project.tracks[1].id
        window.perform(ArmTrack(trackID: keys, armed: true))
        window.pollTransport()
        #expect(window.feedbackGuard.risk?.tracks == [vox, keys])
        #expect(window.toasts.toasts.filter { $0.kind == .feedbackRisk }.count == 1 && window.feedbackGuard.toastID != first)
        #expect(window.toasts.toasts.last?.message.hasPrefix("Vox and Keys monitor") == true)

        window.perform(SetMonitoring(trackID: vox, mode: .off))
        window.perform(SetMonitoring(trackID: keys, mode: .off))
        window.pollTransport()
        #expect(window.feedbackGuard.risk == nil && window.toasts.toasts.isEmpty, "the toast goes with the risk")

        // MIDI tracks carry no audio input.
        window.addTrack(.midi)
        let midi = try #require(window.project.tracks.last?.id)
        window.perform(ArmTrack(trackID: midi, armed: true))
        window.perform(SetMonitoring(trackID: midi, mode: .on))
        window.pollTransport()
        #expect(window.feedbackGuard.risk == nil)
    }

    @Test("DW-230: headphones on the built-in output, another interface, or an offline engine don't warn")
    func safeSetups() throws {
        var phones = speakers
        phones.outputIsHeadphones = true
        let (headphones, _) = try liveWindow(devices: [mic, phones])
        headphones.perform(ArmTrack(trackID: headphones.project.tracks[0].id, armed: true))
        headphones.pollTransport()
        #expect(headphones.feedbackGuard.risk == nil && headphones.toasts.toasts.isEmpty)

        let (usb, _) = try liveWindow(running: 30)
        usb.perform(ArmTrack(trackID: usb.project.tracks[0].id, armed: true))
        usb.pollTransport()
        #expect(usb.feedbackGuard.risk == nil, "the USB interface's output isn't the built-in speakers")

        // Built-in speakers out, but recording from the interface's inputs (the audio settings' input).
        let (split, _) = try liveWindow()
        split.perform(ArmTrack(trackID: split.project.tracks[0].id, armed: true))
        #expect(FeedbackRisk.assess(project: split.project, devices: [mic, speakers, interface],
                                    config: DriverConfig(inputDevice: 30, sampleRate: 48_000), runningOutput: 20) == nil)
        #expect(FeedbackRisk.assess(project: split.project, devices: [mic, speakers, interface],
                                    config: DriverConfig(sampleRate: 48_000), runningOutput: 20) != nil)

        let (offline, _) = try makeWindow(tracks: ["Vox"])
        offline.perform(ArmTrack(trackID: offline.project.tracks[0].id, armed: true))
        offline.pollTransport()
        #expect(offline.feedbackGuard.risk == nil, "no device")
    }

    @Test("DW-230: a device change while a track monitors re-checks: unplugged headphones warn within the recheck interval, a device event at once")
    func deviceChanges() throws {
        let clock = TestClock()
        var phones = speakers
        phones.outputIsHeadphones = true
        let (window, engine) = try liveWindow(devices: [mic, phones, interface], clock: clock)
        window.perform(ArmTrack(trackID: window.project.tracks[0].id, armed: true))
        window.pollTransport()
        #expect(window.feedbackGuard.risk == nil)

        // Headphones unplugged: the same device, its data source back to the speakers (no event).
        engine.setDevices([mic, speakers, interface])
        window.pollTransport()
        #expect(window.feedbackGuard.risk == nil, "the device list is cached between checks")
        clock.advance(FeedbackGuard.recheckInterval)
        window.pollTransport()
        #expect(window.feedbackGuard.risk != nil && window.toasts.toasts.last?.kind == .feedbackRisk)

        // The device moves to the interface (an engine event): the risk ends at once.
        engine.setRunningDevice(30)
        engine.post(EngineEvent(kind: .deviceChanged, device: DeviceChange(reason: .defaultOutputChanged, previousDeviceID: 20,
                                                                            deviceID: 30, previousSampleRate: 48_000, sampleRate: 48_000)))
        window.engineEventsArrived(engine.pollEvents())
        window.pollTransport()
        #expect(window.feedbackGuard.risk == nil && !window.toasts.toasts.contains { $0.kind == .feedbackRisk })

        // And back to the speakers: a device change while armed warns again.
        engine.setRunningDevice(20)
        engine.post(EngineEvent(kind: .deviceChanged, device: DeviceChange(reason: .defaultOutputChanged, previousDeviceID: 30,
                                                                            deviceID: 20, previousSampleRate: 48_000, sampleRate: 48_000)))
        window.engineEventsArrived(engine.pollEvents())
        window.pollTransport()
        #expect(window.feedbackGuard.risk != nil && window.toasts.toasts.contains { $0.kind == .feedbackRisk })
    }

    @Test("DW-230: a dismissed warning stays dismissed until something new (another track, other devices)")
    func dismissed() throws {
        let (window, _) = try liveWindow(tracks: ["Vox", "Gtr"])
        window.perform(ArmTrack(trackID: window.project.tracks[0].id, armed: true))
        window.pollTransport()
        let toast = try #require(window.toasts.toasts.last)
        try window.control("toast.\(toast.id).dismiss").action()
        window.pollTransport()
        #expect(window.feedbackGuard.risk != nil && window.toasts.toasts.isEmpty, "no nagging")
        window.perform(ArmTrack(trackID: window.project.tracks[1].id, armed: true))
        window.pollTransport()
        #expect(window.toasts.toasts.last?.kind == .feedbackRisk, "a new track: a new warning")
    }

    @Test("DW-230, 08 delta (T-090): device info carries isBuiltIn, outputIsHeadphones and isDefaultInput, decoded with defaults")
    func deviceInfoFields() throws {
        let old = #"{"id":1,"name":"A","inputChannels":2,"outputChannels":2,"nominalSampleRate":48000,"isDefaultOutput":true}"#
        let decoded = try JSONDecoder().decode(AudioDeviceInfo.self, from: Data(old.utf8))
        #expect(!decoded.isBuiltIn && !decoded.outputIsHeadphones && !decoded.isDefaultInput)
        let round = try JSONDecoder().decode(AudioDeviceInfo.self, from: JSONEncoder().encode(mic))
        #expect(round == mic && round.isBuiltIn && round.isDefaultInput)
        // The real engine on the fake driver: never built-in; input 0 is the default output's inputs.
        let engine = try EngineClient(.realtime(DriverConfig(sampleRate: 48_000, bufferFrames: 256, driver: .fake)))
        let devices = engine.devices()
        #expect(devices.map(\.isBuiltIn) == [false, false] && devices.map(\.outputIsHeadphones) == [false, false])
        #expect(devices.map(\.isDefaultInput) == [true, false])
    }
}
