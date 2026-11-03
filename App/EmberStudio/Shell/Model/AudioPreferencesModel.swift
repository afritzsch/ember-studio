import DAWModel
import Foundation
import Observation

/// UI-040 (T-055): the audio preferences of one project window: output and input device, the
/// session sample rate, buffer size and input channels, with the latency they give. Every window
/// has its own engine (one per project), so the preferences belong to the window.
///
/// Device, buffer and input changes call `EngineProtocol.setDevice` with the window's engine
/// config (realtime engines only). The sample rate is the project's: it changes through
/// `SetSessionSampleRate` (MODEL-005, DW-183), which asks the engine first, so a rate the device
/// can't run is refused before the document changes. While the engine re-converts the project's
/// audio to a new rate (IO-033) `reload` follows its `assetsReloaded` events, for the progress bar.
///
/// The engine doesn't report the config it runs (only the device and rate, in telemetry), so the
/// model keeps the last config it applied to each engine, starting from the one the engine was
/// created with (`EngineProtocol.mode`).
@Observable
@MainActor
final class AudioPreferencesModel {
    @ObservationIgnored weak var window: ProjectWindowModel?

    /// The panel shows (`prefs.audio`). Opening it lists the devices again.
    var isOpen = false {
        didSet { if isOpen && !oldValue { refreshDevices() } }
    }

    /// The engine's devices as of the last refresh (opening the panel, a device event, a change).
    private(set) var devices: [AudioDeviceInfo] = []
    /// The re-conversion pass running since the last session-rate change (IO-033), nil when none.
    private(set) var reload: AssetsReload?
    /// Why the last device change was refused, until the next one succeeds.
    private(set) var lastError: String?
    /// Every device name seen on this window's engines, so a toast can still name a device that
    /// has gone (a lost device leaves the engine's list).
    @ObservationIgnored private var knownNames: [UInt32: String] = [:]
    /// The config last applied to an engine (`engine` identifies which).
    @ObservationIgnored private var applied: (engine: ObjectIdentifier, config: DriverConfig)?

    /// IO-003.
    static let bufferSizes: [UInt32] = [32, 64, 128, 256, 512, 1024, 2048]
    static let sampleRates: [Double] = [44_100, 48_000, 88_200, 96_000]
    /// Input channel counts offered (IO-003 `inputChannels`: the device's first N), up to the device's.
    static let inputChannelCounts: [UInt32] = [1, 2, 4, 8, 16, 32]

    var engine: (any EngineProtocol)? { window?.engine }

    /// The config the window's engine runs, as far as the app knows; nil for an offline engine
    /// (no device to configure) or none.
    var config: DriverConfig? {
        guard let engine, case .realtime(let created) = engine.mode else { return nil }
        if let applied, applied.engine == ObjectIdentifier(engine) { return applied.config }
        return created
    }

    var driver: DeviceDriverKind? { config?.driver }
    var sessionSampleRate: Double { window?.project.sessionSampleRate ?? 48_000 }
    var telemetry: EngineTelemetry { window?.telemetry ?? EngineTelemetry() }
    var outputDevices: [AudioDeviceInfo] { devices.filter { $0.outputChannels > 0 } }
    var inputDevices: [AudioDeviceInfo] { devices.filter { $0.inputChannels > 0 } }

    /// A device's name from the last list, else from any list seen before (a device now gone).
    func deviceName(_ id: UInt32) -> String? { devices.first { $0.id == id }?.name ?? knownNames[id] }

    /// UI-004: what a device toast calls device `id`, listing the devices again if it is new.
    func name(of id: UInt32) -> String? {
        if let name = deviceName(id) { return name }
        refreshDevices()
        return deviceName(id)
    }

    var outputTitle: String {
        guard let config else { return "None (offline)" }
        if config.outputDevice != 0 { return deviceName(config.outputDevice) ?? "Device \(config.outputDevice)" }
        let running = telemetry.outputDeviceID
        return running == 0 ? "System Default" : "System Default (\(deviceName(running) ?? "device \(running)"))"
    }

    var inputTitle: String {
        guard let config else { return "None (offline)" }
        return config.inputDevice == 0 ? "System Default" : deviceName(config.inputDevice) ?? "Device \(config.inputDevice)"
    }

