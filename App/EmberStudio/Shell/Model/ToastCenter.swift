import DAWModel
import Foundation
import Observation

/// One toast (UI-004).
struct Toast: Identifiable, Equatable {
    enum Kind: String, Codable, Sendable {
        case deviceChanged, overload, pluginCrashed, assetLoadFailed, graphRejected, assetsReloaded, recordingDropped
        /// T-055: takes recorded and added to the project; a take that couldn't be saved or added.
        case recordingFinalized, recordingFailed
        case recoveryAvailable, offlineAssets, repairs, info, error
    }

    enum Severity: String, Codable, Sendable, Comparable {
        case info, warning, error

        static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
        private var rank: Int { self == .info ? 0 : self == .warning ? 1 : 2 }
    }

    struct Action: Equatable {
        let label: String
        let perform: @MainActor () -> Void

        static func == (a: Action, b: Action) -> Bool { a.label == b.label }
    }

    let id: Int
    let kind: Kind
    var severity: Severity
    var title: String
    var message: String
    var action: Action?
    /// `overload`: how many xruns so far (coalesced into one toast).
    var count: UInt64?
    var postedAt: Date
    /// nil: stays until dismissed or its action runs.
    var expiresAt: Date?
}

/// UI-004: turns engine events into toasts, coalesces bursts, and expires them. The clock is
/// injectable so expiry is testable without waiting.
@Observable
@MainActor
final class ToastCenter {
    private(set) var toasts: [Toast] = []
    @ObservationIgnored var now: @MainActor () -> Date
    /// Names a device for "switched to …" (the engine's device list); nil shows its ID.
    @ObservationIgnored var deviceName: @MainActor (UInt32) -> String? = { _ in nil }
    /// UI-004 (T-055): names a track for recording toasts; nil shows its ID.
    @ObservationIgnored var trackName: @MainActor (NodeIDValue) -> String? = { _ in nil }
    /// REC-004: whether a finished take is in the project now (the store imports it before the
    /// window sees the event). Without a project to ask, every take counts as added.
    @ObservationIgnored var takeImported: @MainActor (RecordedTake) -> Bool = { _ in true }
    /// UI-040 (T-055): opens the window's audio settings; device toasts then offer it as their action.
    @ObservationIgnored var openAudioSettings: (@MainActor () -> Void)?
    @ObservationIgnored private var nextID = 1

    /// How long a toast stays, by severity; errors and toasts with an action stay until dismissed.
    static let lifetime: [Toast.Severity: TimeInterval] = [.info: 4, .warning: 8]
    /// The most shown at once; the oldest goes first.
    static let capacity = 5

    init(now: @escaping @MainActor () -> Date = { Date() }) {
        self.now = now
    }

    // MARK: Posting

    @discardableResult
    func post(_ kind: Toast.Kind, _ severity: Toast.Severity, title: String, message: String = "",
              action: Toast.Action? = nil, count: UInt64? = nil, sticky: Bool? = nil) -> Int {
        let at = now()
        let sticky = sticky ?? (action != nil || severity == .error)
        let toast = Toast(id: nextID, kind: kind, severity: severity, title: title, message: message, action: action,
                          count: count, postedAt: at,
                          expiresAt: sticky ? nil : at.addingTimeInterval(Self.lifetime[severity] ?? 8))
        nextID += 1
        toasts.append(toast)
        if toasts.count > Self.capacity { toasts.removeFirst(toasts.count - Self.capacity) }
        return toast.id
    }

    /// MODEL-045, DW-144: an autosave newer than the saved project is waiting; `recover` reopens it.
    @discardableResult
    func postRecoveryAvailable(project: String, recover: @escaping @MainActor () -> Void) -> Int {
        post(.recoveryAvailable, .warning, title: "Unsaved changes found",
             message: "\(project) has an autosave newer than its last save.", action: Toast.Action(label: "Recover", perform: recover))
    }

    /// DW-144: what opening a project found (offline audio, repairs).
    func post(loadReport report: ProjectLoadReport, project: String) {
        if !report.offlineAssets.isEmpty {
            let n = report.offlineAssets.count
            post(.offlineAssets, .warning, title: "\(n) audio file\(n == 1 ? "" : "s") offline",
                 message: "\(project): their clips play silence until the files are back.")
        }
        if !report.repairs.isEmpty {
            post(.repairs, .info, title: "Project repaired on open", message: report.repairs.joined(separator: "\n"))
        }
    }

