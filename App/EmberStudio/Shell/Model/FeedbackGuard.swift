import DAWModel
import Foundation
import Observation

/// DW-230 (T-090, docs/autobuild/DECISIONS.md "T-090 feedback guard"): what makes monitoring howl.
/// Tracks that monitor their input (REC-020: `on`, or `auto` while armed) through the Mac's own
/// microphone into its own speakers feed the speakers back into the microphone. Headphones on the
/// built-in output don't, and neither does any other interface.
struct FeedbackRisk: Equatable {
    /// The audio tracks that monitor input now, in project order.
    var tracks: [NodeIDValue]
    /// The device the engine records from and the one it plays to.
    var input: AudioDeviceInfo
    var output: AudioDeviceInfo

    /// The risk for `project` on the engine's devices, nil when there is none. `config` is the
    /// realtime engine's (nil offline: no device, no risk), `runningOutput` the output device that
    /// runs (telemetry, 0 while stopped).
    static func assess(project: Project, devices: [AudioDeviceInfo], config: DriverConfig?,
                       runningOutput: UInt32) -> FeedbackRisk? {
        guard let config else { return nil }
        let tracks = monitoringTracks(project)
        guard !tracks.isEmpty else { return nil }
        let outputID = runningOutput != 0 ? runningOutput
            : config.outputDevice != 0 ? config.outputDevice : devices.first(where: \.isDefaultOutput)?.id ?? 0
        guard let output = devices.first(where: { $0.id == outputID }) else { return nil }
        // IO-004: input 0 is the system default input. (Input from a device that doesn't share the
        // output's clock falls back to the output device; built-in mic and speakers share one.)
        let inputID = config.inputDevice != 0 ? config.inputDevice : devices.first(where: \.isDefaultInput)?.id ?? outputID
        guard let input = devices.first(where: { $0.id == inputID }) else { return nil }
        guard input.isBuiltIn, input.inputChannels > 0, output.isBuiltIn, output.outputChannels > 0,
              !output.outputIsHeadphones else { return nil }
        return FeedbackRisk(tracks: tracks, input: input, output: output)
    }

    /// REC-020: audio tracks whose input reaches the output: monitoring `on`, or `auto` while armed
    /// (auto monitors when stopped or recording, so an armed track can howl at any time). MIDI
    /// tracks play through whatever the mode (REC-011), but carry no audio input.
    static func monitoringTracks(_ project: Project) -> [NodeIDValue] {
        project.tracks.filter { track in
            track.kind == .audio && (track.monitoring == .on || (track.monitoring == .auto && track.armed))
        }.map(\.id)
    }
}

/// DW-230 (T-090): watches one window for a `FeedbackRisk` and warns once per new risk with a toast
/// whose "Monitoring Off" action sets those tracks' monitoring off (`SetMonitoring`, the menus'
/// path). The warning is in `ui.state` (`feedbackWarning`) while the risk lasts; the toast goes when
/// it ends.
///
/// It runs from the window's display-rate poll. Reading the project costs nothing; the device list
/// (CoreAudio) is read again only when it may have changed: a monitoring track appears, a device
/// event arrives, the audio settings list the devices, and every `recheckInterval` while a track
/// monitors, which is how unplugged headphones (a data-source change, no device event) are noticed.
@Observable
@MainActor
final class FeedbackGuard {
    @ObservationIgnored weak var window: ProjectWindowModel?

    /// The risk as of the last check, nil when there is none.
    private(set) var risk: FeedbackRisk?
    /// The warning toast showing for `risk`.
    private(set) var toastID: Int?

    @ObservationIgnored private var devices: [AudioDeviceInfo] = []
    @ObservationIgnored private var devicesRead: Date?
    @ObservationIgnored private var devicesStale = true
    @ObservationIgnored private var lastTracks: [NodeIDValue] = []

    static let recheckInterval: TimeInterval = 2

    /// The window's engine changed (DW-156) or its devices did: read them again at the next check.
    func devicesChanged() { devicesStale = true }

    /// The audio settings just listed the engine's devices.
    func devicesListed(_ devices: [AudioDeviceInfo]) {
        self.devices = devices
        devicesRead = window?.toasts.now()
        devicesStale = false
    }

    /// One check; the window's poll calls it.
    func check() {
        guard let window else { return }
        let tracks = FeedbackRisk.monitoringTracks(window.project)
        guard !tracks.isEmpty, let engine = window.engine, case .realtime = engine.mode else {
            lastTracks = tracks
            update(nil)
            return
        }
        let now = window.toasts.now()
        let gained = !Set(tracks).isSubset(of: Set(lastTracks))
        lastTracks = tracks
        if devicesStale || gained || devicesRead.map({ now.timeIntervalSince($0) >= Self.recheckInterval }) ?? true {
            devices = engine.devices()
            devicesRead = now
            devicesStale = false
        }
        update(FeedbackRisk.assess(project: window.project, devices: devices, config: window.audioPrefs.config,
                                   runningOutput: window.telemetry.outputDeviceID))
    }

    /// Warns about a risk that is new: one that wasn't there, a track that joined it, or other devices.
    private func update(_ new: FeedbackRisk?) {
        let old = risk
        guard new != old else { return }
        risk = new
        guard let window else { return }
        guard let new else {
            if let toastID { window.toasts.dismiss(toastID) }
            toastID = nil
            return
        }
        let joined = !Set(new.tracks).isSubset(of: Set(old?.tracks ?? []))
        let otherDevices = old.map { $0.input.id != new.input.id || $0.output.id != new.output.id } ?? true
        let shown = toastID.map { id in window.toasts.toasts.contains { $0.id == id } } ?? false
        // Dismissed: no new toast until something new. Showing: it is replaced, so its text is current.
        guard shown || joined || otherDevices else { return }
        if let toastID { window.toasts.dismiss(toastID) }
        let names = new.tracks.map { window.project.track($0)?.name ?? "Track \($0)" }
        toastID = window.toasts.post(
            .feedbackRisk, .warning, title: "Feedback risk",
            message: "\(Self.list(names)) monitor\(names.count == 1 ? "s" : "") \(new.input.name) through "
                + "\(new.output.name): the speakers feed back into the microphone. Use headphones, or turn monitoring off.",
            action: Toast.Action(label: "Monitoring Off") { [weak self] in self?.monitoringOff() })
    }

    /// The toast's action: the monitoring of every track the warning names goes off, through
    /// `SetMonitoring` (history-exempt, like the track menus).
    func monitoringOff() {
        guard let window, let tracks = risk?.tracks else { return }
        toastID = nil
        for id in tracks where window.project.track(id).map({ $0.monitoring != .off }) ?? false {
            window.perform(SetMonitoring(trackID: id, mode: .off))
        }
        check()
    }

    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}