    /// The most input channels the chosen input could give: the input device's, else the device
    /// that runs (IO-004 may use it for input), else the most any device has.
    var maxInputChannels: UInt32 {
        guard let config else { return 0 }
        let id = config.inputDevice != 0 ? config.inputDevice : telemetry.outputDeviceID
        if let device = devices.first(where: { $0.id == id }), device.inputChannels > 0 { return device.inputChannels }
        return devices.map(\.inputChannels).max() ?? 0
    }

    /// DW-200: input channel pairs a track can record from: the device's inputs, as many as the
    /// engine captures (`inputChannels`, the device's first N), in pairs (an odd last channel
    /// makes a pair of its own). 0 without a device.
    var inputPairCount: UInt32 {
        guard let config else { return 0 }
        let channels = min(maxInputChannels, config.inputChannels)
        return (channels + 1) / 2
    }

    /// The counts the input-channel menu offers: powers of two up to the device's, the device's
    /// own count and whatever is set now.
    var inputChannelChoices: [UInt32] {
        guard let config else { return [] }
        let most = min(maxInputChannels, Self.inputChannelCounts.last!)
        var choices = Set(Self.inputChannelCounts.filter { $0 <= most })
        if most > 0 { choices.insert(most) }
        choices.insert(config.inputChannels)
        return choices.sorted()
    }

    // MARK: Latency (IO-005)

    /// What the output latency adds up to, in samples at the session rate (telemetry, IO-005): the
    /// device's (latency + safety offset + buffer + stream) and the graph's (PDC, MIX).
    struct Latency: Equatable {
        var deviceSamples: UInt32
        var graphSamples: UInt32
        var totalSamples: UInt32
        var sampleRate: Double

        func ms(_ samples: UInt32) -> Double { sampleRate > 0 ? Double(samples) * 1000 / sampleRate : 0 }
        var totalMs: Double { ms(totalSamples) }
    }

    var latency: Latency {
        let t = telemetry
        return Latency(deviceSamples: t.deviceOutputLatency, graphSamples: t.graphLatency, totalSamples: t.outputLatency,
                       sampleRate: t.sampleRate > 0 ? t.sampleRate : sessionSampleRate)
    }

    /// "Output 5.3 ms (256 + 0 samples)"
    var latencyText: String {
        let l = latency
        guard config != nil, telemetry.deviceRunning else { return "No device running" }
        return String(format: "Output %.1f ms (%u device + %u plugin samples)", l.totalMs, l.deviceSamples, l.graphSamples)
    }

    /// "Converting audio to 44.1 kHz: 3 of 10"
    var reloadText: String? {
        guard let reload else { return nil }
        let rate = Self.khz(reload.sampleRate)
        return reload.total == 0 ? "Converting audio to \(rate)…" : "Converting audio to \(rate): \(reload.done) of \(reload.total)"
    }

    // MARK: Actions

    /// Lists the engine's devices again.
    func refreshDevices() {
        let devices = engine?.devices() ?? []
        for device in devices { knownNames[device.id] = device.name }
        if devices != self.devices { self.devices = devices }
    }

    func selectOutput(_ id: UInt32) { change("Output device") { $0.outputDevice = id } }
    func selectInput(_ id: UInt32) { change("Input device") { $0.inputDevice = id } }
    func setBufferFrames(_ frames: UInt32) { change("Buffer size") { $0.bufferFrames = frames } }
    func setInputChannels(_ count: UInt32) { change("Input channels") { $0.inputChannels = count } }

    /// DW-183: the project's session rate (MODEL-005). The engine stops, restarts the device at the
    /// rate and re-converts the audio (IO-033); a rate the device can't run is refused with a toast.
    func setSampleRate(_ rate: Double) {
        guard rate != sessionSampleRate else { return }
        window?.perform(SetSessionSampleRate(sampleRate: rate))
    }