    // MARK: Engine events

    /// UI-004: one toast per event that a person should hear about; asset loads, jobs and the like
    /// pass silently. Overloads coalesce into the toast already showing.
    func handle(_ events: [EngineEvent]) {
        // Takes that ended together (every armed track stops at once) share one toast.
        var recorded: [RecordedTake] = []
        for event in events {
            if event.kind == .recordingFinalized, event.error == nil, let take = event.recording, isAdded(take) {
                recorded.append(take)
            } else {
                handle(event)
            }
        }
        if !recorded.isEmpty { postRecorded(recorded) }
    }

    func handle(_ event: EngineEvent) {
        switch event.kind {
        case .deviceChanged:
            deviceChanged(event)
        case .overload:
            if let i = toasts.lastIndex(where: { $0.kind == .overload }) {
                toasts[i].count = event.count
                toasts[i].message = Self.overloadMessage(event.count)
                toasts[i].expiresAt = now().addingTimeInterval(Self.lifetime[.warning]!)
            } else {
                post(.overload, .warning, title: "Audio dropout", message: Self.overloadMessage(event.count), count: event.count)
            }
        case .pluginCrashed:
            post(.pluginCrashed, .error, title: "A plugin misbehaved",
                 message: event.error.map { "\($0)" } ?? "It was disabled; the project autosaved.")
        case .assetLoadFailed:
            post(.assetLoadFailed, .warning, title: "Audio file didn't load",
                 message: event.error.map { "Asset \(event.subject): \($0)" } ?? "Asset \(event.subject)")
        case .graphRejected:
            post(.graphRejected, .error, title: "The engine refused a change",
                 message: event.error.map { "\($0)" } ?? "Graph \(event.subject) was rejected.")
        case .assetsReloaded:
            assetsReloaded(event)
        case .recordingFinalized:
            recordingFinalized(event)
        case .assetLoaded, .jobFinished:
            return
        }
    }

    /// UI-040: "Audio Settings…" on device toasts, when the window has them. It doesn't make a
    /// toast sticky; errors are anyway.
    private var settingsAction: Toast.Action? {
        openAudioSettings.map { open in Toast.Action(label: "Audio Settings…", perform: open) }
    }

    private func postDevice(_ severity: Toast.Severity, title: String, message: String) {
        post(.deviceChanged, severity, title: title, message: message, action: settingsAction, sticky: severity == .error)
    }

    private func deviceChanged(_ event: EngineEvent) {
        guard let change = event.device else {
            postDevice(event.error == nil ? .info : .error, title: "Audio device changed", message: event.error.map { "\($0)" } ?? "")
            return
        }
        let to = name(change.deviceID)
        let rate = change.sampleRate != change.previousSampleRate && change.sampleRate > 0
            ? " Session rate is now \(Self.khz(change.sampleRate))." : ""
        if let error = event.error, change.deviceID == 0 || change.reason == .startFailed {
            postDevice(.error, title: "No audio device running", message: "\(error)")
            return
        }
        switch change.reason {
        case .deviceLost:
            postDevice(.warning, title: "Audio device lost",
                 message: "\(name(change.previousDeviceID)) went away; playback stopped. Now using \(to).\(rate)")
        case .sampleRateChanged:
            postDevice(.warning, title: "Sample rate changed",
                 message: "\(to) moved from \(Self.khz(change.previousSampleRate)) to \(Self.khz(change.sampleRate)); playback stopped.")
        case .defaultOutputChanged:
            postDevice(.info, title: "Output device changed", message: "Following the system default: \(to).\(rate)")
        case .deviceAvailable:
            postDevice(.info, title: "Audio device available", message: "Now using \(to).\(rate)")
        case .startFailed:
            postDevice(.error, title: "Audio device didn't start", message: event.error.map { "\($0)" } ?? to)
        }
    }

    /// IO-033 (DW-183): a session-rate change's re-conversion. Its progress shows in the toolbar
    /// (`AudioPreferencesModel.reload`); the toast says when it is done, or what failed.
    private func assetsReloaded(_ event: EngineEvent) {
        let reload = event.reload
        guard reload?.phase ?? .finished == .finished else { return }
        if let error = event.error {
            let failed = reload.map { $0.failed > 0 ? "\($0.failed) of \($0.total) audio files didn't convert: " : "" } ?? ""
            post(.assetsReloaded, .warning, title: "Audio not reloaded", message: failed + "\(error)")
        } else if let reload, reload.total > 0 {
            let n = reload.total
            post(.assetsReloaded, .info, title: "Audio converted to \(Self.khz(reload.sampleRate))",
                 message: "\(n) audio file\(n == 1 ? "" : "s") re-converted from the originals.")
        }
    }