    /// `setDevice` with the config edited. Rate 0 keeps the session rate when the device can run
    /// it, else the engine takes the device's and the document follows (DW-079, DW-130).
    private func change(_ what: String, _ edit: (inout DriverConfig) -> Void) {
        guard let engine, var config else { return }
        edit(&config)
        config.sampleRate = 0
        do {
            try engine.setDevice(config)
            applied = (ObjectIdentifier(engine), config)
            lastError = nil
        } catch {
            lastError = error.description
            window?.toasts.post(.deviceChanged, .error, title: "\(what) not changed", message: error.description)
        }
        refreshDevices()
    }

    // MARK: Engine events

    /// IO-021 / IO-033: device events refresh the list (and a lost device that was chosen by name
    /// becomes "follow the system default", as the engine does); `assetsReloaded` moves `reload`.
    func engineEventsArrived(_ events: [EngineEvent]) {
        for event in events {
            switch event.kind {
            case .deviceChanged:
                if event.device?.reason == .deviceLost, let engine, var config,
                   config.outputDevice != 0, config.outputDevice == event.device?.previousDeviceID {
                    config.outputDevice = 0
                    applied = (ObjectIdentifier(engine), config)
                }
                refreshDevices()
            case .assetsReloaded:
                guard let pass = event.reload else {
                    reload = nil
                    continue
                }
                reload = pass.phase == .finished ? nil : pass
            default:
                continue
            }
        }
    }

    /// The window shows another project (with another engine).
    func engineReplaced() {
        reload = nil
        lastError = nil
        applied = nil
        refreshDevices()
    }

    // MARK: Controls (UI-052)

    /// `prefs.audio` (always, ⌘,); while the panel is open, `prefs.audio.close`, `.refresh`,
    /// `.output.<id|default>`, `.input.<id|default>`, `.sampleRate.<Hz>`, `.buffer.<frames>` and
    /// `.inputChannels.<n>`.
    var controls: [UIControl] {
        var controls: [UIControl] = [
            .toggle("prefs.audio", "Audio Settings", isOn: isOpen) { [weak self] in self?.isOpen.toggle() },
        ]
        guard isOpen else { return controls }
        let config = config
        let realtime = config != nil
        controls += [
            .button("prefs.audio.close", "Close Audio Settings") { [weak self] in self?.isOpen = false },
            .button("prefs.audio.refresh", "Refresh Devices", enabled: realtime) { [weak self] in self?.refreshDevices() },
            .toggle("prefs.audio.output.default", "Output: System Default", isOn: config?.outputDevice == 0, enabled: realtime) {
                [weak self] in self?.selectOutput(0)
            },
        ]
        controls += outputDevices.map { device in
            .toggle("prefs.audio.output.\(device.id)", "Output: \(device.name)", isOn: config?.outputDevice == device.id,
                    enabled: realtime) { [weak self] in self?.selectOutput(device.id) }
        }
        controls.append(.toggle("prefs.audio.input.default", "Input: System Default", isOn: config?.inputDevice == 0,
                                enabled: realtime) { [weak self] in self?.selectInput(0) })
        controls += inputDevices.map { device in
            .toggle("prefs.audio.input.\(device.id)", "Input: \(device.name)", isOn: config?.inputDevice == device.id,
                    enabled: realtime) { [weak self] in self?.selectInput(device.id) }
        }
        let rate = sessionSampleRate
        controls += Self.sampleRates.map { r in
            .toggle("prefs.audio.sampleRate.\(Int(r))", "Sample Rate \(Self.khz(r))", isOn: rate == r) { [weak self] in
                self?.setSampleRate(r)
            }
        }
        controls += Self.bufferSizes.map { frames in
            .toggle("prefs.audio.buffer.\(frames)", "Buffer \(frames) samples", isOn: config?.bufferFrames == frames,
                    enabled: realtime) { [weak self] in self?.setBufferFrames(frames) }
        }
        controls += inputChannelChoices.map { n in
            .toggle("prefs.audio.inputChannels.\(n)", "\(n) input channel\(n == 1 ? "" : "s")", isOn: config?.inputChannels == n,
                    enabled: realtime) { [weak self] in self?.setInputChannels(n) }
        }
        return controls
    }

    static func khz(_ rate: Double) -> String {
        rate.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(rate / 1000)) kHz" : String(format: "%.1f kHz", rate / 1000)
    }
}