    // MARK: Recording (UI-004, REC-002/004, T-055)

    private func isAdded(_ take: RecordedTake) -> Bool { take.frames > 0 && !take.file.isEmpty && takeImported(take) }

    private func track(_ id: NodeIDValue) -> String { trackName(id) ?? "Track \(id)" }

    private func seconds(_ frames: Int64, _ rate: Double) -> String {
        String(format: "%.1f s", rate > 0 ? Double(frames) / rate : 0)
    }

    /// A finished take: added (info, shared by takes that ended together), with dropped audio
    /// (warning: the gaps are silent), not written (error), empty, or not added (warning: the file
    /// is kept).
    private func recordingFinalized(_ event: EngineEvent) {
        guard let take = event.recording else {
            // An engine without takes (before T-052): only an error says anything.
            if let error = event.error { post(.recordingDropped, .warning, title: "Recording dropped audio", message: "\(error)") }
            return
        }
        let name = track(take.track)
        if take.file.isEmpty {
            post(.recordingFailed, .error, title: "Recording not saved",
                 message: "\(name): \(event.error.map { "\($0)" } ?? "the take couldn't be written.")")
            return
        }
        if take.frames == 0 {
            post(.recordingFinalized, .info, title: "Nothing recorded", message: "\(name): the take is empty.")
            return
        }
        let added = takeImported(take)
        if take.droppedFrames > 0 || event.error != nil {
            let lost = take.droppedFrames > 0
                ? "\(take.droppedFrames) frames (\(Self.ms(take.droppedFrames, take.sampleRate))) were lost; the gaps are silent."
                : event.error.map { "\($0)" } ?? ""
            let file = added ? "" : " The take wasn't added to the project; its file is at \(take.file)."
            post(.recordingDropped, .warning, title: "Recording dropped audio", message: "\(name): \(lost)\(file)")
        } else if added {
            postRecorded([take])
        } else {
            post(.recordingFailed, .warning, title: "Take not added",
                 message: "\(name): the take couldn't be added to the project. Its file is at \(take.file).")
        }
    }

    private static func ms(_ frames: UInt64, _ rate: Double) -> String {
        String(format: "%.0f ms", rate > 0 ? Double(frames) * 1000 / rate : 0)
    }

    private func postRecorded(_ takes: [RecordedTake]) {
        let list = takes.map { "\(track($0.track)) (\(seconds($0.frames, $0.sampleRate)))" }.joined(separator: ", ")
        post(.recordingFinalized, .info, title: takes.count == 1 ? "Take recorded" : "\(takes.count) takes recorded", message: list)
    }

    private func name(_ id: UInt32) -> String {
        id == 0 ? "no device" : deviceName(id) ?? "device \(id)"
    }

    private static func khz(_ rate: Double) -> String {
        rate.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(rate / 1000)) kHz" : String(format: "%.1f kHz", rate / 1000)
    }

    private static func overloadMessage(_ count: UInt64) -> String {
        "The audio thread missed its deadline (\(count) dropout\(count == 1 ? "" : "s") so far)."
    }

    // MARK: Lifetime

    func dismiss(_ id: Int) {
        toasts.removeAll { $0.id == id }
    }

    /// Runs a toast's action and dismisses it.
    func performAction(_ id: Int) {
        guard let toast = toasts.first(where: { $0.id == id }) else { return }
        dismiss(id)
        toast.action?.perform()
    }

    /// Drops toasts whose time is up.
    func expire() {
        let at = now()
        toasts.removeAll { $0.expiresAt.map { $0 <= at } ?? false }
    }

    /// UI-052: dismiss and action buttons, `toast.<id>.dismiss` / `toast.<id>.action`.
    var controls: [UIControl] {
        toasts.flatMap { toast -> [UIControl] in
            var controls = [UIControl.button("toast.\(toast.id).dismiss", "Dismiss") { [weak self] in self?.dismiss(toast.id) }]
            if let action = toast.action {
                controls.append(.button("toast.\(toast.id).action", action.label) { [weak self] in self?.performAction(toast.id) })
            }
            return controls
        }
    }
}
